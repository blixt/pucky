import Foundation

/// Manages the virtual project file system.
/// Files exist in memory and in app's Documents directory.
///
/// Pucky ships tiny starter scaffolds via the `ProjectTemplate`
/// catalog. The user — and the model — only ever touches a single
/// editable file; the rest of the scaffold is locked. Single-file
/// mode makes the model's job tractable: Gemma 4 E2B doesn't have
/// to coordinate changes across files, and the tool surface
/// collapses to "rewrite this file" vs "edit this file".
///
/// `applyPatches` enforces the rule at runtime: any patch whose
/// path doesn't match `template.editablePath` is rejected as
/// `scaffoldLocked`.
@MainActor
@Observable
final class ProjectService {
    var files: [ProjectFile] = []
    /// The template the current workspace was created from. The
    /// Code screen, the Oxc transformer, and `applyPatches` all
    /// consult this to pick the right editable path.
    private(set) var template: ProjectTemplate = .defaultTemplate
    private let projectDirectory: URL

    init() {
        projectDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "project", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    }

    /// The project-relative path of the single file the user (and
    /// the model) is allowed to edit in the current template.
    var editablePath: String { template.editablePath }

    /// Project files, filtered to the one that is user-editable.
    /// The Code screen renders this list; the user never sees
    /// scaffold files like `src/index.ts` or `package.json`.
    var editableFiles: [ProjectFile] {
        files.filter { $0.path == editablePath }
    }

    enum PatchError: Error, LocalizedError {
        case invalidPath(String)
        case scaffoldLocked(path: String)
        case fileNotFound(path: String)
        case findNotFound(path: String, find: String)
        case findNotUnique(path: String, find: String, occurrences: Int)

        /// The file path the failing patch was targeting, when
        /// known. Lets `OrchestrationService` build a `BuildError`
        /// pointing at the file that actually failed instead of
        /// guessing with `patches.first`.
        var path: String? {
            switch self {
            case .invalidPath(let p),
                 .scaffoldLocked(let p),
                 .fileNotFound(let p),
                 .findNotFound(let p, _),
                 .findNotUnique(let p, _, _):
                return p
            }
        }

        var errorDescription: String? {
            switch self {
            case .invalidPath(let p):
                return "Invalid path: \(p)"
            case .scaffoldLocked:
                // Unreachable from model-generated patches in
                // normal flow — `filePatch(from:)` injects the
                // current template's editable path and the model
                // never supplies a path itself. Kept as a
                // defensive guard; the message is intentionally
                // generic so a fallback trigger doesn't leak a
                // filename into the chat.
                return "The tool call targeted code that isn't editable."
            case .fileNotFound:
                return "The code is not available to edit."
            case .findNotFound(_, let f):
                return "The find string was not found in the code. Find string was: \(Self.snippet(f))"
            case .findNotUnique(_, let f, let n):
                return "The find string matches \(n) places in the code. Provide enough surrounding context for it to be unique. Find string was: \(Self.snippet(f))"
            }
        }

        private static func snippet(_ s: String) -> String {
            if s.count <= 80 { return s }
            return String(s.prefix(80)) + "…"
        }
    }

    /// Validates a relative path: no leading slash, no `..`, no `.`,
    /// no empty components (so `foo//bar` and `dir/` are rejected).
    private func validate(path: String) throws {
        guard !path.isEmpty else { throw PatchError.invalidPath("empty") }
        guard !path.hasPrefix("/") else { throw PatchError.invalidPath(path) }
        // `omittingEmptySubsequences: false` matters: the default
        // version silently strips `//` and trailing `/`, which would
        // make the empty-component check below dead code.
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for c in components {
            if c == ".." || c == "." || c.isEmpty {
                throw PatchError.invalidPath(path)
            }
        }
    }

    func applyPatches(_ patches: [FilePatch]) throws {
        for patch in patches {
            try validate(path: patch.path)
            // The scaffold is immutable. Any attempt to write,
            // edit, or delete anything other than the current
            // template's editable file is a programming error
            // upstream — `filePatch(from:)` hard-codes the path —
            // but we defend at this boundary too because the model
            // can still emit unexpected tool calls, and we want a
            // clean error surface rather than a silently
            // corrupted scaffold.
            if patch.path != editablePath {
                throw PatchError.scaffoldLocked(path: patch.path)
            }
            switch patch {
            case .write(let path, let text):
                try writeFile(path: path, content: text)

            case .edit(let path, let find, let replace):
                guard let index = files.firstIndex(where: { $0.path == path }) else {
                    throw PatchError.fileNotFound(path: path)
                }
                let current = files[index].content
                let occurrences = current.components(separatedBy: find).count - 1
                if occurrences == 0 {
                    throw PatchError.findNotFound(path: path, find: find)
                }
                if occurrences > 1 {
                    throw PatchError.findNotUnique(path: path, find: find, occurrences: occurrences)
                }
                let updated = current.replacingOccurrences(of: find, with: replace)
                try writeFile(path: path, content: updated)

            case .delete:
                // Delete is unreachable in single-file mode — the
                // path check above bounces any non-editable path,
                // and the editable path can't be deleted.
                throw PatchError.scaffoldLocked(path: patch.path)
            }
        }
    }

    private func writeFile(path: String, content: String) throws {
        let language = ProjectFile.Language.from(filename: path)
        if let index = files.firstIndex(where: { $0.path == path }) {
            files[index].content = content
            files[index].lastModified = .now
            try persist(files[index])
        } else {
            let file = ProjectFile(
                name: URL(filePath: path).lastPathComponent,
                path: path,
                content: content,
                language: language
            )
            files.append(file)
            try persist(file)
        }
    }

    private func persist(_ file: ProjectFile) throws {
        let fileURL = projectDirectory.appending(path: file.path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try file.content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Wipe the current workspace and rebuild it from the scaffold
    /// for `template`. Used on first launch, when the user switches
    /// templates from the chat hero picker, and when
    /// `AppState.startNewSession` kicks a new project. Also clears
    /// any previous template's files off disk so the Oxc
    /// transformer never sees stale scaffolding.
    func createDefaultProject(template: ProjectTemplate = .defaultTemplate) {
        self.template = template

        // Purge whatever was in the project directory from a
        // previous template so the transformer never sees stale
        // files from a different starter.
        try? FileManager.default.removeItem(at: projectDirectory)
        try? FileManager.default.createDirectory(
            at: projectDirectory,
            withIntermediateDirectories: true
        )

        files = ProjectScaffold.files(for: template)
        // Materialize every file on disk so callers that read
        // straight from the filesystem (or third-party tools) see
        // the same state the in-memory `files` array reports.
        for file in files {
            try? persist(file)
        }
    }
}

extension ProjectFile.Language {
    static func from(filename: String) -> ProjectFile.Language {
        if filename.hasSuffix(".tsx") { return .typescriptReact }
        if filename.hasSuffix(".ts") { return .typescript }
        if filename.hasSuffix(".js") { return .javascript }
        if filename.hasSuffix(".json") { return .json }
        return .unknown
    }
}
