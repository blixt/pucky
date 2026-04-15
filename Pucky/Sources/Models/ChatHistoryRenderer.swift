import Foundation

/// Pure helper that takes a chat transcript and renders it into the
/// pieces the prompt builder needs:
///
/// - the set of file paths that have a `.file` snapshot somewhere in
///   history (so the system prompt knows which initial-state files
///   to inline and which to skip),
/// - the prose+tool-call+file-snapshot text for each user/assistant
///   turn, with `.file` items deduplicated so each path's content
///   only ships in its latest occurrence.
///
/// All logic is pure functions on plain values so it can be unit
/// tested without standing up an `AppState`, a `ModelService`, or
/// any of the SwiftUI plumbing.
enum ChatHistoryRenderer {

    /// One rendered turn ready to feed to `Gemma4ToolPromptBuilder`.
    struct RenderedTurn: Equatable {
        let role: String   // "user" or "model"
        let content: String
    }

    /// Result of rendering a chat history.
    struct Rendered: Equatable {
        let turns: [RenderedTurn]
        /// Every file path the history mentioned (in any
        /// `.file` item, including the superseded ones).
        let mentionedPaths: Set<String>
    }

    /// Render messages `[0, upTo)` into model history turns.
    ///
    /// `upTo` is the index of the in-flight assistant message that
    /// the model is about to fill in — it must be excluded so we
    /// don't echo an empty turn back to the model.
    static func render(
        messages: [ChatMessage],
        upTo: Int
    ) -> Rendered {
        let slice = Array(messages.prefix(upTo))

        // First pass: figure out which (messageIndex, itemIndex)
        // owns the latest snapshot of each path.
        var latestOwner: [String: ItemAddress] = [:]
        var mentionedPaths: Set<String> = []
        for (mIdx, message) in slice.enumerated() {
            for (iIdx, item) in message.items.enumerated() {
                guard case .file(let path, _) = item else { continue }
                mentionedPaths.insert(path)
                latestOwner[path] = ItemAddress(messageIndex: mIdx, itemIndex: iIdx)
            }
        }

        // Second pass: render each user/model message into a turn.
        // System messages are chat-side build notes and don't go to
        // the model.
        var turns: [RenderedTurn] = []
        for (mIdx, message) in slice.enumerated() {
            switch message.role {
            case .user:
                let body = renderItems(
                    message.items,
                    messageIndex: mIdx,
                    latestOwner: latestOwner
                )
                guard !body.isEmpty else { continue }
                turns.append(RenderedTurn(role: "user", content: body))
            case .assistant:
                let body = renderItems(
                    message.items,
                    messageIndex: mIdx,
                    latestOwner: latestOwner
                )
                guard !body.isEmpty else { continue }
                turns.append(RenderedTurn(role: "model", content: body))
            case .system:
                continue
            }
        }
        return Rendered(turns: turns, mentionedPaths: mentionedPaths)
    }

    /// Address of a single item inside the message timeline. Used to
    /// resolve "is this the latest .file for this path" queries.
    private struct ItemAddress: Equatable {
        let messageIndex: Int
        let itemIndex: Int
    }

    /// Render a single message's items in order. Text items pass
    /// through. Tool calls render as a tag-style line so the model
    /// has a record of what it did without us having to replay the
    /// raw `<|tool_call>` markers (those carry full file bodies and
    /// blow up prefill on multi-turn conversations). File items
    /// render either as a numbered code block (if this is the
    /// latest occurrence of that path) or as a single-line marker
    /// (if a later message overrides it).
    private static func renderItems(
        _ items: [ChatMessage.Item],
        messageIndex: Int,
        latestOwner: [String: ItemAddress]
    ) -> String {
        var pieces: [String] = []
        for (iIdx, item) in items.enumerated() {
            switch item {
            case .text(let s):
                if !s.isEmpty { pieces.append(s) }
            case .toolCall(let chip):
                pieces.append(renderToolCallChip(chip))
            case .file(let path, let content):
                let owner = latestOwner[path]
                let isLatest = owner?.messageIndex == messageIndex
                    && owner?.itemIndex == iIdx
                pieces.append(renderFileItem(path: path, content: content, isLatest: isLatest))
            }
        }
        return pieces.joined(separator: "\n\n")
    }

    private static func renderToolCallChip(_ chip: ToolChipModel) -> String {
        switch chip.kind {
        case .writeFile:
            return chip.label.isEmpty ? "[wrote file]" : "[wrote \(chip.label)]"
        case .deleteFile:
            return chip.label.isEmpty ? "[deleted file]" : "[deleted \(chip.label)]"
        case .generic:
            return chip.label.isEmpty ? "[tool call]" : "[\(chip.label)]"
        }
    }

    /// Render a single file snapshot. Latest occurrences ship the
    /// full numbered body; older ones just say "(superseded by a
    /// later edit)" so the model knows the code changed without
    /// leaking any internal filename or path.
    static func renderFileItem(
        path _: String,
        content: String,
        isLatest: Bool
    ) -> String {
        if !isLatest {
            return "<code>(superseded by a later edit)</code>"
        }
        return "<code>\n\(numberLines(content))\n</code>"
    }

    /// Render a file body with `NN | ` line-number prefixes — the
    /// same shape the editor's `Read` tool uses, which Gemma 4 has
    /// seen in pre-training. The number prefix is not part of the
    /// source text and the model is told that explicitly elsewhere.
    static func numberLines(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        let pad = String(lines.count).count
        return lines.enumerated().map { (idx, line) in
            let n = String(idx + 1)
            let padded = String(repeating: " ", count: max(0, pad - n.count)) + n
            return "\(padded) | \(line)"
        }.joined(separator: "\n")
    }
}
