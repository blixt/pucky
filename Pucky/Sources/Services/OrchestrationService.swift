import Foundation

/// Takes a set of generated file patches, applies them to the workspace,
/// runs the Oxc transform pipeline on the transformable files, bundles
/// the result, and asks the preview service to reload.
///
/// This service used to also perform a second model call for structured
/// patches — that design was flagged by Codex (two-pass generation is
/// wasteful and can't share context). The model call is now owned by
/// `AppState.sendMessage`, which streams a single response, parses
/// Gemma 4 native tool calls via `Gemma4StreamingHandler`, and converts
/// them to `FilePatch`es. Orchestration is narrowed to "take patches,
/// build, reload."
@MainActor
@Observable
final class OrchestrationService {
    enum LoopState: Equatable {
        case idle
        case transforming
        case bundling
        case reloading
        case error(String)
    }

    var state: LoopState = .idle
    var lastBuildDiagnostics: [TransformService.Diagnostic] = []
    /// Most recent failure surfaced as `BuildError` so the next turn
    /// can include it in the system prompt. Cleared at the start of
    /// every `applyAndBuild` and on every successful build.
    var lastBuildError: BuildError? = nil
    var pendingSystemMessages: [ChatMessage] = []

    private let transform: TransformService
    private let preview: PreviewService
    private let project: ProjectService

    init(transform: TransformService, preview: PreviewService, project: ProjectService) {
        self.transform = transform
        self.preview = preview
        self.project = project
    }

    /// Apply patches, transform, bundle, and reload the preview.
    /// Surfaces any failure as both an inline chat system message
    /// and a structured `lastBuildError` so the next user turn can
    /// include the offending line + a few lines of context in the
    /// system prompt and the model can write a precise edit_file.
    func applyAndBuild(patches: [FilePatch]) async {
        guard !patches.isEmpty else {
            state = .idle
            return
        }

        // Wipe the previous build's error before doing any work so a
        // successful run leaves the slate clean.
        lastBuildError = nil

        for p in patches {
            PuckyLog.orch.notice(
                "[orch] patch op=\(p.kindTag, privacy: .public) path=\(p.path, privacy: .public)"
            )
        }

        do {
            try project.applyPatches(patches)
            PuckyLog.orch.notice("[orch] applyPatches ok")
        } catch let error as ProjectService.PatchError {
            // PatchError already carries the offending path inside
            // its case payload — pull it out so the BuildError
            // points the model at the file that actually failed,
            // not just the first one in the batch.
            PuckyLog.orch.error(
                "[orch] applyPatches failed err=\(error.localizedDescription, privacy: .public)"
            )
            let failingPath = error.path ?? patches.first?.path ?? ""
            lastBuildError = BuildError(
                path: failingPath,
                line: 0,
                column: 0,
                message: error.localizedDescription,
                snippet: ""
            )
            state = .error(error.localizedDescription)
            pendingSystemMessages.append(ChatMessage(
                role: .system,
                text: error.localizedDescription
            ))
            return
        } catch {
            PuckyLog.orch.error(
                "[orch] applyPatches failed err=\(error.localizedDescription, privacy: .public)"
            )
            state = .error(error.localizedDescription)
            pendingSystemMessages.append(ChatMessage(
                role: .system,
                text: "Failed to apply patches: \(error.localizedDescription)"
            ))
            return
        }

        await transformAndBundleCurrentWorkspace()
    }

    /// Compile every transformable file in the current workspace
    /// with Oxc, link them into a module map, and write the result
    /// into the preview bundle. Used by `applyAndBuild` after a
    /// patch round AND by `buildCurrentWorkspace()` so the preview
    /// can be functional immediately on app launch — without this
    /// the user sees the empty-state placeholder until they send
    /// their first message and the model emits a tool call. The
    /// method is private because callers should always go through
    /// one of the two public entry points so the contract about
    /// when to clear `lastBuildError` stays consistent.
    private func transformAndBundleCurrentWorkspace() async {
        state = .transforming
        let sourceFiles = project.files.filter { $0.language.isTransformable }
        PuckyLog.orch.notice("[orch] transform begin files=\(sourceFiles.count, privacy: .public)")
        var transformedFiles: [String: String] = [:]
        var diagnosticsByFile: [(file: ProjectFile, diag: TransformService.Diagnostic)] = []

        do {
            for file in sourceFiles {
                let result = try await transform.transform(
                    source: file.content,
                    filename: file.name
                )
                transformedFiles[file.path] = result.javascript
                for d in result.diagnostics {
                    diagnosticsByFile.append((file, d))
                }
                PuckyLog.orch.notice(
                    "[orch] transform ok file=\(file.path, privacy: .public) jsBytes=\(result.javascript.count, privacy: .public) diags=\(result.diagnostics.count, privacy: .public)"
                )
            }
        } catch {
            PuckyLog.orch.error(
                "[orch] transform failed err=\(error.localizedDescription, privacy: .public)"
            )
            state = .error(error.localizedDescription)
            pendingSystemMessages.append(ChatMessage(
                role: .system,
                text: "Transform failed: \(error.localizedDescription)"
            ))
            return
        }

        lastBuildDiagnostics = diagnosticsByFile.map(\.diag)

        let errorPairs = diagnosticsByFile.filter { $0.diag.severity == .error }
        if let first = errorPairs.first {
            let snippet = BuildError.snippet(from: first.file.content, line: first.diag.line)
            let buildErr = BuildError(
                path: first.file.path,
                line: first.diag.line,
                column: first.diag.column,
                message: first.diag.message,
                snippet: snippet
            )
            lastBuildError = buildErr
            let displaySummary = "\(first.file.path):\(first.diag.line) — \(first.diag.message)\n\(snippet)"
            PuckyLog.orch.error(
                "[orch] build errors count=\(errorPairs.count, privacy: .public) first=\(displaySummary, privacy: .public)"
            )
            state = .error(first.diag.message)
            pendingSystemMessages.append(ChatMessage(
                role: .system,
                text: "Build error in \(first.file.path):\(first.diag.line)\n\(first.diag.message)\n\(snippet)"
            ))
            return
        }

        state = .bundling
        do {
            let template = project.template
            let modules = try await transform.linkTransformed(
                transformedFiles: transformedFiles,
                entryPoint: template.preview.entryPoint
            )
            let totalBytes = modules.values.reduce(0) { $0 + $1.count }
            PuckyLog.orch.notice(
                "[orch] bundle ok modules=\(modules.count, privacy: .public) bytes=\(totalBytes, privacy: .public) template=\(template.id, privacy: .public)"
            )
            state = .reloading
            try preview.writeBundle(template: template, modules: modules)
            state = .idle
            PuckyLog.orch.notice("[orch] reload ok state=idle")
        } catch {
            PuckyLog.orch.error(
                "[orch] bundle failed err=\(error.localizedDescription, privacy: .public)"
            )
            state = .error(error.localizedDescription)
            pendingSystemMessages.append(ChatMessage(
                role: .system,
                text: "Bundle failed: \(error.localizedDescription)"
            ))
        }
    }

    /// Build the current workspace without applying any patches.
    /// Called from `AppState.initialize()` so the preview is alive
    /// the moment the user opens the app — they swipe over to the
    /// Preview tab and see the default scaffold running, instead
    /// of an empty-state placeholder telling them to "describe an
    /// app in chat to see it live here".
    func buildCurrentWorkspace() async {
        // Clear any error from a previous workspace before
        // rebuilding. The default scaffold should always succeed.
        lastBuildError = nil
        await transformAndBundleCurrentWorkspace()
    }
}
