import Foundation

/// One line of preview-runtime log output. Lives in `Models/` so the
/// service layer (`PreviewService`) doesn't have to depend on the
/// view layer for one of its core types — Codex flagged the original
/// "type defined in PreviewScreen.swift" layout as a backwards
/// dependency direction.
struct LogEntry: Identifiable, Equatable {
    let id: UUID
    let text: String
    let level: Level
    let timestamp: Date

    enum Level: Equatable {
        case info
        case warning
        case error
    }

    init(id: UUID = UUID(), text: String, level: Level, timestamp: Date = .now) {
        self.id = id
        self.text = text
        self.level = level
        self.timestamp = timestamp
    }
}
