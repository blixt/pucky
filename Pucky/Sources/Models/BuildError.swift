import Foundation

/// A single build failure surfaced to the model on the next turn so
/// it can fix what it just broke. Carries enough context (the file
/// path, the line number, and a few lines of surrounding source)
/// that Gemma 4 can write a precise edit_file call without having
/// to re-read the whole project.
struct BuildError: Equatable {
    let path: String
    let line: Int
    let column: Int
    let message: String
    /// Pre-formatted snippet of the offending line plus a couple of
    /// neighbours, with a `>` marker on the failing line. Built by
    /// `BuildError.snippet(from:line:context:)` so the formatting is
    /// consistent across call sites.
    let snippet: String

    /// Render a snippet around `line` with `context` lines of
    /// surrounding source on each side. Lines are 1-indexed and the
    /// failing line is prefixed with `>`. Tabs are preserved.
    static func snippet(from source: String, line: Int, context: Int = 2) -> String {
        let lines = source.components(separatedBy: "\n")
        guard !lines.isEmpty else { return "" }
        let target = max(1, line)
        let start = max(1, target - context)
        let end = min(lines.count, target + context)
        var out: [String] = []
        let pad = String(end).count
        for n in start...end {
            let prefix = n == target ? "> " : "  "
            let num = String(n).padded(toWidth: pad)
            out.append("\(prefix)\(num) | \(lines[n - 1])")
        }
        return out.joined(separator: "\n")
    }
}

private extension String {
    func padded(toWidth width: Int) -> String {
        if count >= width { return self }
        return String(repeating: " ", count: width - count) + self
    }
}
