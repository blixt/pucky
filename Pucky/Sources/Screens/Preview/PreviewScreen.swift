import SwiftUI
import WebKit

struct PreviewScreen: View {
    @Environment(AppState.self) private var appState
    @State private var showingLogs = false

    /// Closure the paged navigator injects so we can programmatic-
    /// ally swipe back to the Chat tab when the user drags
    /// inwards from the left edge. The outer pager's user-driven
    /// pan is disabled while Preview is active (otherwise it
    /// fights with WKWebView for every touch), so this is the
    /// only way out.
    var onSwipeBack: () -> Void = {}

    /// Width of the left-edge drag zone that triggers `onSwipeBack`.
    /// Narrow enough to not compete with touches inside the webview
    /// interior but wide enough to feel natural as a "swipe from
    /// the edge" gesture.
    private static let edgeSwipeZoneWidth: CGFloat = 20

    /// How far the finger must travel to the right before the
    /// edge swipe commits to a tab change. Mirrors iOS's native
    /// back-swipe threshold, roughly.
    private static let edgeSwipeCommitDistance: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            ZStack(alignment: .leading) {
                previewContent
                if showingLogs {
                    logOverlay
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // Left-edge swipe zone. Sits on top of the webview
                // so it receives the touch before the webview does,
                // and uses a horizontal DragGesture that only
                // commits on a meaningful rightward drag. Any
                // other touch pattern (tap, vertical scroll) falls
                // through to the content because the zone is very
                // narrow and the gesture is drag-only.
                Color.clear
                    .frame(width: Self.edgeSwipeZoneWidth)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 12, coordinateSpace: .local)
                            .onEnded { value in
                                if value.translation.width > Self.edgeSwipeCommitDistance
                                    && abs(value.translation.height) < 60
                                {
                                    onSwipeBack()
                                }
                            }
                    )
                    .accessibilityHidden(true)
            }
        }
        .background(PK.bg.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.22), value: showingLogs)
        .accessibilityIdentifier("PreviewScreen")
    }

    // MARK: — Header

    /// Compact: status dot + label on the left, icon buttons on the
    /// right. The label is dropped entirely while the runtime is
    /// happy and idle so the chrome reduces to a single 6pt dot.
    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(color: runtimeColor)
            if let label = runtimeLabel {
                Text(label)
                    .font(PK.sans(12, weight: .medium))
                    .foregroundStyle(PK.textDim)
                    .transition(.opacity)
            }
            Spacer()
            IconHeaderButton(
                systemName: "terminal",
                tinted: showingLogs
            ) {
                withAnimation { showingLogs.toggle() }
            }
            .accessibilityIdentifier("ToggleLogs")
            .accessibilityLabel("Toggle console")

            IconHeaderButton(systemName: "arrow.clockwise") {
                reloadPreview()
            }
            .accessibilityIdentifier("ReloadPreview")
            .accessibilityLabel("Reload preview")
        }
        .frame(minHeight: 30)
        .padding(.horizontal, PK.md)
        .padding(.top, PK.headerTop)
        .padding(.bottom, PK.xs)
        .animation(.easeInOut(duration: 0.18), value: runtimeLabel)
    }

    private var runtimeColor: Color {
        if case .error = appState.orchestration.state { return PK.alert }
        if appState.previewService.isRunning { return PK.alive }
        return PK.textFaint
    }

    /// Only surface a label when the runtime is in a transient or
    /// failed state. The healthy "Running" state collapses to a
    /// lone dot so the header stops shouting about itself.
    private var runtimeLabel: String? {
        if case .error = appState.orchestration.state { return "Error" }
        if case .reloading = appState.orchestration.state { return "Reloading" }
        if case .transforming = appState.orchestration.state { return "Building" }
        if case .bundling = appState.orchestration.state { return "Bundling" }
        if !appState.previewService.isRunning { return "Idle" }
        return nil
    }

    // MARK: — Content

    @ViewBuilder
    private var previewContent: some View {
        if case .error(let msg) = appState.orchestration.state {
            errorView(msg)
        } else if let entryPath = appState.previewService.entryPath {
            PreviewWebView(
                entryPath: entryPath,
                bundleRoot: appState.previewService.bundleRoot,
                version: appState.previewService.bundleVersion,
                onLog: { entry in
                    appState.previewService.logs.append(entry)
                    if entry.level == .error {
                        appState.recordPreviewRuntimeError(entry.text)
                    }
                }
            )
            .ignoresSafeArea(edges: .bottom)
            .accessibilityIdentifier("PreviewWebView")
        } else if case .reloading = appState.orchestration.state {
            loadingView
        } else {
            emptyPreview
        }
    }

    private var emptyPreview: some View {
        VStack(alignment: .center, spacing: 8) {
            Spacer().frame(height: 120)
            Text("No preview")
                .font(PK.serif(26, weight: .light))
                .foregroundStyle(PK.text)
            Text("Describe an app in chat to see it live here")
                .font(PK.sans(13))
                .foregroundStyle(PK.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, PK.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("PreviewEmpty")
    }

    private var loadingView: some View {
        VStack(alignment: .center, spacing: 8) {
            Spacer().frame(height: 120)
            Text("Mounting bundle…")
                .font(PK.serif(22, weight: .light))
                .foregroundStyle(PK.text)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .center, spacing: PK.md) {
            Spacer().frame(height: 120)
            Text("Build failed")
                .font(PK.serif(26, weight: .light))
                .foregroundStyle(PK.text)
            Text(message)
                .font(PK.mono(11))
                .foregroundStyle(PK.alert.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding(.horizontal, PK.lg)

            Button {
                reloadPreview()
            } label: {
                Text("Retry")
                    .font(PK.sans(13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(PK.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("PreviewError")
    }

    // MARK: — Logs

    private var logOverlay: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Console")
                        .font(PK.sans(12, weight: .semibold))
                        .foregroundStyle(PK.text)
                    Spacer()
                    Button {
                        appState.previewService.logs.removeAll()
                    } label: {
                        Text("Clear")
                            .font(PK.sans(11, weight: .medium))
                            .foregroundStyle(PK.textDim)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, PK.md)
                .padding(.vertical, 10)
                Rule()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if appState.previewService.logs.isEmpty {
                            Text("No logs yet")
                                .font(PK.mono(10))
                                .foregroundStyle(PK.textFaint)
                                .padding(.horizontal, PK.md)
                                .padding(.vertical, 6)
                        }
                        ForEach(appState.previewService.logs) { entry in
                            Text(entry.text)
                                .font(PK.mono(10))
                                .foregroundStyle(color(for: entry.level))
                                .padding(.horizontal, PK.md)
                                .padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 220)
            }
            .background(PK.surface)
            .overlay(alignment: .top) { Rule(color: PK.accent.opacity(0.5)) }
        }
        .accessibilityIdentifier("LogOverlay")
    }

    private func color(for level: LogEntry.Level) -> Color {
        switch level {
        case .info: PK.textDim
        case .warning: PK.alert
        case .error: PK.alert
        }
    }

    private func reloadPreview() {
        Task { await appState.refreshPreview() }
    }
}


/// Embeds a `WKWebView` that loads the user's transformed bundle
/// through a custom `pucky://` URL scheme handler instead of
/// `file://`. WKWebView's `file://` origin is extremely restrictive
/// — it refuses to fetch ES modules cross-origin even when they sit
/// next to the entry HTML on disk, which is exactly the layout the
/// preview runtime needs. Routing every fetch through a custom
/// scheme handler makes the whole bundle look same-origin under
/// `pucky://preview/`, so the importmap-driven module graph
/// resolves cleanly.
///
/// `console.log` and friends from inside the runtime get bridged to
/// the SwiftUI `LogEntry` array via a script message handler so the
/// `Logs` overlay actually shows what the model's code is doing.
private struct PreviewWebView: UIViewRepresentable {
    let entryPath: String
    let bundleRoot: URL
    let version: Int
    let onLog: (LogEntry) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLog: onLog) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Bridge `console.*` calls in the page over to the host so
        // the user can see them in the Logs panel.
        let userScript = WKUserScript(
            source: Self.consoleBridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(context.coordinator, name: "puckyConsole")

        // Custom scheme handler — the lifetime is owned by the
        // coordinator so the WKWebView can keep a weak reference.
        let handler = PreviewSchemeHandler(rootURL: bundleRoot, onLog: onLog)
        context.coordinator.handler = handler
        config.setURLSchemeHandler(handler, forURLScheme: "pucky")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.lastEntryPath = entryPath
        context.coordinator.lastVersion = version

        // Compile and install the offline content blocker, then load
        // the entry HTML. Until the blocker is in place we don't
        // start the navigation, so the very first request can't leak.
        Self.installOfflineBlocker(on: webView, onLog: onLog) {
            webView.load(Self.request(entryPath: entryPath, version: version))
        }
        return webView
    }

    /// Compiles the offline content rule list (lazily, the rule
    /// store caches it across launches by identifier) and adds it to
    /// the webview's user content controller. Calls `then` on the
    /// main queue once installation is complete — the caller uses
    /// that hook to defer the first navigation until the blocker is
    /// active. If compilation fails for any reason we still call
    /// `then` so the preview isn't dead-locked, but log a warning so
    /// the failure is visible in the Logs panel.
    private static func installOfflineBlocker(
        on webView: WKWebView,
        onLog: @escaping (LogEntry) -> Void,
        then: @escaping () -> Void
    ) {
        guard let store = WKContentRuleListStore.default() else {
            DispatchQueue.main.async(execute: then)
            return
        }
        store.compileContentRuleList(
            forIdentifier: "com.blixt.pucky.preview.offline",
            encodedContentRuleList: offlineBlockerJSON
        ) { list, error in
            DispatchQueue.main.async {
                if let list {
                    webView.configuration.userContentController.add(list)
                } else if let error {
                    onLog(LogEntry(
                        text: "[Preview] offline blocker compile failed: \(error.localizedDescription)",
                        level: .warning
                    ))
                }
                then()
            }
        }
    }

    /// `WKContentRuleList` JSON that blocks `http(s)` and `wss?`
    /// fetches at the resource layer. Anything else — `pucky://`,
    /// `data:`, `blob:`, `about:` — is allowed. The complementary
    /// `WKNavigationDelegate.decidePolicyFor:` check on the
    /// coordinator denies non-allowlisted schemes for top-level
    /// navigations as a belt-and-braces guard.
    /// Documented at:
    /// https://developer.apple.com/documentation/safariservices/creating-a-content-blocker
    private static let offlineBlockerJSON: String = #"""
    [
      {
        "trigger": { "url-filter": "^https?://" },
        "action": { "type": "block" }
      },
      {
        "trigger": { "url-filter": "^wss?://" },
        "action": { "type": "block" }
      }
    ]
    """#

    func updateUIView(_ webView: WKWebView, context: Context) {
        if version != context.coordinator.lastVersion
            || entryPath != context.coordinator.lastEntryPath
        {
            context.coordinator.lastEntryPath = entryPath
            context.coordinator.lastVersion = version
            // The disk contents under `bundleRoot` have changed but
            // the URL may only differ by a query string or a
            // versioned bundle directory. Force a fresh navigation
            // so the scheme handler reads the newest bytes off disk.
            webView.load(Self.request(entryPath: entryPath, version: version))
        }
    }

    private static func request(entryPath: String, version: Int) -> URLRequest {
        let url = URL(string: "pucky://preview/\(entryPath)?v=\(version)")!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        /// Schemes the WebView is allowed to navigate to. Anything
        /// else gets cancelled at `decidePolicyFor:`. The content
        /// rule list also blocks `http(s)` / `ws(s)` at the
        /// resource layer; this delegate is the belt-and-braces
        /// guard for top-level/frame navigations specifically, in
        /// case some scheme slips past the resource filter.
        static let allowedSchemes: Set<String> = ["pucky", "about", "data", "blob"]

        var lastVersion: Int = -1
        var lastEntryPath: String = ""
        var handler: PreviewSchemeHandler?
        let onLog: (LogEntry) -> Void
        init(onLog: @escaping (LogEntry) -> Void) { self.onLog = onLog }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            if Self.allowedSchemes.contains(scheme) {
                decisionHandler(.allow)
                return
            }
            let target = navigationAction.request.url?.absoluteString ?? "(no url)"
            Task { @MainActor in
                self.onLog(LogEntry(
                    text: "[Preview] BLOCKED navigation to scheme=\(scheme) url=\(target)",
                    level: .error
                ))
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            Task { @MainActor in
                self.onLog(LogEntry(text: "[Preview] navigation failed: \(error.localizedDescription)", level: .error))
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            Task { @MainActor in
                self.onLog(LogEntry(text: "[Preview] load failed: \(error.localizedDescription)", level: .error))
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let level = dict["level"] as? String,
                  let text = dict["text"] as? String
            else { return }
            let lvl: LogEntry.Level
            switch level {
            case "warn": lvl = .warning
            case "error": lvl = .error
            default: lvl = .info
            }
            Task { @MainActor in
                self.onLog(LogEntry(text: text, level: lvl))
            }
        }
    }

    /// Bridges `console.log/info/warn/error` over to the host. Runs
    /// at document-start so it captures everything from the runtime
    /// boot onward.
    private static let consoleBridgeJS: String = #"""
    (function() {
      const post = (level, args) => {
        try {
          const text = args.map(a => {
            if (a instanceof Error) return a.stack || a.message;
            if (typeof a === 'string') return a;
            try { return JSON.stringify(a); } catch (_) { return String(a); }
          }).join(' ');
          window.webkit.messageHandlers.puckyConsole.postMessage({ level, text });
        } catch (_) {}
      };
      const orig = {
        log: console.log.bind(console),
        info: console.info.bind(console),
        warn: console.warn.bind(console),
        error: console.error.bind(console),
      };
      console.log = (...a) => { post('log', a); orig.log(...a); };
      console.info = (...a) => { post('info', a); orig.info(...a); };
      console.warn = (...a) => { post('warn', a); orig.warn(...a); };
      console.error = (...a) => { post('error', a); orig.error(...a); };
      window.addEventListener('error', (e) => post('error', [e.message, e.error && e.error.stack].filter(Boolean)));
      window.addEventListener('unhandledrejection', (e) => post('error', [e.reason]));
    })();
    """#
}

/// Serves the preview bundle from a directory on disk through a
/// custom `pucky://` URL scheme. WKWebView treats every request to
/// this scheme as same-origin, which is what makes the importmap +
/// ES module graph work — `file://` is locked down too tight to
/// fetch sibling `.js` files cross-origin. Mapping is straightforward:
/// the URL path is taken relative to `rootURL`, the file is read off
/// disk, and the response is returned with an appropriate
/// `Content-Type`.
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    let rootURL: URL
    let onLog: (LogEntry) -> Void

    init(rootURL: URL, onLog: @escaping (LogEntry) -> Void) {
        self.rootURL = rootURL
        self.onLog = onLog
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        var relative = url.path
        if relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = "index.html" }

        // Resolve the requested file against the bundle root, then
        // standardize so any `..` segments collapse, and verify the
        // result is still inside `bundleRoot`. Without this check
        // the model's generated TSX could request something like
        // `pucky://preview/../Documents/project/src/App.tsx` and
        // `Data(contentsOf:)` would happily read it — that's a path
        // traversal exfiltrating arbitrary container files. The
        // standardizedFileURL collapses `..` and the prefix check
        // enforces the sandbox.
        let canonicalRoot = rootURL.standardizedFileURL.path
        let candidate = rootURL.appendingPathComponent(relative).standardizedFileURL
        let candidatePath = candidate.path
        let rootBoundary = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        guard candidatePath == canonicalRoot || candidatePath.hasPrefix(rootBoundary) else {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain; charset=utf-8"]
            )!
            urlSchemeTask.didReceive(response)
            let body = "403 Forbidden: \(relative) escapes preview bundle".data(using: .utf8) ?? Data()
            urlSchemeTask.didReceive(body)
            urlSchemeTask.didFinish()
            Task { @MainActor in
                self.onLog(LogEntry(
                    text: "[Preview] BLOCKED path traversal: \(relative)",
                    level: .error
                ))
            }
            return
        }

        let fileURL = candidate
        do {
            let data = try Data(contentsOf: fileURL)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": Self.mimeType(forPath: relative),
                    "Content-Length": String(data.count),
                    "Cache-Control": "no-store, no-cache, must-revalidate",
                    "Pragma": "no-cache",
                    "Expires": "0",
                    // Permissive CORS so the importmap module graph
                    // is happy fetching siblings.
                    "Access-Control-Allow-Origin": "*",
                ]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain; charset=utf-8"]
            )!
            urlSchemeTask.didReceive(response)
            let body = "404 Not Found: \(relative)".data(using: .utf8) ?? Data()
            urlSchemeTask.didReceive(body)
            urlSchemeTask.didFinish()
            Task { @MainActor in
                self.onLog(LogEntry(
                    text: "[Preview] 404 \(relative)",
                    level: .warning
                ))
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Synchronous handler — nothing to cancel.
    }

    private static func mimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}
