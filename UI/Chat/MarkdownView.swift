import Markdown
import SwiftUI

struct MarkdownView: View {
    let text: String
    let palette: Palette
    let fontSize: CGFloat
    var isStreaming: Bool = false

    var body: some View {
        let document = Document(parsing: text, options: [.parseBlockDirectives, .parseSymbolLinks])
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(document.children.enumerated()), id: \.offset) { _, child in
                MarkdownBlockView(node: child, palette: palette, fontSize: fontSize, dimmed: false)
            }
            if isStreaming {
                Text("▍")
                    .font(AppFont.mono(fontSize))
                    .foregroundStyle(palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlockView: View {
    let node: Markup
    let palette: Palette
    let fontSize: CGFloat
    var dimmed: Bool

    private var baseColor: Color { dimmed ? palette.dim : palette.assistantText }
    private var mono: Font { AppFont.mono(fontSize) }

    @ViewBuilder
    var body: some View {
        if let heading = node as? Heading {
            headingView(heading)
        } else if node is Paragraph {
            paragraphView
        } else if let code = node as? CodeBlock {
            CodeBlockView(
                code: code.code,
                language: code.language,
                palette: palette,
                fontSize: fontSize
            )
        } else if node is BlockQuote {
            quoteView
        } else if let list = node as? UnorderedList {
            listView(items: listChildren(list), ordered: false, start: 1)
        } else if let list = node as? OrderedList {
            listView(items: listChildren(list), ordered: true, start: Int(list.startIndex))
        } else if node is ThematicBreak {
            Rectangle()
                .fill(palette.border)
                .frame(height: 1)
                .padding(.vertical, 4)
        } else if let table = node as? Markdown.Table {
            tableView(table)
        } else if let html = node as? HTMLBlock {
            Text(html.rawHTML)
                .font(mono)
                .foregroundStyle(palette.comment)
                .textSelection(.enabled)
        } else {
            childBlocks
        }
    }

    private var resolvedBase: Color { baseColor }

    private var paragraphView: some View {
        Text(inlineText(node, bold: false, scale: 1))
            .font(mono)
            .foregroundStyle(resolvedBase)
            .lineSpacing(AppFont.lineSpacing)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Headings grow by a fixed number of points, not by a multiplier. On a 14 pt body
    /// that is 17/15/14/14 — the ladder OpenCode uses. A multiplier compounds with the
    /// user's font size, and on a monospaced face semibold already reads heavier, so
    /// 1.25x looked like a different document.
    /// Size ladder for a heading. Absolute increments keep the ratio flat as the user
    /// changes the font size; a multiplier would scale the gap too.
    static func headingSize(level: Int, fontSize: CGFloat) -> CGFloat {
        switch level {
        case 1: fontSize + 3
        case 2: fontSize + 1
        default: fontSize
        }
    }

    static func headingPadding(level: Int) -> CGFloat {
        switch level {
        case 1: 14
        case 2: 10
        case 3: 8
        default: 6
        }
    }

    private func headingView(_ heading: Heading) -> some View {
        let level = heading.level
        let size = Self.headingSize(level: level, fontSize: fontSize)

        return Text(inlineText(heading, bold: level <= 3, scale: size / max(fontSize, 1)))
            .font(mono)
            .foregroundStyle(level >= 4 ? palette.dim : resolvedBase)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Self.headingPadding(level: level))
    }

    private var quoteView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                MarkdownBlockView(
                    node: child,
                    palette: palette,
                    fontSize: fontSize,
                    dimmed: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(palette.faint)
                .frame(width: 2)
        }
        .padding(.vertical, 2)
    }

    private func listChildren(_ list: Markup) -> [Markup] {
        Array(list.children).filter { $0 is ListItem }
    }

    private func listView(items: [Markup], ordered: Bool, start: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(start + index)." : "•")
                        .font(mono)
                        .foregroundStyle(palette.dim)
                        .frame(minWidth: ordered ? 20 : 8, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                            MarkdownBlockView(
                                node: child,
                                palette: palette,
                                fontSize: fontSize,
                                dimmed: dimmed
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var childBlocks: some View {
        if node.childCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                    MarkdownBlockView(
                        node: child,
                        palette: palette,
                        fontSize: fontSize,
                        dimmed: dimmed
                    )
                }
            }
        }
    }

    private func tableView(_ table: Markdown.Table) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(table.head.cells.enumerated()), id: \.offset) { _, cell in
                    Text(inlineText(cell, bold: true, scale: 1))
                        .font(mono)
                        .foregroundStyle(palette.assistantText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(Array(table.body.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        Text(inlineText(cell, bold: false, scale: 1))
                            .font(mono)
                            .foregroundStyle(palette.assistantText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(10)
        .background(palette.codeBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }
}

private struct InlineStyle {
    var bold = false
    var italic = false
    var strikethrough = false
    var code = false
    var dimmed = false
    var scale: CGFloat = 1
}

extension MarkdownBlockView {
    func inlineText(_ markup: Markup, bold: Bool, scale: CGFloat) -> AttributedString {
        renderInline(markup, style: InlineStyle(bold: bold, dimmed: dimmed, scale: scale))
    }

    private func renderInline(_ markup: Markup, style: InlineStyle) -> AttributedString {
        var result = AttributedString()

        for child in markup.children {
            if let text = child as? Markdown.Text {
                result.append(fragment(text.string, style: style, link: nil))
            } else if let code = child as? InlineCode {
                var codeStyle = style
                codeStyle.code = true
                result.append(fragment(code.code, style: codeStyle, link: nil))
            } else if let emphasis = child as? Emphasis {
                var next = style
                next.italic = true
                result.append(renderInline(emphasis, style: next))
            } else if let strong = child as? Strong {
                var next = style
                next.bold = true
                result.append(renderInline(strong, style: next))
            } else if let strike = child as? Strikethrough {
                var next = style
                next.strikethrough = true
                result.append(renderInline(strike, style: next))
            } else if let link = child as? Markdown.Link {
                let inner = renderInline(link, style: style)
                var linked = inner
                linked.link = link.destination.flatMap(URL.init(string:))
                linked.foregroundColor = palette.accent
                linked.underlineStyle = .single
                result.append(linked)
            } else if let image = child as? Markdown.Image {
                var next = style
                next.dimmed = true
                result.append(renderInline(image, style: next))
            } else if child is SoftBreak {
                result.append(fragment(" ", style: style, link: nil))
            } else if child is LineBreak {
                result.append(fragment("\n", style: style, link: nil))
            } else if let html = child as? InlineHTML {
                var next = style
                next.dimmed = true
                result.append(fragment(html.rawHTML, style: next, link: nil))
            } else if child.childCount > 0 {
                result.append(renderInline(child, style: style))
            }
        }

        return result
    }

    private func fragment(_ string: String, style: InlineStyle, link: URL?) -> AttributedString {
        var fragment = AttributedString(string)
        var font = AppFont.mono(fontSize * style.scale, weight: style.bold ? .semibold : .regular)
        if style.italic {
            font = font.italic()
        }
        fragment.font = font

        if style.code {
            fragment.foregroundColor = palette.type
            fragment.backgroundColor = palette.codeBackground
        } else if style.dimmed {
            fragment.foregroundColor = palette.dim
        } else {
            fragment.foregroundColor = palette.assistantText
        }

        if style.strikethrough {
            fragment.strikethroughStyle = .single
        }
        if let link {
            fragment.link = link
            fragment.foregroundColor = palette.accent
            fragment.underlineStyle = .single
        } else if style.code {
            fragment.backgroundColor = palette.codeBackground
        }

        return fragment
    }
}