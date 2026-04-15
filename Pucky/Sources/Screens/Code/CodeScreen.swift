import SwiftUI

struct CodeScreen: View {
    @Environment(AppState.self) private var appState

    /// The app is constrained to a single editable file per
    /// template. The code screen just reads it directly from the
    /// project service; there is nothing to select between.
    private var editableFile: ProjectFile? {
        let path = appState.projectService.editablePath
        return appState.projectFiles.first(where: { $0.path == path })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            content
        }
        .background(PK.bg.ignoresSafeArea())
        .accessibilityIdentifier("CodeScreen")
    }

    // MARK: — Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(editableFile?.name ?? appState.projectService.template.editableFileName)
                .font(PK.serif(26, weight: .light))
                .foregroundStyle(PK.text)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(PK.accent.opacity(0.55))
                        .frame(height: 1)
                        .offset(y: 4)
                }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PK.md)
        .padding(.top, PK.headerTop - 8)
        .padding(.bottom, PK.sm)
        .accessibilityIdentifier("CodeHeader")
    }

    // MARK: — Code content

    @ViewBuilder
    private var content: some View {
        if let file = editableFile {
            sourceContent(for: file)
        } else {
            emptySourceView
        }
    }

    private func sourceContent(for file: ProjectFile) -> some View {
        let lines = file.content.components(separatedBy: "\n")
        // The inner horizontal ScrollView is wrapped in horizontal padding
        // so its frame (and therefore its hit target) doesn't reach the
        // screen edges. The paged outer ScrollView in `MainNavigationView`
        // owns edge-swipes and gets them cleanly instead of losing them
        // to the inner horizontal pan.
        return ScrollView(.vertical, showsIndicators: false) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        // Line numbers gutter
                        VStack(alignment: .trailing, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, _ in
                                Text("\(index + 1)")
                                    .font(PK.mono(11))
                                    .foregroundStyle(PK.textFaint)
                                    .frame(height: 18)
                                    .padding(.trailing, 10)
                            }
                        }

                        // Code
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(SyntaxHighlighter.highlight(line.isEmpty ? " " : line))
                                    .font(PK.mono(12))
                                    .frame(height: 18, alignment: .leading)
                            }
                        }
                        .padding(.trailing, PK.md)
                        .textSelection(.enabled)
                    }
                    .padding(.vertical, PK.md)
                }
            }
            .padding(.horizontal, PK.md)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("SourceContent")
    }

    private var emptySourceView: some View {
        VStack(alignment: .center, spacing: 8) {
            Spacer().frame(height: 120)
            Text("No source yet")
                .font(PK.serif(26, weight: .light))
                .foregroundStyle(PK.text)
            Text("Your generated files will appear here")
                .font(PK.sans(13))
                .foregroundStyle(PK.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
