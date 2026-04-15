import Foundation

/// Gemma 4 native function calling: prompt builder, streaming parser,
/// and chunk handler.
///
/// Why this exists
/// ───────────────
/// Gemma 4 ships its own non-JSON wire format for tool definitions and
/// tool calls, built around special tokens that are first-class entries
/// in `tokenizer.json`:
///
///   - `<|tool>`        / `<tool|>`        — declaration block
///   - `<|tool_call>`   / `<tool_call|>`   — assistant-emitted call
///   - `<|tool_response>` / `<tool_response|>` — caller-fed result
///   - `<|"|>`          — string delimiter (NOT ASCII `"`)
///
/// The format is documented at
/// <https://ai.google.dev/gemma/docs/capabilities/text/function-calling-gemma4>
/// and authoritatively defined by `format_function_declaration` in
/// `google/gemma-4-e2b-it/chat_template.jinja`.
///
/// `mlx-swift-lm` 2.30.6 has no `.gemma4` `ToolCallFormat` case — its
/// existing `GemmaFunctionParser` matches Gemma 2/3's
/// `<start_function_call>` protocol and would silently fail on Gemma 4
/// output. So we render the wire format ourselves, parse it ourselves,
/// and feed the resulting `ToolCall`s into Pucky's existing
/// `FilePatch`-based orchestration.
///
/// References:
/// - `mlx-lm/mlx_lm/tool_parsers/gemma4.py` (Python reference parser)
/// - `docs/reviews/gemma4-function-calling-research.md` (full spec)
///
/// This file is intentionally standalone — no `MLXLMCommon` import —
/// because the iOS Simulator can't link MLX (no Metal device), and we
/// want the simulator stub to exercise the same parser as the device.

// MARK: - Local types
//
// We deliberately do NOT use `MLXLMCommon.ToolCall` / `ToolSpec` here.
// Pucky owns the call dispatch (the call → `FilePatch` translation
// happens in `OrchestrationService`), so a tiny standalone shape is
// enough and keeps the simulator path free of MLX.

/// JSON-shaped tool definition. Same structure as
/// `MLXLMCommon.ToolSpec` so existing OpenAI-style schemas drop in.
typealias PuckyToolSpec = [String: any Sendable]

/// A single tool invocation parsed from the model's stream.
struct PuckyToolCall: Hashable, Sendable {
    let name: String
    let arguments: [String: PuckyJSONValue]
}

/// A minimal JSON value enum — same shape as `MLXLMCommon.JSONValue`
/// but defined locally so this file doesn't pull in MLX.
enum PuckyJSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([PuckyJSONValue])
    case object([String: PuckyJSONValue])

    static func from(_ value: Any) -> PuckyJSONValue {
        switch value {
        case is NSNull:
            return .null
        case let b as Bool:
            return .bool(b)
        case let i as Int:
            return .int(i)
        case let d as Double:
            return .double(d)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map { from($0) })
        case let o as [String: Any]:
            return .object(o.mapValues { from($0) })
        default:
            return .string(String(describing: value))
        }
    }
}

// MARK: - Prompt builder

/// Renders Gemma 4 prompts with a tool-declaration block in the system
/// turn. Mirrors `format_function_declaration` byte-for-byte so the
/// prompt stays on the training distribution.
enum Gemma4ToolPromptBuilder {

    /// One turn in a chat history. `role` is `"user"` or `"model"`.
    struct Turn: Sendable {
        let role: String
        let content: String
        init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// Build a multi-turn prompt with optional system text and a tool
    /// declaration block. Output shape:
    /// ```
    /// <bos><|turn>system
    /// {system text}<|tool>declaration:name{...}<tool|>...<turn|>
    /// <|turn>user
    /// {turn 0 user}<turn|>
    /// <|turn>model
    /// {turn 0 assistant}<turn|>
    /// ...
    /// <|turn>user
    /// {latest user}<turn|>
    /// <|turn>model
    /// ```
    /// The trailing `<|turn>model\n` marker invites the assistant to
    /// generate the next response. The last item in `history` MUST be
    /// the user turn the model is responding to.
    static func prompt(
        system: String?,
        history: [Turn],
        tools: [PuckyToolSpec]
    ) -> String {
        var out = "<bos>"

        let hasSystem = (system?.isEmpty == false)
        let hasTools = !tools.isEmpty

        if hasSystem || hasTools {
            out += "<|turn>system\n"
            if let system, !system.isEmpty {
                out += system.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for tool in tools {
                out += "<|tool>"
                out += renderDeclaration(tool)
                out += "<tool|>"
            }
            out += "<turn|>\n"
        }

        for turn in history {
            out += "<|turn>\(turn.role)\n\(turn.content)<turn|>\n"
        }
        out += "<|turn>model\n"
        return out
    }

    /// Build a continuation prompt: same prefix as `prompt(...)` but
    /// the trailing assistant turn is left open and contains both the
    /// prior model output (raw, including the tool call markers) and
    /// the tool responses we want to feed back. The model resumes
    /// inside the same `<|turn>model` it started, which is the shape
    /// Gemma 4 was trained on for multi-step tool use. We do not
    /// append a `<turn|>` closer or open a new model turn here.
    ///
    /// `priorAssistantRaw` is replayed verbatim — including any
    /// `text:<|"|>…<|"|>` file bodies. Compacting that text would
    /// strip context the model needs to remain coherent across
    /// iterations (it would no longer "remember" what it just wrote
    /// to a file). Callers that want to use this should be aware
    /// that the prompt grows with the file size and that on
    /// memory-tight variants like E4B this can push prefill past the
    /// foreground ceiling.
    static func continuation(
        system: String?,
        history: [Turn],
        tools: [PuckyToolSpec],
        priorAssistantRaw: String,
        toolResults: [(name: String, result: String)]
    ) -> String {
        var out = "<bos>"

        let hasSystem = (system?.isEmpty == false)
        let hasTools = !tools.isEmpty

        if hasSystem || hasTools {
            out += "<|turn>system\n"
            if let system, !system.isEmpty {
                out += system.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for tool in tools {
                out += "<|tool>"
                out += renderDeclaration(tool)
                out += "<tool|>"
            }
            out += "<turn|>\n"
        }

        for turn in history {
            out += "<|turn>\(turn.role)\n\(turn.content)<turn|>\n"
        }

        out += "<|turn>model\n"
        out += priorAssistantRaw
        for r in toolResults {
            out += "<|tool_response>"
            out += "response:\(r.name){result:<|\"|>\(r.result)<|\"|>}"
            out += "<tool_response|>"
        }
        return out
    }

    // MARK: - Declaration renderer

    private static func renderDeclaration(_ toolSchema: PuckyToolSpec) -> String {
        guard let function = toolSchema["function"] as? [String: Any],
              let name = function["name"] as? String
        else {
            return ""
        }
        let description = function["description"] as? String ?? ""
        let params = function["parameters"] as? [String: Any]

        var out = "declaration:\(name){description:\(quoted(description))"
        if let params {
            out += ",parameters:{"
            var paramParts: [String] = []

            if let props = params["properties"] as? [String: Any], !props.isEmpty {
                paramParts.append("properties:{\(renderProperties(props))}")
            }
            if let required = params["required"] as? [String], !required.isEmpty {
                paramParts.append("required:[\(required.map(quoted).joined(separator: ","))]")
            }
            let typeString = (params["type"] as? String) ?? "object"
            paramParts.append("type:\(quoted(typeString.uppercased()))")
            out += paramParts.joined(separator: ",")
            out += "}"
        }
        out += "}"
        return out
    }

    private static func renderProperties(_ properties: [String: Any]) -> String {
        // Alphabetical sort matches the Jinja `dictsort`. We don't
        // take a `required` parameter here because the required list
        // is rendered separately by the caller — see how the
        // top-level `parameters` block emits `required:[…]` next to
        // `properties:{…}`.
        let sorted = properties.keys.sorted()
        var pieces: [String] = []
        for key in sorted {
            guard let value = properties[key] as? [String: Any] else { continue }
            pieces.append("\(key):{\(renderPropertyValue(value))}")
        }
        return pieces.joined(separator: ",")
    }

    private static func renderPropertyValue(_ value: [String: Any]) -> String {
        var parts: [String] = []
        if let desc = value["description"] as? String {
            parts.append("description:\(quoted(desc))")
        }
        let type = (value["type"] as? String)?.uppercased() ?? "STRING"

        if type == "STRING", let enumValues = value["enum"] as? [String] {
            parts.append("enum:[\(enumValues.map(quoted).joined(separator: ","))]")
        } else if type == "ARRAY", let items = value["items"] as? [String: Any] {
            parts.append("items:{\(renderPropertyValue(items))}")
        } else if type == "OBJECT", let nested = value["properties"] as? [String: Any] {
            parts.append("properties:{\(renderProperties(nested))}")
            if let nestedRequired = value["required"] as? [String], !nestedRequired.isEmpty {
                parts.append("required:[\(nestedRequired.map(quoted).joined(separator: ","))]")
            }
        }
        if let nullable = value["nullable"] as? Bool, nullable {
            parts.append("nullable:true")
        }
        parts.append("type:\(quoted(type))")
        return parts.joined(separator: ",")
    }

    @inline(__always)
    private static func quoted(_ s: String) -> String {
        // Gemma 4's string delimiter is the special token `<|"|>`, not
        // ASCII `"`. The tokenizer encodes the five characters as a
        // single id.
        "<|\"|>\(s)<|\"|>"
    }
}

// MARK: - Tool call parser

/// Parses a single `call:NAME{...}` payload extracted from between
/// `<|tool_call>` and `<tool_call|>` markers.
///
/// Pucky doesn't go through `MLXLMCommon.ToolCallProcessor` (which can
/// only construct itself from a `ToolCallFormat` enum that has no
/// `.gemma4` case), so this struct is intentionally standalone — no
/// `ToolCallParser` protocol conformance needed.
enum Gemma4ToolCallParser {

    /// Parse the body inside a `<|tool_call>...<tool_call|>` pair.
    static func parseCall(_ content: String) -> PuckyToolCall? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Defensive: strip tags if the caller didn't.
        if let range = text.range(of: "<|tool_call>") {
            text = String(text[range.upperBound...])
        }
        if let range = text.range(of: "<tool_call|>") {
            text = String(text[..<range.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard text.hasPrefix("call:") else { return nil }
        let afterPrefix = text.index(text.startIndex, offsetBy: "call:".count)
        let rest = text[afterPrefix...]

        guard let braceStart = rest.firstIndex(of: "{") else { return nil }
        let name = String(rest[..<braceStart])
        guard !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
        else { return nil }

        guard let braceEnd = findMatchingBrace(in: rest, openIdx: braceStart) else {
            return nil
        }
        let argsStart = rest.index(after: braceStart)
        let argsString = String(rest[argsStart..<braceEnd])

        guard let arguments = parseArgBody(argsString) else { return nil }
        return PuckyToolCall(
            name: name,
            arguments: arguments.mapValues { PuckyJSONValue.from($0) }
        )
    }

    /// Walk a substring starting at `{` and return the index of the
    /// matching `}`. Skips braces inside `<|"|>...<|"|>` string spans.
    private static func findMatchingBrace(
        in s: Substring,
        openIdx: Substring.Index
    ) -> Substring.Index? {
        precondition(s[openIdx] == "{")
        var depth = 0
        var i = openIdx
        var inString = false
        let stringDelim = "<|\"|>"
        while i < s.endIndex {
            if s[i...].hasPrefix(stringDelim) {
                inString.toggle()
                i = s.index(i, offsetBy: stringDelim.count)
                continue
            }
            if !inString {
                if s[i] == "{" { depth += 1 }
                if s[i] == "}" {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Parse `key:value,key:value` body into a `[String: Any]` dict.
    /// Strategy: substitute Gemma 4 string delimiters with placeholders,
    /// quote bare keys to make valid JSON, restore strings, then let
    /// `JSONSerialization` handle the rest.
    private static func parseArgBody(_ body: String) -> [String: Any]? {
        var json = "{" + body + "}"

        var captures: [String] = []
        let stringDelim = "<|\"|>"

        while let openRange = json.range(of: stringDelim) {
            guard let closeRange = json.range(
                of: stringDelim,
                range: openRange.upperBound..<json.endIndex
            ) else {
                return nil
            }
            let captured = String(json[openRange.upperBound..<closeRange.lowerBound])
            captures.append(captured)
            let token = "\u{0001}\(captures.count - 1)\u{0001}"
            json.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: token)
        }

        // Quote bare keys: anything that follows `{` or `,` and ends in `:`.
        if let re = try? NSRegularExpression(
            pattern: "(?<=[{,])(\\w+):", options: []
        ) {
            let range = NSRange(json.startIndex..., in: json)
            json = re.stringByReplacingMatches(
                in: json, options: [], range: range, withTemplate: "\"$1\":"
            )
        }

        // Restore string captures as JSON-encoded strings.
        for (i, captured) in captures.enumerated() {
            let placeholder = "\u{0001}\(i)\u{0001}"
            let encoded: String = {
                guard let data = try? JSONSerialization.data(
                    withJSONObject: [captured], options: [.fragmentsAllowed]
                ),
                      let s = String(data: data, encoding: .utf8) else {
                    return "\"\""
                }
                // Peel the outer `[` `]`.
                return String(s.dropFirst().dropLast())
            }()
            json = json.replacingOccurrences(of: placeholder, with: encoded)
        }

        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any]
        else {
            return nil
        }
        return dict
    }
}

// MARK: - Streaming handler

/// Tiny streaming state machine. Feed it chunks of decoded model
/// output; it returns the user-visible text (tool-call regions
/// swallowed) and accumulates parsed `ToolCall`s.
final class Gemma4StreamingHandler {
    private(set) var toolCalls: [PuckyToolCall] = []
    /// Snippets of tool-call bodies the parser couldn't make sense
    /// of. Surfaced to the chat layer so malformed Gemma 4 emissions
    /// don't disappear without a trace — Codex flagged the previous
    /// "drop and continue" behaviour as the kind of swallowed error
    /// that makes on-device tool use impossible to debug.
    private(set) var malformedCallBodies: [String] = []
    private var buffer = ""
    private var inCall = false

    private let openTag = "<|tool_call>"
    private let closeTag = "<tool_call|>"
    // We also strip the chat-end-of-turn marker if it slips through.
    private let turnEnd = "<turn|>"

    /// A live, human-readable summary of whatever tool call is being
    /// streamed right now (e.g. "Writing src/App.tsx"), or nil when
    /// the model isn't inside a `<|tool_call>` region. Reset to nil
    /// once the call is fully parsed and added to `toolCalls`.
    private(set) var liveToolStatus: String?

    /// Append a streamed chunk. Returns the text that should be shown
    /// to the user (tool-call bytes are swallowed; partial open-tag
    /// suffixes are buffered until the next chunk completes them).
    func ingest(_ chunk: String) -> String {
        var visible = ""
        var remaining = buffer + chunk
        buffer = ""

        while !remaining.isEmpty {
            if inCall {
                // The closer scan must skip occurrences of
                // `<tool_call|>` that appear inside `<|"|>...<|"|>`
                // string spans. Without this, a tool call body that
                // happens to contain the literal substring
                // `<tool_call|>` (e.g. inside a TSX string) would end
                // the call early, parse a truncated body, and
                // desync the rest of the stream.
                if let end = Self.findOutsideStringSpans(closeTag, in: remaining) {
                    let body = String(remaining[..<end.lowerBound])
                    if let call = Gemma4ToolCallParser.parseCall(body) {
                        toolCalls.append(call)
                    } else {
                        malformedCallBodies.append(Self.snippet(of: body))
                    }
                    remaining = String(remaining[end.upperBound...])
                    inCall = false
                    liveToolStatus = nil
                } else {
                    // Need more bytes to find the closer. Try to peek
                    // the call name + path so the UI can show
                    // "Writing src/App.tsx" while the body streams.
                    buffer = remaining
                    liveToolStatus = peekStatus(remaining)
                    return visible
                }
            } else {
                if let start = remaining.range(of: openTag) {
                    visible += stripTurnEnd(String(remaining[..<start.lowerBound]))
                    remaining = String(remaining[start.upperBound...])
                    inCall = true
                    liveToolStatus = "Calling tool…"
                } else {
                    // Hold back a tail that could be the start of a
                    // partial `<|tool_call>` straddling chunks.
                    let keep = min(remaining.count, openTag.count - 1)
                    let split = remaining.index(remaining.endIndex, offsetBy: -keep)
                    visible += stripTurnEnd(String(remaining[..<split]))
                    buffer = String(remaining[split...])
                    return visible
                }
            }
        }
        return visible
    }

    /// Find the first occurrence of `needle` in `haystack` that is
    /// NOT inside a `<|"|>…<|"|>` string span. Returns nil if there
    /// is no unescaped occurrence. Used by `ingest` to scan for
    /// `<tool_call|>` correctly when the model emits the literal
    /// substring inside a string argument.
    static func findOutsideStringSpans(_ needle: String, in haystack: String) -> Range<String.Index>? {
        let stringDelim = "<|\"|>"
        var i = haystack.startIndex
        var inString = false
        while i < haystack.endIndex {
            if haystack[i...].hasPrefix(stringDelim) {
                inString.toggle()
                i = haystack.index(i, offsetBy: stringDelim.count)
                continue
            }
            if !inString && haystack[i...].hasPrefix(needle) {
                let end = haystack.index(i, offsetBy: needle.count)
                return i..<end
            }
            i = haystack.index(after: i)
        }
        return nil
    }

    /// Best-effort live readout of the open tool call. Picks up the
    /// tool name and returns a verb like "Rewriting code" or
    /// "Editing code". Single-code mode means there's no path to
    /// extract and nothing more specific to say.
    private func peekStatus(_ body: String) -> String? {
        guard body.hasPrefix("call:") else { return "Calling tool…" }
        let after = body.dropFirst("call:".count)
        guard let braceIdx = after.firstIndex(of: "{") else { return "Calling tool…" }
        let name = String(after[..<braceIdx])
        guard !name.isEmpty else { return "Calling tool…" }
        return Self.statusLabel(forTool: name)
    }

    private static func statusLabel(forTool name: String) -> String {
        switch name {
        case "replace_code":
            return "Rewriting code"
        case "edit_code":
            return "Editing code"
        default:
            return "\(name)…"
        }
    }

    /// Called once after the stream ends. Flushes any trailing buffer.
    func flush() -> String {
        defer { buffer = "" }
        if inCall {
            // Stream ended mid-tool-call. Parse what we have; if it's
            // unparseable, record the snippet so the chat layer can
            // surface the failure (the existing `liveToolStatus`
            // truncation surface also catches this case but only
            // when zero earlier calls succeeded).
            if let call = Gemma4ToolCallParser.parseCall(buffer) {
                toolCalls.append(call)
            } else if !buffer.isEmpty {
                malformedCallBodies.append(Self.snippet(of: buffer))
            }
            inCall = false
            liveToolStatus = nil
            return ""
        }
        return stripTurnEnd(buffer)
    }

    private static func snippet(of body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 120 { return trimmed }
        return String(trimmed.prefix(120)) + "…"
    }

    private func stripTurnEnd(_ s: String) -> String {
        guard s.contains(turnEnd) else { return s }
        return s.replacingOccurrences(of: turnEnd, with: "")
    }
}

// MARK: - Tool definitions

/// Pucky's two code-mutation tools, expressed as plain JSON-shaped
/// dictionaries. We don't use `MLXLMCommon.Tool<Input, Output>` because
/// dispatch happens in `OrchestrationService`, not via a tool handler
/// closure (and that file would pull MLX onto the simulator path).
///
/// Single-code mode
/// ────────────────
/// Gemma 4 E2B struggles to coordinate edits across multiple files,
/// so Pucky constrains the model to a single piece of code. Both
/// tools therefore omit any `path` argument — the target is always
/// the same and is injected by `filePatch(from:)`. The tool
/// descriptions the model sees never mention a filename either:
/// leaking a path like `App.tsx` trains the model to hallucinate
/// multi-file workflows and emit tool calls with a `path` field
/// that no longer exists.
///
/// The model can only:
///
/// - `replace_code` — rewrite the whole thing.
/// - `edit_code` — surgical find/replace.
///
/// No `write_file`, no `delete_file`, no path argument. Fewer
/// degrees of freedom means the model is less likely to go off the
/// rails, and the prompt stays smaller because we no longer have
/// to teach a file layout.
enum PuckyTools {
    /// Full rewrite. Use when the change is large enough that a
    /// find/replace would be awkward.
    static let replaceCode: PuckyToolSpec = [
        "type": "function",
        "function": [
            "name": "replace_code",
            "description": "Rewrite the entire code with new contents. Use this when the change is large or touches many parts of the code.",
            "parameters": [
                "type": "object",
                "properties": [
                    "text": [
                        "type": "string",
                        "description": "The complete new contents of the code.",
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["text"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    /// Surgical edit: replace exactly one occurrence of `find`
    /// with `replace`. Mirrors the editor's `Edit` tool.
    static let editCode: PuckyToolSpec = [
        "type": "function",
        "function": [
            "name": "edit_code",
            "description": "Replace exactly one occurrence of find with replace inside the code. Prefer this over replace_code for localised changes because the payload is much smaller. The find string must occur exactly once in the code: if it doesn't, include enough surrounding context to make it unique.",
            "parameters": [
                "type": "object",
                "properties": [
                    "find": [
                        "type": "string",
                        "description": "Exact substring to locate inside the code. Must occur exactly once.",
                    ] as [String: any Sendable],
                    "replace": [
                        "type": "string",
                        "description": "Replacement substring. May be empty to delete the matched text.",
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["find", "replace"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    static let all: [PuckyToolSpec] = [editCode, replaceCode]
}

/// Translate a parsed `PuckyToolCall` into a `FilePatch`. Returns nil
/// for unknown tool names or missing/invalid arguments.
///
/// The target path is supplied by the caller (always the current
/// template's editable path). The model never sees or names a file —
/// it only emits `replace_code` / `edit_code` arguments, and we fill
/// in the path at dispatch time. Every starter template routes
/// through this same function, so the template catalog is the
/// single source of truth for "which file gets modified."
func filePatch(from call: PuckyToolCall, editablePath: String) -> FilePatch? {
    switch call.name {
    case "replace_code":
        guard case .string(let text) = call.arguments["text"]
        else { return nil }
        return .write(path: editablePath, text: text)
    case "edit_code":
        guard case .string(let find) = call.arguments["find"], !find.isEmpty,
              case .string(let replace) = call.arguments["replace"]
        else { return nil }
        return .edit(path: editablePath, find: find, replace: replace)
    default:
        return nil
    }
}
