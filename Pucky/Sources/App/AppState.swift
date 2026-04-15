import SwiftUI

@MainActor
@Observable
final class AppState {
    var selectedTab: AppTab = .chat
    var chatMessages: [ChatMessage] = []
    var isModelLoaded: Bool = false
    var isGenerating: Bool = false
    var loadError: String?

    /// The active project template. Persisted to UserDefaults so a
    /// half-finished Three.js session survives an app relaunch. The
    /// chat hero's template picker binds straight to this.
    var projectTemplate: ProjectTemplate {
        get { storedTemplate }
        set {
            guard newValue != storedTemplate else { return }
            storedTemplate = newValue
        }
    }
    private var storedTemplate: ProjectTemplate = {
        if let raw = UserDefaults.standard.string(forKey: "PuckyProjectTemplate"),
           let parsed = ProjectTemplate.template(id: raw) {
            return parsed
        }
        return .defaultTemplate
    }() {
        didSet {
            UserDefaults.standard.set(storedTemplate.id, forKey: "PuckyProjectTemplate")
        }
    }

    let modelService = ModelService()
    let transformService = TransformService()
    let previewService = PreviewService()
    let projectService = ProjectService()
    private(set) var orchestration: OrchestrationService!

    /// In-flight generation task. Owned by `AppState` so
    /// `startNewSession` (and any future "stop generating" affordance)
    /// can cancel and await it before mutating shared state. Without
    /// this, a tap on `New` mid-stream invalidates `messageIndex`
    /// captured by `runGeneration` and the next chunk hits an
    /// out-of-range write into `chatMessages`.
    private var generationTask: Task<Void, Never>?

    var projectFiles: [ProjectFile] {
        projectService.files
    }

    init() {
        orchestration = OrchestrationService(
            transform: transformService,
            preview: previewService,
            project: projectService
        )
    }

    func initialize() async {
        loadError = nil
        projectService.createDefaultProject(template: projectTemplate)

        // Compile + bundle the default scaffold immediately so the
        // Preview tab is functional the moment the user opens the
        // app, before they've sent any message. Without this they
        // see the empty-state placeholder until the model emits
        // its first successful tool call. The build happens in
        // parallel with model loading because they touch different
        // resources (Oxc + filesystem vs MLX + GPU).
        async let initialBuild: Void = orchestration.buildCurrentWorkspace()

        #if DEBUG
        // UI smoke tests need to drive the chrome without waiting
        // for an actual MLX load (which is slow on simulator and
        // unreliable without a GPU). XCUIApplication injects this
        // arg via `launchArguments`; nothing in the shipping app
        // ever sets it.
        if ProcessInfo.processInfo.arguments.contains("--pucky-ui-test") {
            isModelLoaded = true
            await initialBuild
            return
        }
        #endif

        do {
            try await modelService.loadModel()
            isModelLoaded = true
        } catch {
            loadError = error.localizedDescription
        }

        await initialBuild
    }

    /// Cancel any in-flight generation, wait for it to settle, then
    /// reset every piece of session state — chat transcript,
    /// project workspace back to the default scaffold, preview
    /// bundle (deleted off disk), orchestration state, and any
    /// pending build error. The cancel-and-await is the critical
    /// part: without it, an in-flight `runGeneration` would keep
    /// mutating `chatMessages[messageIndex]` after we've already
    /// removed the messages, hitting an out-of-bounds write.
    func startNewSession() async {
        if let task = generationTask {
            task.cancel()
            await task.value
        }
        generationTask = nil
        chatMessages.removeAll()
        isGenerating = false
        projectService.createDefaultProject(template: projectTemplate)
        previewService.stop()
        previewService.logs.removeAll()
        orchestration.lastBuildError = nil
        orchestration.lastBuildDiagnostics.removeAll()
        orchestration.pendingSystemMessages.removeAll()
        orchestration.state = .idle
        // Re-build the default scaffold so the Preview tab shows
        // something the moment the new session starts, just like
        // it does on first launch.
        await orchestration.buildCurrentWorkspace()
    }

    /// Switch the current project template. No-op if the template
    /// is already active. Cancels any in-flight generation, wipes
    /// the old workspace (chat transcript, project files, preview
    /// bundle), then rebuilds from the new template's scaffold.
    /// Same cancel-and-await discipline as `startNewSession`.
    func setTemplate(_ newTemplate: ProjectTemplate) async {
        guard newTemplate != projectTemplate else { return }
        projectTemplate = newTemplate
        await startNewSession()
    }

    /// Retry the preview pipeline. If we already have a built bundle,
    /// this is a cheap WebView reload. If the last build failed or no
    /// bundle exists yet, rebuild the current workspace first so the
    /// Preview screen's "Retry" button is actually meaningful.
    func refreshPreview() async {
        if previewService.entryPath != nil, case .error = orchestration.state {
            await orchestration.buildCurrentWorkspace()
            return
        }
        if previewService.entryPath == nil {
            await orchestration.buildCurrentWorkspace()
            return
        }
        previewService.reload()
    }

    /// Called by `PreviewScreen` whenever the WKWebView's script
    /// bridge reports an `.error`-level log entry. We dedupe
    /// against `previewService.lastRuntimeError` so a screenful of
    /// repeated console.error spam from the same exception only
    /// produces a single chat system message. The structured
    /// error is also stashed on `previewService.lastRuntimeError`
    /// so the next prompt build can include it for the model.
    func recordPreviewRuntimeError(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if previewService.lastRuntimeError == trimmed { return }
        previewService.lastRuntimeError = trimmed
        chatMessages.append(ChatMessage(
            role: .system,
            text: "Preview runtime error:\n\(trimmed)"
        ))
        PuckyLog.chat.error(
            "[chat] preview runtime error: \(trimmed, privacy: .public)"
        )
    }

    /// Public entry point used by `ChatScreen`. Synchronous so the
    /// view can fire and forget; the actual work runs as an owned
    /// `Task` we can cancel via `startNewSession()`.
    func sendMessage(_ text: String) {
        // Replace any in-flight generation. The user kicked off a
        // new turn before the previous one finished — abandon the
        // old work cleanly.
        generationTask?.cancel()
        generationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runGeneration(text: text)
        }
    }

    private func runGeneration(text: String) async {
        PuckyLog.chat.notice(
            "[chat] sendMessage textLen=\(text.count, privacy: .public) historyMsgs=\(self.chatMessages.count, privacy: .public)"
        )
        let userMessage = ChatMessage(role: .user, text: text)
        chatMessages.append(userMessage)

        isGenerating = true
        defer { isGenerating = false }

        // Append an empty assistant message that we stream tokens into.
        let assistantMessage = ChatMessage(role: .assistant)
        chatMessages.append(assistantMessage)
        let messageIndex = chatMessages.count - 1

        // Build a multi-turn history from the visible chat. The model
        // sees every prior user/assistant exchange so a follow-up
        // "yes" actually refers to the question it asked.
        // Render the history with structural file dedup. The
        // renderer walks every prior `.file` item and only keeps
        // content for the latest snapshot of each path; older
        // instances become path-only markers. The system prompt's
        // file dump uses the `mentionedPaths` set to avoid
        // duplicating files that history already covers.
        let rendered = ChatHistoryRenderer.render(
            messages: chatMessages,
            upTo: messageIndex
        )
        let history: [Gemma4ToolPromptBuilder.Turn] = rendered.turns.map {
            .init(role: $0.role, content: $0.content)
        }
        let systemPrompt = Self.systemPrompt(
            for: projectFiles,
            template: projectService.template,
            lastBuildError: orchestration.lastBuildError,
            lastRuntimeError: previewService.lastRuntimeError,
            pathsCoveredByHistory: rendered.mentionedPaths
        )
        PuckyLog.chat.notice(
            "[chat] generate.invoke historyTurns=\(history.count, privacy: .public)"
        )

        // Single inference pass per user message. Gemma 4's training
        // distribution emits parallel tool calls back-to-back inside
        // a single model turn (`<|tool_call>call:a{…}<tool_call|>`
        // followed by `<|tool_call>call:b{…}<tool_call|>` etc — see
        // docs/reviews/gemma4-function-calling-research.md), and our
        // streaming handler picks each one up as soon as its closing
        // tag arrives. So a "build me tic tac toe" prompt produces
        // every needed file in one turn, no continuation prompt
        // required. If the build fails after applying patches, we
        // surface the error inline as a system chat message and the
        // user re-prompts to fix it. We deliberately do NOT loop on
        // synthesised "ok" tool responses because (a) replaying the
        // assistant's prior tool calls verbatim makes the next
        // prefill cost grow with file size and trips jetsam on E4B,
        // and (b) compacting that replay strips the file body the
        // model needs to stay coherent across iterations.
        let prompt = Gemma4ToolPromptBuilder.prompt(
            system: systemPrompt,
            history: history,
            tools: PuckyTools.all
        )
        PuckyLog.chat.notice(
            "[chat] generate.start promptChars=\(prompt.count, privacy: .public)"
        )

        let handler = Gemma4StreamingHandler()
        var processedToolCount = 0
        var inferenceError: (any Error)? = nil
        do {
            for try await chunk in modelService.generate(rawPrompt: prompt) {
                // Bail if a `startNewSession()` cancelled us. The
                // index we captured at the top of this function may
                // already be out of bounds.
                if Task.isCancelled { return }
                let visible = handler.ingest(chunk)
                guard messageIndex < chatMessages.count else { return }
                if !visible.isEmpty {
                    chatMessages[messageIndex].appendText(visible)
                }
                chatMessages[messageIndex].liveTool = Self.liveChip(from: handler.liveToolStatus)
                while handler.toolCalls.count > processedToolCount {
                    let call = handler.toolCalls[processedToolCount]
                    let path: String = {
                        if case .string(let p) = call.arguments["path"] { return p }
                        return "?"
                    }()
                    PuckyLog.tool.notice(
                        "[tool] parsed name=\(call.name, privacy: .public) path=\(path, privacy: .public)"
                    )
                    if let chip = Self.settledChip(for: call) {
                        chatMessages[messageIndex].appendToolCall(chip)
                    }
                    processedToolCount += 1
                }
            }
        } catch {
            inferenceError = error
            PuckyLog.chat.error(
                "[chat] inference failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        if Task.isCancelled || messageIndex >= chatMessages.count { return }
        let truncatedToolStatus = handler.liveToolStatus
        let trailing = handler.flush()
        if !trailing.isEmpty {
            chatMessages[messageIndex].appendText(trailing)
        }
        chatMessages[messageIndex].liveTool = nil
        while handler.toolCalls.count > processedToolCount {
            let call = handler.toolCalls[processedToolCount]
            if let chip = Self.settledChip(for: call) {
                chatMessages[messageIndex].appendToolCall(chip)
            }
            processedToolCount += 1
        }

        PuckyLog.gen.notice(
            "[gen] turn.complete toolCalls=\(handler.toolCalls.count, privacy: .public) textTotalLen=\(self.chatMessages[messageIndex].plainText.count, privacy: .public)"
        )

        // Apply every parsed tool call to the project. Build errors
        // are appended to the chat as system messages by
        // OrchestrationService and shown to the user inline.
        // Route every parsed tool call at the CURRENT template's
        // editable file. The model never names a path, so we're
        // the source of truth for what "the code" actually is.
        let editablePath = projectService.editablePath
        let patches = handler.toolCalls.compactMap { call in
            filePatch(from: call, editablePath: editablePath)
        }
        if !patches.isEmpty {
            PuckyLog.orch.notice(
                "[orch] applyAndBuild start patches=\(patches.count, privacy: .public)"
            )
            await orchestration.applyAndBuild(patches: patches)
            PuckyLog.orch.notice(
                "[orch] applyAndBuild done state=\(String(describing: self.orchestration.state), privacy: .public)"
            )

            // Append a tool-result note to the assistant message
            // itself so the model can see, on its next turn, that
            // its own tool call failed. Without this the model only
            // sees the tool-call chip in history and assumes
            // success — the failure note lives in
            // `pendingSystemMessages` which is filtered out of the
            // history rendered to the model. The text we append
            // here is part of the *same model turn* the tool call
            // belonged to, so the connection is unambiguous when
            // the model reads its own history. We deliberately
            // keep the message filename-free so the model doesn't
            // develop the wrong idea that there's more than one
            // file in play.
            if let buildErr = orchestration.lastBuildError {
                chatMessages[messageIndex].appendText(
                    "[Tool call failed: \(buildErr.message). The latest code is shown in the system prompt above. Pick a unique substring that exactly appears in the code and try edit_code again, or use replace_code to rewrite the whole thing.]"
                )
            }

            // Snapshot the post-edit state of each touched file as
            // a `.file(...)` item on this assistant message. The
            // history renderer will dedupe these against any older
            // snapshots of the same path so the next prompt only
            // ships the latest copy of each file. Order matters
            // because these end up in the prompt history: walk the
            // patches in their emission order and dedupe with a
            // Set we only consult to skip repeats. Files for paths
            // whose patch failed (i.e. the workspace state didn't
            // change) are skipped — there is nothing new to
            // snapshot, and the system prompt's initial-state dump
            // already covers them.
            let failedPath = orchestration.lastBuildError?.path
            var seen = Set<String>()
            for patch in patches {
                let path = patch.path
                guard seen.insert(path).inserted else { continue }
                if path == failedPath { continue }
                if let file = projectService.files.first(where: { $0.path == path }) {
                    chatMessages[messageIndex].appendFile(path: path, content: file.content)
                }
            }

            chatMessages.append(contentsOf: orchestration.pendingSystemMessages)
            orchestration.pendingSystemMessages.removeAll()
        }

        // Surface inference failures (model not loaded, MLX threw,
        // etc.) as a system message rather than letting them silently
        // produce an empty assistant turn.
        if let inferenceError {
            chatMessages.append(ChatMessage(
                role: .system,
                text: inferenceError.localizedDescription
            ))
        }

        // Surface any tool calls the parser couldn't make sense of.
        // These would otherwise vanish without a trace because the
        // streaming handler skips unparseable bodies.
        for snippet in handler.malformedCallBodies {
            PuckyLog.tool.error(
                "[tool] malformed call body: \(snippet, privacy: .public)"
            )
            chatMessages.append(ChatMessage(
                role: .system,
                text: "The model emitted a tool call I couldn't parse: \(snippet)"
            ))
        }

        // The only silent failure mode worth surfacing is a tool call
        // that ran out of token budget mid-stream. Plain prose with
        // no tool calls is normal conversation and intentionally not
        // flagged as an error. The truncation surface fires even
        // when EARLIER tool calls in the same turn succeeded — those
        // earlier files are real, but the user still needs to know
        // the work is partial.
        if let truncated = truncatedToolStatus {
            PuckyLog.chat.notice(
                "[chat] tool call truncated at maxTokens path=\(truncated, privacy: .public) afterToolCalls=\(handler.toolCalls.count, privacy: .public)"
            )
            let priorTools = handler.toolCalls.count
            let detail = priorTools > 0
                ? "\(priorTools) earlier tool call\(priorTools == 1 ? "" : "s") succeeded but the model ran out of token budget while writing a file (\(truncated)). The change is partial — re-prompt to finish."
                : "The model ran out of token budget while writing a file (\(truncated)). Try asking for a smaller change."
            chatMessages.append(ChatMessage(
                role: .system,
                text: detail
            ))
        }

        PuckyLog.chat.notice("[chat] sendMessage end")
    }


    /// Convert a settled `PuckyToolCall` into the chip data the
    /// bubble renders. In single-code mode every call targets the
    /// same piece of code, so the label is just a verb — no path.
    private static func settledChip(for call: PuckyToolCall) -> ToolChipModel? {
        switch call.name {
        case "replace_code":
            return ToolChipModel(kind: .writeFile, label: "Rewrote code")
        case "edit_code":
            return ToolChipModel(kind: .writeFile, label: "Edited code")
        default:
            return ToolChipModel(kind: .generic, label: call.name)
        }
    }

    /// Map the streaming handler's `liveToolStatus` string into a
    /// chip model. The handler produces "Rewriting code" /
    /// "Editing code" / "Calling tool…" in single-code mode.
    private static func liveChip(from status: String?) -> ToolChipModel? {
        guard let status, !status.isEmpty else { return nil }
        return ToolChipModel(kind: .writeFile, label: status)
    }

    /// Build the Gemma 4 system prompt. Every token here becomes
    /// prefill KV cache, so the static prefix is intentionally
    /// tight. The dynamic content (current file contents and any
    /// pending build error) lives at the very end so the static
    /// prefix is stable across turns.
    ///
    /// `pathsCoveredByHistory` is the set of file paths that already
    /// appear (with content) in the rendered chat history. Files in
    /// that set are not inlined here because the history's `.file`
    /// snapshots are the source of truth — duplicating them in the
    /// system prompt would just inflate prefill for nothing.
    nonisolated static func systemPrompt(
        for files: [ProjectFile],
        template: ProjectTemplate = .defaultTemplate,
        lastBuildError: BuildError? = nil,
        lastRuntimeError: String? = nil,
        pathsCoveredByHistory: Set<String> = []
    ) -> String {
        var prompt = template.promptPreamble

        if let err = lastBuildError {
            // Compose the error header. Only include the line
            // number when it's a real Oxc diagnostic (line > 0),
            // not when it's a patch-application error like
            // findNotFound where `:0 — ...` reads like a
            // misleading column reference. Same for the snippet —
            // patch errors have empty snippets and we don't want
            // a trailing blank line. We never show the file path
            // because the model only has one piece of code to
            // edit; surfacing paths just tempts it to hallucinate
            // multi-file workflows.
            var section = "\n\nThe previous turn produced a build error. Fix it before making any other changes:\n\n"
            if err.line > 0 {
                section += "line \(err.line): \(err.message)"
            } else {
                section += err.message
            }
            if !err.snippet.isEmpty {
                section += "\n\(err.snippet)"
            }
            prompt += section
        }

        if let runtimeErr = lastRuntimeError {
            // The build succeeded but the user's app threw at
            // runtime inside the WKWebView (a JS exception, an
            // unhandled promise rejection, or a missing import).
            // The model needs to see this exactly the way it sees
            // build errors, otherwise it will think its last edit
            // worked and keep stacking changes on top of broken
            // code.
            prompt += "\n\nThe preview is currently broken at runtime with this error:\n\n\(runtimeErr)\n\nLook at the code shown below and fix the problem."
        }

        // Initial-state dump of the one editable file. Skipped
        // when history already carries a newer snapshot of it.
        // No path attribute — the model doesn't see or care that
        // this code lives at a path, because from its point of
        // view the two tools are the only interface to it.
        let editable = template.editablePath
        if !pathsCoveredByHistory.contains(editable),
           let app = files.first(where: { $0.path == editable })
        {
            prompt += "\n\n<code>\n\(ChatHistoryRenderer.numberLines(app.content))\n</code>"
        }

        return prompt
    }

}

enum AppTab: Int, CaseIterable {
    case code = 0
    case chat = 1
    case preview = 2

    init?(name: String) {
        switch name.lowercased() {
        case "code": self = .code
        case "chat": self = .chat
        case "preview": self = .preview
        default: return nil
        }
    }
}
