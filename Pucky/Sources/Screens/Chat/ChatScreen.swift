import SwiftUI

struct ChatScreen: View {
    @Environment(AppState.self) private var appState
    @State private var inputText = ""
    @State private var inputFieldKey = 0  // bumped on send to force-clear `axis: .vertical` TextField
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            chatContent
            Rule()
            inputBar
        }
        .background(PK.bg.ignoresSafeArea())
        .accessibilityIdentifier("ChatScreen")
    }

    // MARK: — Header

    /// A single compact status line under the Dynamic Island.
    /// When the model is loaded and the chat is empty we show
    /// nothing at all — the IslandRope and the centred hero are
    /// enough orientation. As soon as a session is in flight we
    /// surface a `+` button to start a new one.
    private var header: some View {
        HStack(spacing: 10) {
            if !appState.isModelLoaded {
                StatusDot(color: PK.alert)
                Text("Loading \(appState.modelService.modelDisplayName)…")
                    .font(PK.sans(12, weight: .medium))
                    .foregroundStyle(PK.textDim)
            } else if appState.isGenerating {
                StatusDot(color: PK.accent)
                Text(appState.modelService.modelDisplayName)
                    .font(PK.sans(12, weight: .medium))
                    .foregroundStyle(PK.textDim)
            }
            Spacer()
            if !appState.chatMessages.isEmpty {
                IconHeaderButton(systemName: "plus") {
                    Task { await appState.startNewSession() }
                }
                .accessibilityIdentifier("ChatNewSession")
                .accessibilityLabel("Start new session")
            }
        }
        .frame(minHeight: 30)
        .padding(.horizontal, PK.md)
        .padding(.top, PK.headerTop)
        .padding(.bottom, PK.xs)
    }

    // MARK: — Content

    private var chatContent: some View {
        ZStack {
            // The scroll view is the back layer. When the chat is
            // empty we disable its hit testing so taps reach the
            // template picker on top; when a conversation is in
            // flight the picker fades out and the scroll view takes
            // over touch handling for flicks and tool chips.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(appState.chatMessages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }
                    // Sentinel that the scroll view pins to. Any time
                    // the last message's content/status grows, this
                    // view's position changes and
                    // `defaultScrollAnchor(.bottom)` keeps it in view
                    // — same trick WhatsApp/iMessage use.
                    Color.clear
                        .frame(height: 1)
                        .id("chatBottom")
                }
                .padding(.vertical, PK.md)
            }
            .defaultScrollAnchor(.bottom)
            .allowsHitTesting(!appState.chatMessages.isEmpty)
            .animation(.easeOut(duration: 0.18), value: appState.chatMessages.last?.items.count)
            .animation(.easeOut(duration: 0.18), value: appState.chatMessages.last?.plainText)
            .animation(.easeOut(duration: 0.18), value: appState.chatMessages.last?.liveTool)

            // Empty-state hero sits on top so the Menu trigger
            // isn't covered by the scroll view. It's faded out
            // once the user sends their first message, and its
            // hit testing is disabled at the same time so it
            // stops intercepting taps on the scrolling chat.
            templateHero
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(appState.chatMessages.isEmpty ? 1 : 0)
                .allowsHitTesting(appState.chatMessages.isEmpty)
                .accessibilityIdentifier("ChatEmptyState")
        }
        .animation(.easeOut(duration: 0.35), value: appState.chatMessages.isEmpty)
    }

    // MARK: — Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                "",
                text: $inputText,
                prompt: Text("Message Pucky").foregroundColor(PK.textDim),
                axis: .vertical
            )
            .font(PK.sans(17))
            .foregroundStyle(PK.text)
            .tint(PK.accent)
            .lineLimit(1...6)
            .textFieldStyle(.plain)
            .focused($isInputFocused)
            // Vertical TextField + no submitLabel/onSubmit means the
            // keyboard's return key inserts a newline. The send action
            // is owned by the SendButton next to the field, so the two
            // intents are completely separate: return composes,
            // SendButton commits.
            .padding(.vertical, 10)
            .accessibilityIdentifier("ChatInput")
            .id(inputFieldKey)

            SendButton(enabled: canSend, loading: appState.isGenerating) {
                sendMessage()
            }
            .accessibilityIdentifier("ChatSendButton")
            .padding(.bottom, 4)
        }
        .padding(.horizontal, PK.md)
        .padding(.vertical, 8)
        .background(PK.bg)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !appState.isGenerating
    }

    // MARK: — Template hero

    /// "New {App|3D} ▾" — "New" stays in the usual text color, the
    /// template name sits in the hot-pink accent, and a small caret
    /// hints that the name is a tap target. Wrapping the whole row
    /// in a Menu means the user gets the system menu chrome for
    /// free on iOS, with `App` / `3D` as the two options.
    ///
    /// Layout stability is load-bearing here. The bare Text
    /// concatenation used to let SwiftUI's Menu re-measure its
    /// label every time `shortLabel` changed, producing a visible
    /// pop + clip during the transition. Reserving the slot at
    /// the widest template name keeps the Menu's frame pinned and
    /// the transition smooth.
    private var templateHero: some View {
        Menu {
            ForEach(ProjectTemplate.allCases) { option in
                Button {
                    Task { await appState.setTemplate(option) }
                } label: {
                    HStack {
                        Text(option.menuLabel)
                        if option == appState.projectTemplate {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("New")
                    .font(PK.serif(40, weight: .light))
                    .foregroundStyle(PK.text)
                    .fixedSize()

                // The accent-colored template name sits in a
                // fixed slot sized to the widest possible option
                // ("App" in the serif display face). A hidden
                // ZStack layer reserves that width and every
                // concrete label is centred inside it, so the
                // Menu's intrinsic size never changes when the
                // user switches templates.
                ZStack {
                    ForEach(ProjectTemplate.allCases) { option in
                        Text(option.shortLabel)
                            .font(PK.serif(40, weight: .light))
                            .fixedSize()
                            .hidden()
                    }
                    Text(appState.projectTemplate.shortLabel)
                        .font(PK.serif(40, weight: .light))
                        .foregroundStyle(PK.accent)
                        .fixedSize()
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.18), value: appState.projectTemplate)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PK.accent.opacity(0.85))
                    .baselineOffset(-5)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier("TemplatePicker")
        .accessibilityLabel("Template: \(appState.projectTemplate.shortLabel)")
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        // Force-recreate the TextField. With `axis: .vertical` the
        // underlying UITextView occasionally hangs onto its multi-line
        // buffer through a binding update; bumping the id is the
        // reliable way to guarantee the input visibly clears.
        inputFieldKey &+= 1
        appState.sendMessage(text)
    }
}
