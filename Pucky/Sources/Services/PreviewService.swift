import Foundation

/// Owns the preview runtime: writes the user's transformed JS plus
/// the runtime shim into a temp directory and tells the
/// `PreviewScreen` what URL to load in its WKWebView. The shim is
/// regenerated from `PreviewRuntime` on every build so changes to
/// the JS shim ship without any extra wiring.
///
/// On every successful generation:
///
///   1. `OrchestrationService` calls `writeBundle(modules:)` with the
///      file map produced by `TransformService.linkTransformed`.
///   2. We write a brand-new versioned bundle directory containing
///      the runtime files, bundled resources, and user modules.
///   3. `entryPath` points `PreviewScreen` at that new directory and
///      `bundleVersion` is bumped so the WebView wrapper forces a
///      fresh navigation.
@MainActor
@Observable
final class PreviewService {
    var isRunning = false
    var logs: [LogEntry] = []
    /// Bumped on every successful bundle write so the SwiftUI
    /// `WebView` can detect bundle writes or manual reload requests
    /// and force a fresh navigation.
    private(set) var bundleVersion: Int = 0
    /// Relative `pucky://preview/...` path of the bundle entry HTML
    /// for the latest successful build.
    private(set) var entryPath: String? = nil
    /// Most recent runtime error from inside the WKWebView (a JS
    /// exception, an unhandled promise rejection, or a failed
    /// dynamic `import`). Captured by the script-message bridge in
    /// `PreviewWebView.Coordinator` whenever an `.error` log entry
    /// arrives. The next prompt build reads this and feeds it back
    /// to the model so it can see runtime failures it caused, not
    /// just compile-time diagnostics. Cleared on every successful
    /// `writeBundle(...)` because a new bundle invalidates the
    /// previous error.
    var lastRuntimeError: String? = nil

    /// Root directory inside the app's temp area where we keep every
    /// preview bundle. Stable across builds so the WKWebView's
    /// custom-scheme handler can capture it once at construction.
    let bundleRoot: URL = FileManager.default.temporaryDirectory
        .appending(path: "pucky-preview", directoryHint: .isDirectory)

    private var currentBundleDirectoryName: String? = nil

    /// Write a fresh preview bundle for the given template. Each
    /// successful build gets its own versioned directory so the
    /// webview never reuses stale module URLs from a previous build.
    func writeBundle(template: ProjectTemplate, modules: [String: String]) throws {
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        let previousBundleDirectoryName = currentBundleDirectoryName
        let nextVersion = bundleVersion &+ 1
        let bundleDirectoryName = "bundle-\(nextVersion)"
        let bundleDirectory = bundleRoot.appending(path: bundleDirectoryName, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: bundleDirectory)
        try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)

        for entry in template.preview.runtimeFiles {
            try writeTextFile(entry.body, relativePath: entry.path, into: bundleDirectory)
        }

        for resource in template.preview.bundledResources {
            try copyBundledResource(resource, into: bundleDirectory)
        }

        for (relativePath, source) in modules {
            try writeTextFile(source, relativePath: relativePath, into: bundleDirectory)
        }

        bundleVersion = nextVersion
        currentBundleDirectoryName = bundleDirectoryName
        entryPath = "\(bundleDirectoryName)/index.html"
        isRunning = true
        // The new bundle supersedes any error captured against the
        // previous one. If the new code throws too, the script
        // bridge will repopulate this within a few hundred ms of
        // the WebView reload.
        lastRuntimeError = nil
        pruneBundles(keeping: [bundleDirectoryName, previousBundleDirectoryName].compactMap { $0 })
        logs.append(LogEntry(
            text: "[Preview] Wrote \(modules.count) module\(modules.count == 1 ? "" : "s") to \(bundleDirectory.path)",
            level: .info
        ))
    }

    private func writeTextFile(_ body: String, relativePath: String, into bundleDirectory: URL) throws {
        let fileURL = bundleDirectory.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try body.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func copyBundledResource(_ resource: ProjectTemplate.BundledResource, into bundleDirectory: URL) throws {
        guard let source = Bundle.main.url(
            forResource: resource.sourceName,
            withExtension: resource.sourceExtension
        ) else {
            throw BundleError.missingResource(resource.displayName)
        }
        let destination = bundleDirectory.appending(path: resource.destinationPath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func pruneBundles(keeping bundleDirectoryNames: [String]) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: bundleRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let keep = Set(bundleDirectoryNames)
        for url in contents where !keep.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    enum BundleError: Error, LocalizedError {
        case missingResource(String)
        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "Missing bundled preview resource: \(name)"
            }
        }
    }

    func reload() {
        // Reload only makes sense if there's actually a bundle on
        // disk. Bumping `bundleVersion` with no entry path would
        // force the WebView to navigate to nowhere.
        guard entryPath != nil else {
            logs.append(LogEntry(text: "[Preview] Reload skipped: no bundle yet.", level: .warning))
            return
        }
        bundleVersion &+= 1
        logs.append(LogEntry(text: "[Preview] Reload requested", level: .info))
    }

    /// Tear down the preview entirely: delete the on-disk bundle,
    /// reset `bundleVersion` so `PreviewScreen` falls back to the
    /// empty state, and forget the runtime status. Used by
    /// `AppState.startNewSession()` so a "new" session never shows
    /// a stale app from the previous conversation.
    func stop() {
        isRunning = false
        bundleVersion = 0
        entryPath = nil
        currentBundleDirectoryName = nil
        lastRuntimeError = nil
        try? FileManager.default.removeItem(at: bundleRoot)
        logs.append(LogEntry(text: "[Preview] Stopped.", level: .info))
    }
}
