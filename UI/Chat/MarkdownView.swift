import AppKit
import Markdown
import SwiftUI

/// Markdown rendering.
///
/// Typography follows the design tokens: SF Pro at the transcript size, a flat heading
/// ladder (+3 / +1 / 0 pt over the body) where weight and space carry rank, and 20 pt
/// between paragraphs. The ladder and the line box are pinned by `StyleTests`.
struct MarkdownView: View {
    let text: String
    let fontSize: CGFloat
    var isStreaming: Bool = false
    /// R33: case-insensitive find query tinted on every text run.
    var highlight: String = ""

    @Environment(\.theme) private var theme

    /// Parsed blocks live in state and are rebuilt only when the text changes. Parsing
    /// inside `body` re-ran on every layout pass — including each frame of a window
    /// resize.
    @State private var blocks: [Markup] = []
    @State private var parsedText: String?
    /// Coalesces streaming bursts: at 40–60 chunks per second the parser would run tens
    /// of times a second for no visible benefit.
    @State private var parseTask: Task<Void, Never>?
    @State private var pendingText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.zero) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, child in
                MarkdownBlockView(
                    node: child,
                    fontSize: fontSize,
                    dimmed: false,
                    highlight: highlight
                )
                    .padding(.top, index == 0 ? Spacing.zero : MarkdownBlockView.gap(after: blocks[index - 1], before: child))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: text, initial: true) { _, newValue in
            scheduleParse(newValue)
        }
        // The final text must be parsed at once: the stream stopped, no more chunks are
        // coming to flush the last one.
        .onChange(of: isStreaming) { _, streaming in
            if !streaming { scheduleParse(text) }
        }
        .onAppear { scheduleParse(text) }
        .onDisappear {
            parseTask?.cancel()
            parseTask = nil
        }
    }
}

extension MarkdownView {
    private func scheduleParse(_ value: String) {
        pendingText = value
        guard parsedText != value else { return }
        guard isStreaming, parsedText != nil else {
            parseTask?.cancel()
            parseTask = nil
            parsedText = value
            blocks = Self.parse(value)
            return
        }
        guard parseTask == nil else { return }
        parseTask = Task {
            try? await Task.sleep(for: .seconds(Tuning.markdownParseInterval))
            guard !Task.isCancelled else { return }
            let latest = pendingText
            parsedText = latest
            blocks = Self.parse(latest)
            parseTask = nil
        }
    }

    private static func parse(_ value: String) -> [Markup] {
        Array(
            Document(parsing: value, options: [.parseBlockDirectives, .parseSymbolLinks])
                .children
        )
    }
}

struct MarkdownBlockView: View {
    let node: Markup
    let fontSize: CGFloat
    var dimmed: Bool = false
    var depth: Int = 0
    var highlight: String = ""

    @Environment(\.theme) private var theme

    private var baseColor: Color { dimmed ? theme.labelSecondary : theme.labelPrimary }
    private var ui: Font { AppFont.ui(fontSize) }
    private var lineSpacing: CGFloat { AppFont.lineSpacing(for: fontSize) }

    // MARK: - Vertical rhythm

    /// Margin above a block, in points.
    static func marginTop(_ node: Markup) -> CGFloat {
        if let heading = node as? Heading {
            return [Spacing.offGrid28, Spacing.section, Spacing.offGrid20, Spacing.offGrid20][min(max(heading.level - 1, 0), 3)]
        }
        if node is CodeBlock { return Spacing.medium }
        if node is Markdown.Image { return Spacing.section }
        if node is Markdown.Table || node is BlockQuote { return Spacing.large }
        if node is ThematicBreak { return Spacing.offGrid32 }
        if node is UnorderedList || node is OrderedList { return Spacing.small }
        return Spacing.zero
    }

    /// Margin below a block, in points.
    static func marginBottom(_ node: Markup) -> CGFloat {
        if let heading = node as? Heading {
            return [Spacing.medium, Spacing.offGrid10, Spacing.small, Spacing.small][min(max(heading.level - 1, 0), 3)]
        }
        if node is CodeBlock { return Spacing.section }
        if node is Markdown.Image { return Spacing.section }
        if node is Markdown.Table || node is BlockQuote { return Spacing.large }
        if node is ThematicBreak { return Spacing.offGrid32 }
        if node is UnorderedList || node is OrderedList { return Spacing.medium }
        // A paragraph is followed by a real blank line: with the tightened leading a
        // 12 pt gap merged neighbouring paragraphs into one wall of text.
        return Spacing.offGrid20
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
            CodeBlockView(code: code.code, language: code.language, fontSize: fontSize)
        } else if node is BlockQuote {
            quoteView
        } else if let list = node as? UnorderedList {
            listView(items: listChildren(list), ordered: false, start: 1)
        } else if let list = node as? OrderedList {
            listView(items: listChildren(list), ordered: true, start: Int(list.startIndex))
        } else if node is ThematicBreak {
            // No rule: a break is air, nothing more.
            Color.clear.frame(height: Spacing.zero)
        } else if let table = node as? Markdown.Table {
            tableView(table)
        } else if let image = node as? Markdown.Image {
            imageView(image)
        } else if let html = node as? HTMLBlock {
            Text(html.rawHTML)
                .font(AppFont.mono(fontSize))
                .foregroundStyle(theme.labelTertiary)
                .selectableWhileIdle()
        } else {
            childBlocks
        }
    }

    private var paragraphView: some View {
        Text(inlineText(node, bold: false, scale: 1))
            .font(ui)
            .foregroundStyle(baseColor)
            .lineSpacing(lineSpacing)
            .selectableWhileIdle()
            .fixedSize(horizontal: false, vertical: true)
            // Prose is capped so a line does not run the full 1100 pt container. Code
            // blocks and tables below intentionally skip this and use the full width.
            .frame(maxWidth: Layout.textColumn, alignment: .leading)
    }

    // MARK: - Headings

    /// Size ladder: +3 / +1 / 0 / 0 points over the body. Absolute steps keep the ratio
    /// flat as the user changes the font size. Pinned by `StyleTests`.
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
        .font(AppFont.ui(size, weight: Self.headingWeight(level: level)))
        .foregroundStyle(level >= 4 ? theme.labelSecondary : theme.labelPrimary)
        .lineSpacing(lineSpacing)
        .selectableWhileIdle()
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: Layout.textColumn, alignment: .leading)
    }

    // MARK: - Quote

    private var quoteView: some View {
        VStack(alignment: .leading, spacing: Spacing.zero) {
            let children = Array(node.children)
            ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                MarkdownBlockView(node: child, fontSize: fontSize, dimmed: true, depth: depth, highlight: highlight)
                    .padding(.top, index == 0 ? Spacing.zero : Self.gap(after: children[index - 1], before: child))
            }
        }
        .frame(maxWidth: Layout.textColumn, alignment: .leading)
        .padding(.leading, Spacing.small)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.separator)
                .frame(width: Spacing.hairline)
        }
    }

    // MARK: - Lists

    private func listChildren(_ list: Markup) -> [Markup] {
        Array(list.children).filter { $0 is ListItem }
    }

    private func listView(items: [Markup], ordered: Bool, start: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
                    Text(ordered ? "\(start + index)." : "•")
                        .font(ui)
                        .foregroundStyle(theme.labelSecondary)
                        .frame(minWidth: Spacing.offGrid20, alignment: .trailing)
                    VStack(alignment: .leading, spacing: Spacing.zero) {
                        let children = Array(item.children)
                        ForEach(Array(children.enumerated()), id: \.offset) { childIndex, child in
                            MarkdownBlockView(node: child, fontSize: fontSize, dimmed: dimmed, depth: depth + 1, highlight: highlight)
                                .padding(.top, childIndex == 0 ? Spacing.zero : Self.gap(after: children[childIndex - 1], before: child))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: Layout.textColumn, alignment: .leading)
        // Nested lists get a shallower indent than a top-level list.
        .padding(.leading, depth > 0 ? Spacing.large : Spacing.zero)
    }

    @ViewBuilder
    private var childBlocks: some View {
        if node.childCount > 0 {
            let children = Array(node.children)
            VStack(alignment: .leading, spacing: Spacing.zero) {
                ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                    MarkdownBlockView(node: child, fontSize: fontSize, dimmed: dimmed, depth: depth, highlight: highlight)
                        .padding(.top, index == 0 ? Spacing.zero : Self.gap(after: children[index - 1], before: child))
                }
            }
        }
    }

    // MARK: - Tables

    private func tableView(_ table: Markdown.Table) -> some View {
        let tableFont = max(fontSize - 1, FontSize.minReadable)
        let rows = Array(table.body.rows)

        return VStack(alignment: .leading, spacing: Spacing.zero) {
            HStack(spacing: Spacing.zero) {
                ForEach(Array(table.head.cells.enumerated()), id: \.offset) { _, cell in
                    Text(inlineText(cell, bold: false, scale: tableFont / max(fontSize, 1)))
                        .font(AppFont.ui(tableFont, weight: .medium))
                        .foregroundStyle(theme.labelSecondary)
                        .lineSpacing(AppFont.lineSpacing(for: tableFont))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.medium)
                        .padding(.vertical, Spacing.small)
                }
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Rectangle()
                    .fill(theme.separator)
                    .frame(height: Spacing.hairline)

                HStack(spacing: Spacing.zero) {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        Text(inlineText(cell, bold: false, scale: tableFont / max(fontSize, 1)))
                            .font(AppFont.ui(tableFont))
                            .foregroundStyle(theme.labelPrimary)
                            .lineSpacing(AppFont.lineSpacing(for: tableFont))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Spacing.medium)
                            .padding(.vertical, Spacing.offGrid10)
                    }
                }
            }
        }
        .background(theme.controlBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control)
                .stroke(theme.separator, lineWidth: Spacing.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
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
            } else {
                LocalChatImage(path: source)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
    }

    private func imagePlaceholder(_ image: Markdown.Image) -> some View {
        Text(image.plainText.isEmpty ? "[изображение]" : "[\(image.plainText)]")
            .font(ui)
            .foregroundStyle(theme.labelSecondary)
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
                linked.foregroundColor = theme.accent
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
        // The interface face carries prose; code and identifiers keep the mono face.
        let size = fontSize * style.scale
        var font = style.code
            ? AppFont.mono(size, weight: .medium)
            : AppFont.ui(size, weight: style.bold ? .semibold : .regular)
        if style.italic {
            font = font.italic()
        }
        fragment.font = font

        fragment.foregroundColor = style.dimmed ? theme.labelSecondary : theme.labelPrimary

        // Inline code is tinted with the accent and left on the page background, so
        // paths, flags and hashes stand out without a plate behind them.
        if style.code {
            fragment.foregroundColor = theme.accent
        }

        if style.strikethrough {
            fragment.strikethroughStyle = .single
        }
        if let link {
            fragment.link = link
            fragment.foregroundColor = theme.accent
        }

        // R33: the find bar tints hits after every other attribute is set, so a match
        // stays visible inside code, links and emphasis alike.
        return SearchHighlight.applying(
            fragment,
            source: string,
            query: highlight,
            color: theme.accent.opacity(0.28)
        )
    }
}
