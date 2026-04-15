import Foundation

/// A single mutation against the workspace, parsed from one of the
/// model's tool calls. Modeled as an enum so each operation only
/// carries the data it needs and the compiler can keep callers
/// honest. `path` is exposed at the top level for convenience.
enum FilePatch: Equatable {
    /// Create a new file or overwrite an existing one with the
    /// supplied contents. Use sparingly — `edit` is preferred for
    /// changes to existing files because it keeps tool-call payloads
    /// (and prefill cost) tiny.
    case write(path: String, text: String)

    /// Replace exactly one occurrence of `find` inside the file at
    /// `path` with `replace`. Mirrors the semantics of the
    /// editor's exact-string Edit tool: if `find` doesn't appear or
    /// appears more than once, the patch is rejected and surfaced
    /// to the user as a build-style error.
    case edit(path: String, find: String, replace: String)

    /// Remove the file at `path`. No-op if it isn't there.
    case delete(path: String)

    var path: String {
        switch self {
        case .write(let p, _),
             .edit(let p, _, _),
             .delete(let p):
            return p
        }
    }

    /// Short tag used for logging — keeps the log lines structured
    /// without leaking the full file body.
    var kindTag: String {
        switch self {
        case .write: "write"
        case .edit: "edit"
        case .delete: "delete"
        }
    }
}
