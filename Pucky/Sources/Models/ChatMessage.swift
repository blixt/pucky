import Foundation

/// One message in the chat transcript.
///
/// Assistant messages are an ordered timeline of `Item`s — text and
/// tool-call chips interleaved in the exact order the model emitted
/// them. The bubble walks `items` top-to-bottom so a sequence like
/// `prose → tool call → more prose → another tool call` renders the
/// way it streamed, instead of bunching all the prose at the top and
/// all the chips at the bottom.
///
/// `liveTool` is held off to the side so the bubble can update the
/// pulsing chip on every chunk without producing a new item.
struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: Role
    var items: [Item]
    var liveTool: ToolChipModel?
    let timestamp: Date

    enum Role: String {
        case user
        case assistant
        case system
    }

    /// One element of an assistant (or context) message timeline.
    /// Modeled as an enum so the prompt builder can structurally
    /// dedupe `.file` snapshots across turns: when the same `path`
    /// appears in multiple `.file` items, only the latest one needs
    /// to ship its `content` to the model — the older ones become
    /// path-only markers and the older content drops out of prefill.
    enum Item: Equatable {
        case text(String)
        case toolCall(ToolChipModel)
        /// Snapshot of a file's contents at the moment this message
        /// was produced. Used to give the model the current state of
        /// the project without re-dumping file bodies on every turn:
        /// the prompt builder collapses older `.file` items for the
        /// same `path` to save tokens, since the latest snapshot is
        /// the source of truth.
        case file(path: String, content: String)
    }

    init(
        id: UUID = UUID(),
        role: Role,
        text: String = "",
        liveTool: ToolChipModel? = nil,
        timestamp: Date = .now
    ) {
        self.id = id
        self.role = role
        self.items = text.isEmpty ? [] : [.text(text)]
        self.liveTool = liveTool
        self.timestamp = timestamp
    }

    /// Convenience: every text item joined together. Used for the
    /// model history (which only needs the prose) and for logging.
    var plainText: String {
        items.compactMap {
            if case .text(let s) = $0 { return s }
            return nil
        }.joined()
    }

    /// True if this message has at least one settled tool call item.
    var hasToolCalls: Bool {
        items.contains {
            if case .toolCall = $0 { return true }
            return false
        }
    }

    /// Append a chunk of streamed text. Coalesces with the trailing
    /// text item if there is one, so we don't fragment a single prose
    /// run into many items. If the last item is a tool call, this
    /// starts a new text item, which is exactly what we want for the
    /// "prose / tool call / more prose" timeline.
    mutating func appendText(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        if case .text(let last) = items.last {
            items[items.count - 1] = .text(last + chunk)
        } else {
            items.append(.text(chunk))
        }
    }

    /// Append a settled tool call. The next text chunk will start a
    /// fresh text item below it.
    mutating func appendToolCall(_ chip: ToolChipModel) {
        items.append(.toolCall(chip))
    }

    /// Append a file snapshot. These are invisible to the user
    /// (`ChatBubble` only renders text and tool-call items) and are
    /// produced by `AppState` after each successful `applyAndBuild`
    /// pass so the next prompt has the post-edit state for every
    /// file the model just touched.
    mutating func appendFile(path: String, content: String) {
        items.append(.file(path: path, content: content))
    }
}

/// Lightweight model for a tool-call chip rendered inside the chat
/// bubble. The kind drives the SF Symbol; the label is the
/// human-readable description (typically a path).
struct ToolChipModel: Equatable {
    let kind: Kind
    let label: String

    enum Kind: Equatable {
        case writeFile
        case deleteFile
        case generic
    }
}
