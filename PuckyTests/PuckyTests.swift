import Foundation
import Testing
import Tokenizers
@testable import Pucky

@Suite("ChatMessage items")
struct ChatMessageItemTests {
    @Test func appendTextCoalescesWithLastTextItem() {
        var m = ChatMessage(role: .assistant)
        m.appendText("hello ")
        m.appendText("world")
        #expect(m.items == [.text("hello world")])
    }

    @Test func appendTextStartsNewItemAfterToolCall() {
        var m = ChatMessage(role: .assistant)
        m.appendText("ok, ")
        m.appendToolCall(ToolChipModel(kind: .writeFile, label: "src/A.tsx"))
        m.appendText("done")
        #expect(m.items == [
            .text("ok, "),
            .toolCall(ToolChipModel(kind: .writeFile, label: "src/A.tsx")),
            .text("done"),
        ])
    }

    @Test func appendFileLandsAtEndOfTimeline() {
        var m = ChatMessage(role: .assistant)
        m.appendText("done")
        m.appendFile(path: "src/A.tsx", content: "let x = 1")
        switch m.items.last {
        case .file(let path, let content):
            #expect(path == "src/A.tsx")
            #expect(content == "let x = 1")
        default:
            Issue.record("expected .file to be the last item")
        }
    }

    @Test func plainTextIgnoresToolCallsAndFiles() {
        var m = ChatMessage(role: .assistant)
        m.appendText("hi ")
        m.appendToolCall(ToolChipModel(kind: .writeFile, label: "src/A.tsx"))
        m.appendFile(path: "src/A.tsx", content: "x")
        m.appendText("bye")
        #expect(m.plainText == "hi bye")
    }

    @Test func hasToolCallsReportsCorrectly() {
        var m = ChatMessage(role: .assistant, text: "just talking")
        #expect(!m.hasToolCalls)
        m.appendToolCall(ToolChipModel(kind: .writeFile, label: "x"))
        #expect(m.hasToolCalls)
    }

    @Test func emptyTextChunksAreSkipped() {
        var m = ChatMessage(role: .assistant)
        m.appendText("")
        #expect(m.items.isEmpty)
    }
}

@Suite("ChatHistoryRenderer dedup")
struct ChatHistoryRendererTests {
    @Test func emptySliceProducesNoTurns() {
        let r = ChatHistoryRenderer.render(messages: [], upTo: 0)
        #expect(r.turns.isEmpty)
        #expect(r.mentionedPaths.isEmpty)
    }

    @Test func upToExcludesInFlightAssistant() {
        // The in-flight assistant message must not be rendered as a
        // history turn — that's the slot the model is about to fill.
        let user = ChatMessage(role: .user, text: "hi")
        let assistant = ChatMessage(role: .assistant)
        let r = ChatHistoryRenderer.render(messages: [user, assistant], upTo: 1)
        #expect(r.turns.count == 1)
        #expect(r.turns[0].role == "user")
    }

    @Test func systemMessagesAreDroppedFromModelHistory() {
        let user = ChatMessage(role: .user, text: "hi")
        let sys = ChatMessage(role: .system, text: "Build error: ...")
        let assistant = ChatMessage(role: .assistant, text: "ok")
        let r = ChatHistoryRenderer.render(
            messages: [user, sys, assistant],
            upTo: 3
        )
        #expect(r.turns.count == 2)
        #expect(r.turns.map(\.role) == ["user", "model"])
    }

    @Test func latestFileSnapshotKeepsContent() {
        var m1 = ChatMessage(role: .assistant)
        m1.appendFile(path: "src/A.tsx", content: "first")
        var m2 = ChatMessage(role: .assistant)
        m2.appendFile(path: "src/A.tsx", content: "second")

        let r = ChatHistoryRenderer.render(
            messages: [m1, m2],
            upTo: 2
        )
        #expect(r.mentionedPaths == ["src/A.tsx"])
        // The first turn should mark the older snapshot as superseded.
        #expect(r.turns[0].content.contains("(superseded by a later edit)"))
        #expect(!r.turns[0].content.contains("first"))
        #expect(!r.turns[0].content.contains("path="))
        // The second turn should ship the latest content with line numbers.
        #expect(r.turns[1].content.contains("1 | second"))
        #expect(!r.turns[1].content.contains("src/A.tsx"))
    }

    @Test func differentPathsAreUnaffectedByDedup() {
        var m1 = ChatMessage(role: .assistant)
        m1.appendFile(path: "src/A.tsx", content: "alpha")
        var m2 = ChatMessage(role: .assistant)
        m2.appendFile(path: "src/B.tsx", content: "beta")

        let r = ChatHistoryRenderer.render(messages: [m1, m2], upTo: 2)
        #expect(r.mentionedPaths == ["src/A.tsx", "src/B.tsx"])
        #expect(r.turns[0].content.contains("1 | alpha"))
        #expect(r.turns[1].content.contains("1 | beta"))
    }

    @Test func threeUpdatesOfSamePathOnlyKeepsTheLast() {
        var m1 = ChatMessage(role: .assistant)
        m1.appendFile(path: "src/A.tsx", content: "v1")
        var m2 = ChatMessage(role: .assistant)
        m2.appendFile(path: "src/A.tsx", content: "v2")
        var m3 = ChatMessage(role: .assistant)
        m3.appendFile(path: "src/A.tsx", content: "v3")

        let r = ChatHistoryRenderer.render(messages: [m1, m2, m3], upTo: 3)
        #expect(r.turns.count == 3)
        #expect(r.turns[0].content.contains("(superseded by a later edit)"))
        #expect(r.turns[1].content.contains("(superseded by a later edit)"))
        #expect(r.turns[2].content.contains("1 | v3"))
        #expect(!r.turns[0].content.contains("v1"))
        #expect(!r.turns[1].content.contains("v2"))
    }

    @Test func toolCallChipsRenderInOrderWithText() {
        var m = ChatMessage(role: .assistant)
        m.appendText("Building.")
        m.appendToolCall(ToolChipModel(kind: .writeFile, label: "src/A.tsx"))
        m.appendText("All done.")
        let r = ChatHistoryRenderer.render(messages: [m], upTo: 1)
        let body = r.turns[0].content
        let buildIdx = body.range(of: "Building.")!.lowerBound
        let toolIdx = body.range(of: "[wrote src/A.tsx]")!.lowerBound
        let doneIdx = body.range(of: "All done.")!.lowerBound
        #expect(buildIdx < toolIdx)
        #expect(toolIdx < doneIdx)
    }

    @Test func numberedFileBodyHasOneIndexedPaddedLines() {
        let body = ChatHistoryRenderer.numberLines("a\nb\nc")
        #expect(body == "1 | a\n2 | b\n3 | c")
    }

    @Test func numberedFileBodyPadsLineNumbers() {
        // 12 lines so the line-number column is two characters wide.
        let source = (1...12).map { "line\($0)" }.joined(separator: "\n")
        let body = ChatHistoryRenderer.numberLines(source)
        let lines = body.components(separatedBy: "\n")
        #expect(lines[0] == " 1 | line1")
        #expect(lines[8] == " 9 | line9")
        #expect(lines[9] == "10 | line10")
    }

    @Test func userTurnEditingSameFileSupersedesAssistantSnapshot() {
        // Mixed roles: assistant snapshots a file, then a later user
        // turn re-snapshots it. The assistant's older copy should be
        // superseded by the user's newer one.
        let user1 = ChatMessage(role: .user, text: "build it")
        var assistant1 = ChatMessage(role: .assistant)
        assistant1.appendFile(path: "src/A.tsx", content: "first")
        var user2 = ChatMessage(role: .user, text: "tweak it")
        user2.appendFile(path: "src/A.tsx", content: "tweaked")

        let r = ChatHistoryRenderer.render(
            messages: [user1, assistant1, user2],
            upTo: 3
        )
        // assistant1 (index 1) is superseded by user2 (index 2).
        let assistantTurn = r.turns.first { $0.role == "model" }!
        #expect(assistantTurn.content.contains("(superseded by a later edit)"))
        let lastUserTurn = r.turns.last(where: { $0.role == "user" })!
        #expect(lastUserTurn.content.contains("1 | tweaked"))
    }
}

@Suite("App launch gating")
struct AppLaunchGatingTests {
    @Test func unitTestHostSkipsFullBoot() {
        let shouldBoot = AppState.shouldBootFullApp(
            arguments: ["Pucky"],
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
        )
        #expect(!shouldBoot)
    }

    @Test func uiTestLaunchStillBootsApp() {
        let shouldBoot = AppState.shouldBootFullApp(
            arguments: ["Pucky", "--pucky-ui-test"],
            environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
        )
        #expect(shouldBoot)
    }

    @Test func normalLaunchBootsApp() {
        let shouldBoot = AppState.shouldBootFullApp(
            arguments: ["Pucky"],
            environment: [:]
        )
        #expect(shouldBoot)
    }
}


@Suite("Single-code tool surface")
@MainActor
struct SingleCodeToolTests {
    @Test func replaceCodeRoutesAtEveryTemplatesEditablePath() {
        let text = "export default function App(){}"
        let call = PuckyToolCall(
            name: "replace_code",
            arguments: ["text": .string(text)]
        )
        for template in ProjectTemplate.allCases {
            let patch = filePatch(from: call, editablePath: template.editablePath)
            #expect(patch == .write(path: template.editablePath, text: text))
        }
    }

    @Test func editCodeUsesCallerSuppliedPath() {
        let call = PuckyToolCall(
            name: "edit_code",
            arguments: [
                "find": .string("Hello"),
                "replace": .string("Hi"),
            ]
        )
        let patch = filePatch(from: call, editablePath: "anywhere/App.tsx")
        #expect(patch == .edit(path: "anywhere/App.tsx", find: "Hello", replace: "Hi"))
    }

    @Test func deprecatedToolNamesAreRejected() {
        // write_file / edit_file / delete_file no longer exist in
        // single-code mode; if the model happens to emit one we
        // return nil so it's surfaced as a malformed call rather
        // than silently applied.
        let writeFile = PuckyToolCall(
            name: "write_file",
            arguments: [
                "path": .string("src/Other.tsx"),
                "text": .string("x"),
            ]
        )
        #expect(filePatch(from: writeFile, editablePath: ProjectTemplate.defaultTemplate.editablePath) == nil)

        let deleteFile = PuckyToolCall(
            name: "delete_file",
            arguments: ["path": .string(ProjectTemplate.defaultTemplate.editablePath)]
        )
        #expect(filePatch(from: deleteFile, editablePath: ProjectTemplate.defaultTemplate.editablePath) == nil)
    }

    @Test func projectServiceRejectsScaffoldWrites() throws {
        guard let template = ProjectTemplate.allCases.first(where: { candidate in
            candidate.scaffoldFiles.contains { $0.path != candidate.editablePath }
        }),
        let lockedPath = template.scaffoldFiles.first(where: { $0.path != template.editablePath })?.path
        else {
            Issue.record("expected at least one template with a locked scaffold file")
            return
        }

        let project = ProjectService()
        project.createDefaultProject(template: template)

        // Writing to a scaffold path must fail — it's the
        // defensive guard the user saw leak earlier. The error
        // message is intentionally free of any file path.
        let badPatch = FilePatch.write(path: lockedPath, text: "hacked")
        do {
            try project.applyPatches([badPatch])
            Issue.record("expected scaffoldLocked error")
        } catch let err as ProjectService.PatchError {
            switch err {
            case .scaffoldLocked:
                let message = err.errorDescription ?? ""
                #expect(!message.contains("src/"))
                #expect(!message.contains(".tsx"))
                #expect(!message.contains(".ts"))
            default:
                Issue.record("wrong error: \(err)")
            }
        }
    }

    @Test func projectServiceAcceptsWritesAtEveryTemplatesEditablePath() throws {
        for template in ProjectTemplate.allCases {
            let project = ProjectService()
            project.createDefaultProject(template: template)
            let newBody = "// rewrite for \(template.id)\nexport default 1"
            try project.applyPatches([.write(path: project.editablePath, text: newBody)])
            let updated = project.files.first { $0.path == project.editablePath }
            #expect(updated?.content == newBody)
        }
    }

    @Test func editableFilesReturnsSingleFilePerTemplate() {
        for template in ProjectTemplate.allCases {
            let project = ProjectService()
            project.createDefaultProject(template: template)
            #expect(project.editableFiles.count == 1)
            #expect(project.editableFiles.first?.path == template.editablePath)
        }
    }
}

@Suite("Streaming detokenizer regressions")
struct StreamingDetokenizerTests {
    /// Minimal copy of MLXLMCommon's upstream detokenizer. We keep it
    /// local to the test so the regression stays pinned even if the
    /// package updates underneath us.
    struct NaiveCharacterDetokenizer {
        let tokenizer: Tokenizer
        var segmentTokens: [Int] = []
        var segment = ""

        mutating func append(token: Int) {
            segmentTokens.append(token)
        }

        mutating func startNewSegment() {
            let lastToken = segmentTokens.last
            segmentTokens.removeAll()
            if let lastToken {
                segmentTokens.append(lastToken)
                segment = tokenizer.decode(tokens: segmentTokens)
            } else {
                segment = ""
            }
        }

        mutating func next() -> String? {
            let newSegment = tokenizer.decode(tokens: segmentTokens)
            let new = newSegment.suffix(newSegment.count - segment.count)
            if new.last == "\u{fffd}" {
                return nil
            }
            if new.hasSuffix("\n") {
                startNewSegment()
            } else {
                segment = newSegment
            }
            return String(new)
        }
    }

    /// Copy of the previous production re-anchor logic. This is the
    /// regression we care about for Pucky itself: after a threshold
    /// reset, it re-decoded the carried token(s) in isolation and
    /// treated those bytes as already emitted.
    struct ThresholdResetByteCountDetokenizer {
        let tokenizer: Tokenizer
        let segmentResetThreshold: Int
        var segmentTokens: [Int] = []
        var segmentBytes: Int = 0

        init(tokenizer: Tokenizer, segmentResetThreshold: Int) {
            self.tokenizer = tokenizer
            self.segmentResetThreshold = segmentResetThreshold
        }

        mutating func append(token: Int) -> String? {
            segmentTokens.append(token)
            let decoded = tokenizer.decode(tokens: segmentTokens)
            if decoded.unicodeScalars.last == "\u{fffd}" {
                return nil
            }

            let utf8Count = decoded.utf8.count
            guard utf8Count > segmentBytes else { return nil }

            let newBytes = Array(decoded.utf8.suffix(utf8Count - segmentBytes))
            let result = String(bytes: newBytes, encoding: .utf8)
            segmentBytes = utf8Count

            if decoded.hasSuffix("\n") || segmentTokens.count >= segmentResetThreshold {
                let lastToken = token
                segmentTokens = [lastToken]
                segmentBytes = tokenizer.decode(tokens: segmentTokens).utf8.count
            }

            return result
        }
    }

    /// Synthetic tokenizer with a grapheme split across tokens. The
    /// one-shot decode is stable and well-formed, so we can compare
    /// streaming output against the final decode exactly.
    struct GraphemeSplitTokenizer: Tokenizer {
        func tokenize(text: String) -> [String] { [] }
        func encode(text: String) -> [Int] { [] }
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }

        func decode(tokens: [Int], skipSpecialTokens: Bool) -> String {
            switch tokens {
            case [0]:
                return "import React from '👩‍"
            case [0, 1]:
                return "import React from '👩‍💻react"
            default:
                Issue.record("unexpected token sequence: \(tokens)")
                return ""
            }
        }

        func convertTokenToId(_ token: String) -> Int? { nil }
        func convertIdToToken(_ id: Int) -> String? { nil }

        var bosToken: String? = nil
        var bosTokenId: Int? = nil
        var eosToken: String? = nil
        var eosTokenId: Int? = nil
        var unknownToken: String? = nil
        var unknownTokenId: Int? = nil

        func applyChatTemplate(messages: [Tokenizers.Message]) throws -> [Int] { [] }

        func applyChatTemplate(messages: [Tokenizers.Message], tools: [Tokenizers.ToolSpec]?) throws
            -> [Int]
        {
            []
        }

        func applyChatTemplate(
            messages: [Tokenizers.Message],
            tools: [Tokenizers.ToolSpec]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            []
        }

        func applyChatTemplate(
            messages: [Tokenizers.Message],
            chatTemplate: Tokenizers.ChatTemplateArgument
        ) throws -> [Int] {
            []
        }

        func applyChatTemplate(messages: [Tokenizers.Message], chatTemplate: String) throws -> [Int] {
            []
        }

        func applyChatTemplate(
            messages: [Tokenizers.Message],
            chatTemplate: Tokenizers.ChatTemplateArgument?,
            addGenerationPrompt: Bool,
            truncation: Bool,
            maxLength: Int?,
            tools: [Tokenizers.ToolSpec]?
        ) throws -> [Int] {
            []
        }

        func applyChatTemplate(
            messages: [Tokenizers.Message],
            chatTemplate: Tokenizers.ChatTemplateArgument?,
            addGenerationPrompt: Bool,
            truncation: Bool,
            maxLength: Int?,
            tools: [Tokenizers.ToolSpec]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            []
        }
    }

    /// Synthetic tokenizer that reproduces the reset-path corruption:
    /// token `1` contributes only a newline in context, but once the
    /// detokenizer re-anchors on `[1]` it decodes to `\n👩‍`. When token
    /// `2` arrives, the upstream character-count diff drops the `💻`
    /// entirely, while the byte-count diff emits `💻react`.
    struct ResetBoundaryMergingTokenizer: Tokenizer {
        func tokenize(text: String) -> [String] { [] }
        func encode(text: String) -> [Int] { [] }
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }

        func decode(tokens: [Int], skipSpecialTokens: Bool) -> String {
            switch tokens {
            case [0]:
                return "import React from '"
            case [0, 1]:
                return "import React from '\n"
            case [1]:
                return "\n👩‍"
            case [1, 2]:
                return "\n👩‍💻react"
            case [0, 1, 2]:
                return "import React from '\n👩‍💻react"
            default:
                Issue.record("unexpected token sequence: \(tokens)")
                return ""
            }
        }

        func convertTokenToId(_ token: String) -> Int? { nil }
        func convertIdToToken(_ id: Int) -> String? { nil }

        var bosToken: String? = nil
        var bosTokenId: Int? = nil
        var eosToken: String? = nil
        var eosTokenId: Int? = nil
        var unknownToken: String? = nil
        var unknownTokenId: Int? = nil

        func applyChatTemplate(messages: [Tokenizers.Message]) throws -> [Int] { [] }

        func applyChatTemplate(messages: [Tokenizers.Message], tools: [Tokenizers.ToolSpec]?) throws
            -> [Int]
        {
            []
        }

        func applyChatTemplate(
            messages: [Tokenizers.Message],
            tools: [Tokenizers.ToolSpec]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            []
        }

        func applyChatTemplate(
            messages: [Tokenizers.Message],
            chatTemplate: Tokenizers.ChatTemplateArgument
        ) throws -> [Int] {
            []
        }

        func applyChatTemplate(messages: [Tokenizers.Message], chatTemplate: String) throws -> [Int] {
            []
        }

        func applyChatTemplate(
            messages: [Tokenizers.Message],
            chatTemplate: Tokenizers.ChatTemplateArgument?,
            addGenerationPrompt: Bool,
            truncation: Bool,
            maxLength: Int?,
            tools: [Tokenizers.ToolSpec]?
        ) throws -> [Int] {
            []
        }

        func applyChatTemplate(
            messages: [Tokenizers.Message],
            chatTemplate: Tokenizers.ChatTemplateArgument?,
            addGenerationPrompt: Bool,
            truncation: Bool,
            maxLength: Int?,
            tools: [Tokenizers.ToolSpec]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            []
        }
    }

    /// Minimal reproduction of the observed `from 'eact'` failure mode:
    /// the carried suffix token decodes to `"'r"` in isolation, but only
    /// to `"'"` in context. Re-anchoring from the isolated decode makes the
    /// next step think the `r` was already emitted.
    struct ReactThresholdResetTokenizer: Tokenizer {
        func tokenize(text: String) -> [String] { [] }
        func encode(text: String) -> [Int] { [] }
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }

        func decode(tokens: [Int], skipSpecialTokens: Bool) -> String {
            switch tokens {
            case [0]:
                return "from "
            case [0, 1]:
                return "from '"
            case [1]:
                return "'r"
            case [1, 2]:
                return "'react"
            case [2]:
                return "react"
            case [2, 3]:
                return "react';"
            case [3]:
                return "';"
            case [1, 2, 3]:
                return "'react';"
            case [0, 1, 2]:
                return "from 'react"
            case [0, 1, 2, 3]:
                return "from 'react';"
            default:
                Issue.record("unexpected token sequence: \(tokens)")
                return ""
            }
        }

        func convertTokenToId(_ token: String) -> Int? { nil }
        func convertIdToToken(_ id: Int) -> String? { nil }

        var bosToken: String? = nil
        var bosTokenId: Int? = nil
        var eosToken: String? = nil
        var eosTokenId: Int? = nil
        var unknownToken: String? = nil
        var unknownTokenId: Int? = nil

        func applyChatTemplate(messages: [Tokenizers.Message]) throws -> [Int] { [] }

        func applyChatTemplate(messages: [Tokenizers.Message], tools: [Tokenizers.ToolSpec]?) throws
            -> [Int]
        {
            []
        }

        func applyChatTemplate(
            messages: [Tokenizers.Message],
            tools: [Tokenizers.ToolSpec]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            []
        }

        func applyChatTemplate(
            messages: [Tokenizers.Message],
            chatTemplate: Tokenizers.ChatTemplateArgument
        ) throws -> [Int] {
            []
        }

        func applyChatTemplate(messages: [Tokenizers.Message], chatTemplate: String) throws -> [Int] {
            []
        }

        func applyChatTemplate(
            messages: [Tokenizers.Message],
            chatTemplate: Tokenizers.ChatTemplateArgument?,
            addGenerationPrompt: Bool,
            truncation: Bool,
            maxLength: Int?,
            tools: [Tokenizers.ToolSpec]?
        ) throws -> [Int] {
            []
        }

        func applyChatTemplate(
            messages: [Tokenizers.Message],
            chatTemplate: Tokenizers.ChatTemplateArgument?,
            addGenerationPrompt: Bool,
            truncation: Bool,
            maxLength: Int?,
            tools: [Tokenizers.ToolSpec]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            []
        }
    }

    private func collectNaiveStream(_ tokens: [Int], tokenizer: Tokenizer) -> String {
        var detokenizer = NaiveCharacterDetokenizer(tokenizer: tokenizer)
        var out = ""
        for token in tokens {
            detokenizer.append(token: token)
            out += detokenizer.next() ?? ""
        }
        return out
    }

    private func collectByteStream(
        _ tokens: [Int],
        tokenizer: Tokenizer,
        segmentResetThreshold: Int = 32,
        carryTokenCount: Int = 4
    ) -> String {
        var detokenizer = BoundedByteDetokenizer(
            tokenizer: tokenizer,
            segmentResetThreshold: segmentResetThreshold,
            carryTokenCount: carryTokenCount
        )
        var out = ""
        for token in tokens {
            out += detokenizer.append(token: token) ?? ""
        }
        return out
    }

    private func collectOldByteCountStream(
        _ tokens: [Int],
        tokenizer: Tokenizer,
        segmentResetThreshold: Int
    ) -> String {
        var detokenizer = ThresholdResetByteCountDetokenizer(
            tokenizer: tokenizer,
            segmentResetThreshold: segmentResetThreshold
        )
        var out = ""
        for token in tokens {
            out += detokenizer.append(token: token) ?? ""
        }
        return out
    }

    @Test func upstreamCharacterDiffDropsBoundarySpanningContentAfterReset() {
        let tokenizer = ResetBoundaryMergingTokenizer()
        let tokens = [0, 1, 2]

        let streamed = collectNaiveStream(tokens, tokenizer: tokenizer)

        #expect(streamed == "import React from '\nreact")
    }

    @Test func boundedByteDetokenizerPreservesBoundarySpanningContentAcrossTokens() {
        let tokenizer = GraphemeSplitTokenizer()
        let tokens = [0, 1]

        let naive = collectNaiveStream(tokens, tokenizer: tokenizer)
        let byteStream = collectByteStream(tokens, tokenizer: tokenizer)

        #expect(naive == "import React from '👩‍react")
        #expect(byteStream == tokenizer.decode(tokens: tokens))
        #expect(byteStream == "import React from '👩‍💻react")
    }

    @Test func boundedByteDetokenizerKeepsResetBoundaryContinuation() {
        let tokenizer = ResetBoundaryMergingTokenizer()
        let tokens = [0, 1, 2]

        let streamed = collectByteStream(tokens, tokenizer: tokenizer)

        #expect(streamed == "import React from '\n👩‍💻react")
    }

    @Test func oldThresholdReanchorDropsLeadingCharacterFromReact() {
        let tokenizer = ReactThresholdResetTokenizer()
        let tokens = [0, 1, 2, 3]

        let streamed = collectOldByteCountStream(
            tokens,
            tokenizer: tokenizer,
            segmentResetThreshold: 2
        )

        #expect(streamed == "from 'eact';")
    }

    @Test func boundedByteDetokenizerPreservesReactAcrossThresholdReset() {
        let tokenizer = ReactThresholdResetTokenizer()
        let tokens = [0, 1, 2, 3]

        let streamed = collectByteStream(
            tokens,
            tokenizer: tokenizer,
            segmentResetThreshold: 2,
            carryTokenCount: 1
        )

        #expect(streamed == "from 'react';")
    }

    /// Opt-in network test. The observed `from 'eact'` output does not
    /// require Gemma to sample the single `react` token; the real Hugging
    /// Face tokenizer also accepts an alternate `r` + `ea` + `ct` path.
    @Test func realGemmaTokenizerSupportsSplitReactPieces() async throws {
        guard ProcessInfo.processInfo.environment["PUCKY_GEMMA_NETWORK_TEST"] == "1" else { return }

        let tokenizer = try await AutoTokenizer.from(pretrained: "mlx-community/gemma-4-e2b-it-4bit")

        #expect(tokenizer.decode(tokens: [5966]) == "react")
        #expect(tokenizer.decode(tokens: [236750, 15919, 539]) == "react")
        #expect(tokenizer.decode(tokens: [699, 756, 236750, 15919, 539, 2134]) == " from 'react';")
    }
}
