import Foundation
import Testing
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
