import Foundation
import os.log

/// Single source of truth for Pucky's debug instrumentation.
///
/// Every line we log goes through `os_log` under the
/// `dev.pucky.app` subsystem with category-specific tags
/// (`gen`, `tool`, `orch`, `mem`, …) so an external `idevicesyslog`
/// watcher can subscribe to exactly the streams it needs without
/// drowning in UIKit chatter.
///
/// The tags are stable strings that are easy to grep:
///
///     [gen]   inference lifecycle (text/chunks/turn boundaries)
///     [tool]  parsed tool calls and their arguments (paths only,
///             content is summarised because it can be thousands of
///             tokens of TSX)
///     [orch]  OrchestrationService state machine and per-file work
///     [mem]   memory snapshots (already in MemoryProbe)
///     [chat]  AppState user-facing flow (sendMessage start/end)
///
/// We deliberately use `.notice` level so the lines survive past the
/// system log's default debug filter.
enum PuckyLog {
    static let gen = Logger(subsystem: "dev.pucky.app", category: "gen")
    static let tool = Logger(subsystem: "dev.pucky.app", category: "tool")
    static let orch = Logger(subsystem: "dev.pucky.app", category: "orch")
    static let chat = Logger(subsystem: "dev.pucky.app", category: "chat")

    /// Truncate long strings for log lines so a 4 KB TSX file doesn't
    /// blow out the log buffer. The first 120 chars usually contain
    /// the import header which is enough to identify what was emitted.
    static func truncate(_ s: String, max: Int = 120) -> String {
        if s.count <= max { return s }
        let head = s.prefix(max)
        return "\(head)…(+\(s.count - max) chars)"
    }
}
