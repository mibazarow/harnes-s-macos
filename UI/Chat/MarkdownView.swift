import AppKit
import Markdown
import SwiftUI

/// Markdown rendering. Metrics mirror the reference UI's stylesheet: a 160% line box,
/// 12 pt between paragraphs, 24 pt around code, 16 pt around tables and quotes, and a
/// flat heading ladder where size barely moves and weight, color and space carry rank.
struct MarkdownView: View {
    let text: String
    let palette: Palette
    let fontSize: CGFloat
    var isStreaming: Bool = false

    /// Parsed blocks live in state and are rebuilt only when the text changes. Parsing
    /// inside `body` re-ran on every layout pass — including each frame of a window
    /// resize — which is a large part of why dragging an edge felt like 15 fps.
    @State private var blocks: [Markup] = []
    @State private var parsedText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, child in
                MarkdownBlockView(node: child, palette: palette, fontSize: fontSize, dimmed: false)
                    .padding(.top, index == 0 ? 0 : MarkdownBlockView.gap(after: blocks[index - 1], before: child))
            }
            if isStreaming {
                Text("▍")
                    .font(AppFont.mono(fontSize))
                    .foregroundStyle(palette.accent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: text, initial: true) { _, newValue in
            guard parsedText != newValue else { return }
            parsedText = newValue
            blocks = Array(
                Document(parsing: newValue, options: [.parseBlockDirectives, .parseSymbolLinks])
                    .children
            )
        }
    }
}

struct MarkdownBlockView: View {
    let node: Markup
    let palette: Palette
    let fontSize: CGFloat
    var dimmed: Bool = false
    var depth: Int = 0

    private var baseColor: Color { dimmed ? palette.dim : palette.assistantText }
    private var mono: Font { AppFont.mono(fontSize) }
    private var lineSpacing: CGFloat { AppFont.lineSpacing(for: fontSize) }

    // MARK: - Vertical rhythm

    /// CSS margin-top of a block, in points.
    static func marginTop(_ node: Markup) -> CGFloat {
        if let heading = node as? Heading {
            return [28, 24, 20, 20][min(max(heading.level - 1, 0), 3)]
        }
        if node is CodeBlock { return 12 }
        if node is Markdown.Image { return 24 }
        if node is Markdown.Table || node is BlockQuote { return 16 }
        if node is ThematicBreak { return 32 }
        if node is UnorderedList || node is OrderedList { return 8 }
        return 0
    }

    /// CSS margin-bottom of a block, in points.
    static func marginBottom(_ node: Markup) -> CGFloat {
        if let heading = node as? Heading {
            return [12, 10, 8, 8][min(max(heading.level - 1, 0), 3)]
        }
        if node is CodeBlock { return 24 }
        if node is Markdown.Image { return 24 }
        if node is Markdown.Table || node is BlockQuote { return 16 }
        if node is ThematicBreak { return 32 }
        if node is UnorderedList || node is OrderedList { return 12 }
        // A paragraph is followed by a real blank line: with the tightened leading the
        // old 12 pt merged neighbouring paragraphs into one block of text.
        return 20
    }

    /// Adjacent vertical margins collapse: the larger one wins.
    static func gap(after previous: Markup, before current: Markup) -> CGFloat {
        max(marginBottom(previous), marginTop(current))
    }

    // MARK: - Body

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
            // The reference draws no rule: a break is 32 pt of air, nothing more.
            Color.clear.frame(height: 0)
        } else if let table = node as? Markdown.Table {
            tableView(table)
        } else if let image = node as? Markdown.Image {
            imageView(image)
        } else if let html = node as? HTMLBlock {
            Text(html.rawHTML)
                .font(mono)
                .foregroundStyle(palette.comment)
                .selectableWhileIdle()
        } else {
            childBlocks
        }
    }

    private var resolvedBase: Color { baseColor }

    private var paragraphView: some View {
        Text(inlineText(node, bold: false, scale: 1))
            .font(mono)
            .foregroundStyle(resolvedBase)
            .lineSpacing(lineSpacing)
            .selectableWhileIdle()
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Headings

    /// Size ladder: +3 / +1 / 0 / 0 points over the body. Absolute steps keep the ratio
    /// flat as the user changes the font size; a multiplier would inflate the gap too.
    static func headingSize(level: Int, fontSize: CGFloat) -> CGFloat {
        switch level {
        case 1: fontSize + 3
        case 2: fontSize + 1
        default: fontSize
        }
    }

    static func headingWeight(level: Int) -> Font.Weight {
        level <= 3 ? .semibold : .regular
    }

    private func headingView(_ heading: Heading) -> some View {
        let level = heading.level
        let size = Self.headingSize(level: level, fontSize: fontSize)

        return Text(inlineText(
            heading,
            bold: Self.headingWeight(level: level) != .regular,
            scale: size / max(fontSize, 1)
        ))
        .font(mono)
        .foregroundStyle(level >= 4 ? palette.dim : resolvedBase)
        .lineSpacing(lineSpacing)
        .selectableWhileIdle()
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Quote

    private var quoteView: some View {
        VStack(alignment: .leading, spacing: 0) {
            let children = Array(node.children)
            ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                MarkdownBlockView(
                    node: child,
                    palette: palette,
                    fontSize: fontSize,
                    dimmed: true,
                    depth: depth
                )
                .padding(.top, index == 0 ? 0 : Self.gap(after: children[index - 1], before: child))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(palette.border)
                .frame(width: 1)
        }
    }

    // MARK: - Lists

    private func listChildren(_ list: Markup) -> [Markup] {
        Array(list.children).filter { $0 is ListItem }
    }

    private func listView(items: [Markup], ordered: Bool, start: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(ordered ? "\(start + index)." : "•")
                        .font(mono)
                        .foregroundStyle(palette.dim)
                        .frame(minWidth: 20, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 0) {
                        let children = Array(item.children)
                        ForEach(Array(children.enumerated()), id: \.offset) { childIndex, child in
                            MarkdownBlockView(
                                node: child,
                                palette: palette,
                                fontSize: fontSize,
                                dimmed: dimmed,
                                depth: depth + 1
                            )
                            .padding(.top, childIndex == 0 ? 0 : Self.gap(after: children[childIndex - 1], before: child))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // Nested lists get a shallower indent than a top-level list.
        .padding(.leading, depth > 0 ? 16 : 0)
    }

    @ViewBuilder
    private var childBlocks: some View {
        if node.childCount > 0 {
            let children = Array(node.children)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                    MarkdownBlockView(
                        node: child,
                        palette: palette,
                        fontSize: fontSize,
                        dimmed: dimmed,
                        depth: depth
                    )
                    .padding(.top, index == 0 ? 0 : Self.gap(after: children[index - 1], before: child))
                }
            }
        }
    }

    // MARK: - Tables

    private func tableView(_ table: Markdown.Table) -> some View {
        let tableFont = max(fontSize - 1, 10)
        let rows = Array(table.body.rows)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(table.head.cells.enumerated()), id: \.offset) { _, cell in
                    Text(inlineText(cell, bold: false, scale: tableFont / max(fontSize, 1)))
                        .font(AppFont.mono(tableFont, weight: .medium))
                        .foregroundStyle(palette.dim)
                        .lineSpacing(AppFont.lineSpacing(for: tableFont))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                Rectangle()
                    .fill(palette.border.opacity(0.7))
                    .frame(height: 1)

                HStack(spacing: 0) {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        Text(inlineText(cell, bold: false, scale: tableFont / max(fontSize, 1)))
                            .font(AppFont.mono(tableFont))
                            .foregroundStyle(palette.assistantText)
                            .lineSpacing(AppFont.lineSpacing(for: tableFont))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                .background(rowIndex.isMultiple(of: 2) ? Color.clear : palette.codeBackground.opacity(0.45))
            }
        }
        .background(palette.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    // MARK: - Images

    @ViewBuilder
    private func imageView(_ image: Markdown.Image) -> some View {
        let source = image.source ?? ""
        let remote = URL(string: source).flatMap { url in
            ["http", "https"].contains(url.scheme ?? "") ? url : nil
        }

        Group {
            if let remote {
                AsyncImage(url: remote) { phase in
                    if let loaded = phase.image {
                        loaded.resizable().scaledToFit()
                    } else {
                        imagePlaceholder(image)
                    }
                }
            } else if let local = NSImage(contentsOfFile: source) {
                Image(nsImage: local)
                    .resizable()
                    .scaledToFit()
            } else {
                imagePlaceholder(image)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func imagePlaceholder(_ image: Markdown.Image) -> some View {
        Text(image.plainText.isEmpty ? "[изображение]" : "[\(image.plainText)]")
            .font(mono)
            .foregroundStyle(palette.dim)
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
        if style.code {
            font = AppFont.mono(fontSize * style.scale, weight: .medium)
        }
        if style.italic {
            font = font.italic()
        }
        fragment.font = font

        if style.dimmed {
            fragment.foregroundColor = palette.dim
        } else {
            fragment.foregroundColor = palette.assistantText
        }

        // Inline code is tinted with the accent and left on the page background, so
        // commit hashes, paths and flags stand out without a plate behind them.
        if style.code {
            fragment.foregroundColor = palette.accent
        }

        if style.strikethrough {
            fragment.strikethroughStyle = .single
        }
        if let link {
            fragment.link = link
            fragment.foregroundColor = palette.accent
        }

        return fragment
    }
}
