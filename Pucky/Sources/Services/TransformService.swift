import Foundation

/// Handles TypeScript/TSX → JavaScript transformation using Oxc via Rust FFI.
///
/// Declared as an actor so the synchronous `OxcBridge.transform` call
/// (which is a blocking C FFI into Rust) runs on a background executor
/// instead of the main thread. Each transform takes roughly 5–50 ms
/// depending on file size — small enough that running it on the main
/// thread wouldn't drop frames on its own, but large enough to matter
/// when the orchestrator transforms several files in sequence during
/// a build loop.
actor TransformService {
    struct TransformResult: Sendable {
        let javascript: String
        let diagnostics: [Diagnostic]
        let sourceMap: String?
    }

    struct Diagnostic: Identifiable, Sendable {
        let id = UUID()
        let severity: Severity
        let message: String
        let line: Int
        let column: Int

        enum Severity: Sendable {
            case error, warning, info
        }
    }

    func transform(source: String, filename: String) async throws -> TransformResult {
        // OxcBridge.transform is synchronous — actor isolation pushes it
        // onto a background executor, off the main thread.
        let result = OxcBridge.transform(source: source, filename: filename)

        if let error = result.error {
            let diagnostic = Diagnostic(
                severity: .error,
                message: error,
                line: 0,
                column: 0
            )
            return TransformResult(
                javascript: "",
                diagnostics: [diagnostic],
                sourceMap: nil
            )
        }

        return TransformResult(
            javascript: result.javascript,
            diagnostics: [],
            sourceMap: nil
        )
    }

    /// Prepare the transformed JS for the WKWebView preview runtime.
    ///
    /// Returns a file map keyed by webview-relative path. The webview
    /// loads each file as an ES module via an importmap, so:
    ///
    ///   - `.tsx` and `.ts` source paths become `.js` (the Pucky
    ///     project keeps source extensions; the runtime expects `.js`
    ///     because that's what `<script type="module">` resolves).
    ///   - Bare relative imports inside the JS (`./foo`, `../bar`) get
    ///     a `.js` suffix appended so the browser can resolve them.
    ///     The model writes its imports without extensions because
    ///     that's what TS source uses, and Oxc preserves them as-is.
    ///   - The entry point's existence is verified up front so a
    ///     missing entry surfaces as a clean error instead of a
    ///     silent webview blank screen.
    func linkTransformed(transformedFiles: [String: String], entryPoint: String) async throws -> [String: String] {
        guard transformedFiles[entryPoint] != nil else {
            throw BundleError.entryPointNotFound(entryPoint)
        }
        var out: [String: String] = [:]
        for (sourcePath, js) in transformedFiles {
            let webPath = Self.webviewPath(forSource: sourcePath)
            out[webPath] = Self.appendJsExtensionToImports(in: js)
        }
        return out
    }

    /// Map a Pucky source path (`src/screens/Foo.tsx`) to the web
    /// path the importmap-driven preview will resolve
    /// (`src/screens/Foo.js`).
    static func webviewPath(forSource path: String) -> String {
        if path.hasSuffix(".tsx") { return String(path.dropLast(4)) + ".js" }
        if path.hasSuffix(".ts") { return String(path.dropLast(3)) + ".js" }
        return path
    }

    /// Rewrite ES module specifiers in transformed JS so relative
    /// imports get an explicit `.js` suffix the browser can resolve.
    /// Bare specifiers (`react`, `react-native`) are left alone — the
    /// importmap takes care of those. Specifiers that already end in
    /// `.js` / `.mjs` / `.json` are also left alone.
    static func appendJsExtensionToImports(in source: String) -> String {
        let pattern = #"(from\s+|import\s*\(\s*)(['"])(\.{1,2}/[^'"\n]+?)\2"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return source }
        let ns = source as NSString
        let matches = re.matches(in: source, range: NSRange(location: 0, length: ns.length))
        var result = source
        // Walk matches in reverse so earlier indices stay valid as we
        // splice in the extension.
        for m in matches.reversed() {
            guard m.numberOfRanges == 4 else { continue }
            let specRange = m.range(at: 3)
            let spec = ns.substring(with: specRange)
            if spec.hasSuffix(".js") || spec.hasSuffix(".mjs") || spec.hasSuffix(".json") {
                continue
            }
            let updated = spec + ".js"
            if let r = Range(specRange, in: result) {
                result.replaceSubrange(r, with: updated)
            }
        }
        return result
    }

    enum BundleError: Error {
        case entryPointNotFound(String)
        case transformFailed(String)
    }
}
