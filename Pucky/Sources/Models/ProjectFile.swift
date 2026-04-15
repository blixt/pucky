import Foundation

struct ProjectFile: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var content: String
    var language: Language
    var lastModified: Date

    enum Language: String, Sendable {
        case typescript = "ts"
        case typescriptReact = "tsx"
        case javascript = "js"
        case json = "json"
        case unknown = ""

        var displayName: String {
            switch self {
            case .typescript: "TypeScript"
            case .typescriptReact: "TSX"
            case .javascript: "JavaScript"
            case .json: "JSON"
            case .unknown: "Plain Text"
            }
        }

        /// True if the file should be sent through the Oxc transform pipeline.
        var isTransformable: Bool {
            switch self {
            case .typescript, .typescriptReact, .javascript: true
            case .json, .unknown: false
            }
        }
    }

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        content: String = "",
        language: Language = .unknown,
        lastModified: Date = .now
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.content = content
        self.language = language
        self.lastModified = lastModified
    }
}
