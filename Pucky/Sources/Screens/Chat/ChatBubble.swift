import SwiftUI

/// Editorial chat message — clean, no bubbles, no eyebrow labels.
///
/// - User messages: a subtle surface with rounded corners, right-aligned.
/// - AI messages: plain paragraph text, left-aligned, no background.
/// - System messages: inline amber notice.
struct ChatBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }
    private var isSystem: Bool { message.role == .system }

    var body: some View {
        if isSystem {
            systemMessage
        } else if isUser {
            userMessage
        } else {
            assistantMessage
        }
    }

    private var userMessage: some View {
        HStack {
            Spacer(minLength: 48)
            Text(message.plainText)
                .font(PK.sans(15))
                .foregroundStyle(PK.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(PK.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(.horizontal, PK.md)
        .padding(.vertical, 6)
        .accessibilityIdentifier("ChatBubble_user")
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Walk the timeline in order so prose and tool chips
            // appear in the same sequence the model emitted them.
            // Anything that arrives after a tool call lands below it,
            // not bunched up with the earlier text. `.file` snapshot
            // items are invisible: they exist purely to give the
            // model the post-edit state of each file in the next
            // prompt.
            ForEach(Array(message.items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .text(let text):
                    Text(text)
                        .font(PK.sans(15))
                        .foregroundStyle(PK.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .toolCall(let chip):
                    ToolChip(model: chip, active: false)
                case .file:
                    EmptyView()
                }
            }

            // Live tool call currently being streamed (always pinned
            // to the bottom of the bubble until it settles).
            if let live = message.liveTool {
                ToolChip(model: live, active: true)
            }

            // Truly empty assistant message (no items, no live tool).
            // Show the dots so the user has something to look at while
            // the first token is on its way.
            if message.items.isEmpty && message.liveTool == nil {
                Text("…")
                    .font(PK.sans(15))
                    .foregroundStyle(PK.textDim)
            }
        }
        .padding(.horizontal, PK.md)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("ChatBubble_assistant")
    }

    private var systemMessage: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(PK.alert)
            Text(message.plainText)
                .font(PK.sans(12))
                .foregroundStyle(PK.alert.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PK.md)
        .padding(.vertical, 10)
        .accessibilityIdentifier("ChatBubble_system")
    }
}

/// Inline tool-call chip rendered inside the assistant bubble. The
/// chip leads with an SF Symbol that matches the underlying tool, and
/// the `active` variant pulses that symbol via `symbolEffect` while
/// the call is still streaming.
struct ToolChip: View {
    let model: ToolChipModel
    let active: Bool

    private var systemImage: String {
        switch model.kind {
        case .writeFile: "square.and.pencil"
        case .deleteFile: "trash"
        case .generic: "wrench.and.screwdriver"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? PK.accent : PK.textDim)
                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: active)
            Text(model.label)
                .font(PK.mono(12))
                .foregroundStyle(active ? PK.text : PK.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(PK.surfaceElevated))
    }
}
