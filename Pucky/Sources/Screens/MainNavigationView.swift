import SwiftUI

/// Horizontally-paged navigation between Code / Chat / Preview.
///
/// Uses a paged `ScrollView` (not `TabView`) so we can observe the
/// continuous horizontal scroll offset via `onScrollGeometryChange`. The
/// rope indicator on the Dynamic Island tracks this offset 1:1, so the
/// accent segment slides along with the user's finger.
struct MainNavigationView: View {
    @Environment(AppState.self) private var appState

    /// Continuous scroll progress, 0 = Code, 1 = Chat, 2 = Preview.
    @State private var scrollProgress: CGFloat = CGFloat(AppTab.chat.rawValue)
    /// The tab that the scroll view has snapped to (drives `AppState.selectedTab`).
    /// Starts as `nil` so setting it to `.chat` in `.task` triggers an
    /// initial scroll to the Chat page.
    @State private var scrolledTab: AppTab?

    /// Whether the user has ever swiped between screens. Persisted so
    /// the swipe hint stops appearing once they understand the gesture.
    @AppStorage("PuckyHasSwiped") private var hasSwiped: Bool = false
    @State private var showSwipeHint: Bool = false

    /// Allow `xcrun simctl launch ... -PUCKY_INITIAL_TAB code|chat|preview`
    /// so a screenshot script can land on any tab without rebuilding.
    /// Scoped to `#if DEBUG` so it never ships in a release build.
    private var initialTab: AppTab {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "PUCKY_INITIAL_TAB"),
           let parsed = AppTab(name: raw) {
            return parsed
        }
        #endif
        return .chat
    }

    var body: some View {
        GeometryReader { geo in
            let pageWidth = geo.size.width

            ZStack(alignment: .top) {
                PK.bg.ignoresSafeArea()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        CodeScreen()
                            .frame(width: pageWidth)
                            .id(AppTab.code)
                            .accessibilityIdentifier("Tab_Code")
                        ChatScreen()
                            .frame(width: pageWidth)
                            .id(AppTab.chat)
                            .accessibilityIdentifier("Tab_Chat")
                        PreviewScreen(
                            onSwipeBack: {
                                // Programmatic tab change — still
                                // honoured by `scrollPosition(id:)`
                                // even while the pager's user-
                                // driven scrolling is disabled.
                                scrolledTab = .chat
                            }
                        )
                            .frame(width: pageWidth)
                            .id(AppTab.preview)
                            .accessibilityIdentifier("Tab_Preview")
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrolledTab, anchor: .leading)
                // Freeze the pager's own pan gesture while the user
                // is on the Preview tab. WKWebView owns the touches
                // inside the webview (cube rotation, scroll, etc.)
                // and the outer scroll view would otherwise still
                // run its horizontal pan in parallel, stealing
                // drags that were meant for the content. The
                // Preview screen reinstates tab-switching via a
                // dedicated left-edge drag zone that programmatic-
                // ally calls `onSwipeBack`.
                .scrollDisabled(appState.selectedTab == .preview)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.x / max(pageWidth, 1)
                } action: { _, newProgress in
                    scrollProgress = newProgress
                }
                .onChange(of: scrolledTab) { old, new in
                    if let t = new {
                        appState.selectedTab = t
                    }
                    // Once the user has actually moved between pages,
                    // we know they get the gesture — retire the hint
                    // permanently.
                    if old != nil, old != new, !hasSwiped {
                        hasSwiped = true
                        withAnimation(.easeOut(duration: 0.3)) {
                            showSwipeHint = false
                        }
                    }
                }
                .task {
                    // Snap to the default tab after the scroll view
                    // has laid out its content.
                    try? await Task.sleep(for: .milliseconds(1))
                    let tab = initialTab
                    scrolledTab = tab
                    scrollProgress = CGFloat(tab.rawValue)

                    // Reveal the swipe hint a beat after the hero
                    // text has settled, then auto-fade it after a
                    // few seconds so it's never load-bearing.
                    if !hasSwiped {
                        try? await Task.sleep(for: .milliseconds(900))
                        withAnimation(.easeOut(duration: 0.45)) {
                            showSwipeHint = true
                        }
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation(.easeOut(duration: 0.6)) {
                            showSwipeHint = false
                        }
                    }
                }
                .ignoresSafeArea(.container, edges: .top)

                // Rope indicator — centred horizontally, pinned to the top
                // so it aligns with the Dynamic Island.
                IslandRope(
                    scrollProgress: scrollProgress,
                    tabCount: AppTab.allCases.count
                )
                .frame(maxWidth: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .ignoresSafeArea(.all)

                // First-launch swipe affordance. Two faint chevron
                // arrows hugging the screen edges with the word
                // "swipe" between them — only ever shown until the
                // user actually swipes once.
                if showSwipeHint && scrolledTab == .chat {
                    SwipeHintOverlay()
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(PK.bg)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("MainTabView")
    }
}

/// Quiet first-launch teaching aid for the page swipe gesture. Two
/// inward-pulsing chevrons with a single-word label, centred so the
/// user reads "← swipe →" without it feeling like a tutorial popover.
/// Auto-fades after a few seconds, never reappears once the user has
/// successfully swiped.
private struct SwipeHintOverlay: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "chevron.compact.left")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(PK.textDim)
                .offset(x: pulse ? -6 : 0)
            Text("swipe")
                .font(PK.sans(11, weight: .medium))
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(PK.textDim)
            Image(systemName: "chevron.compact.right")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(PK.textDim)
                .offset(x: pulse ? 6 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 140)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityHidden(true)
    }
}
