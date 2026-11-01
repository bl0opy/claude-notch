import SwiftUI

/// The markdown Claude writes, in blocks small enough to draw in the notch.
/// SwiftUI only does inline markdown by itself: bold, code, links.
enum MarkdownBlock: Equatable {
    case heading(String)
    case paragraph(String)
    case bullet(String, depth: Int)
    case numbered(String, text: String)
    case quote(String)
    case code(String)
    case diff(String)
    case table([[String]])
    case rule

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        var codeIsDiff = false
        var table: [[String]] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.table(table)) }
            table = []
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = code {
                    let text = open.joined(separator: "\n")
                    blocks.append(codeIsDiff ? .diff(text) : .code(text))
                    code = nil
                } else {
                    flushParagraph()
                    flushTable()
                    code = []
                    codeIsDiff = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces) == "diff"
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }
            if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 1 {
                flushParagraph()
                let cells = trimmed.dropFirst().dropLast().components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|---| line only says it's a table.
                if !cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { table.append(cells) }
                continue
            }
            flushTable()
            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(heading))
            } else if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                let indent = line.prefix { $0 == " " }.count
                blocks.append(.bullet(String(trimmed.dropFirst(2)), depth: indent / 2))
            } else if let (marker, text) = numbered(trimmed) {
                flushParagraph()
                blocks.append(.numbered(marker, text: text))
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
            } else {
                paragraph.append(trimmed)
            }
        }
        flushParagraph()
        flushTable()
        // A reply clipped partway through a fence still shows what it has.
        if let open = code {
            let text = open.joined(separator: "\n")
            blocks.append(codeIsDiff ? .diff(text) : .code(text))
        }
        return blocks
    }

    private static func heading(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return String(line.dropFirst(hashes + 1))
    }

    private static func numbered(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        let rest = line.dropFirst(digits.count)
        guard !digits.isEmpty, rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return ("\(digits).", String(rest.dropFirst(2)))
    }
}

/// `**bold**`, `` `code` `` and links in a line, styled for the dark island.
func inlineMarkdown(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    var styled = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    for run in styled.runs {
        if run.inlinePresentationIntent?.contains(.code) == true {
            styled[run.range].font = .system(size: 11, design: .monospaced)
            styled[run.range].foregroundColor = Color(red: 0.98, green: 0.78, blue: 0.55)
        }
        if run.link != nil {
            styled[run.range].foregroundColor = AgentPhase.speaking.tint
        }
    }
    return styled
}

struct MarkdownText: View {
    let blocks: [MarkdownBlock]
    var color = Color(white: 0.78)

    init(_ source: String, color: Color = Color(white: 0.78)) {
        blocks = MarkdownBlock.parse(source)
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(of: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(of block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let text):
            line(text, weight: .semibold, size: 13, color: Color(white: 0.96))
                .padding(.top, 4)
        case .paragraph(let text):
            line(text)
        case .bullet(let text, let depth):
            marked("•", text).padding(.leading, CGFloat(depth) * 12)
        case .numbered(let marker, let text):
            marked(marker, text)
        case .quote(let text):
            line(text, color: Color(white: 0.55))
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color(white: 0.28)).frame(width: 2)
                }
        case .code(let text):
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color(white: 0.82))
                .textSelection(.enabled)
                .padding(.horizontal, 9).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.11)))
        case .diff(let text):
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, row in
                    Text(row.isEmpty ? " " : row)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(diffColor(row))
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.11)))
        case .table(let rows):
            table(rows)
        case .rule:
            Rectangle().fill(Color(white: 0.2)).frame(height: 1)
        }
    }

    private func diffColor(_ row: String) -> Color {
        if row.hasPrefix("+") { return Color(red: 0.45, green: 0.85, blue: 0.55) }
        if row.hasPrefix("-") { return Color(red: 1.0, green: 0.5, blue: 0.48) }
        return Color(white: 0.6)
    }

    private func line(_ text: String, weight: Font.Weight = .regular, size: CGFloat = 12, color: Color? = nil) -> some View {
        Text(inlineMarkdown(text))
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color ?? self.color)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func marked(_ marker: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.45))
            line(text)
        }
    }

    private func table(_ rows: [[String]]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(inlineMarkdown(cell))
                            .font(.system(size: 11, weight: index == 0 ? .semibold : .regular))
                            .foregroundStyle(Color(white: index == 0 ? 0.9 : 0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if index == 0 { Rectangle().fill(Color(white: 0.2)).frame(height: 1) }
            }
        }
        .padding(.vertical, 2)
    }
}
