import AppKit
import SwiftUI

/// Text that can compress its lines. SwiftUI clamps `lineSpacing` at zero, so for
/// negative values the text is laid out by TextKit with a `lineHeightMultiple`.
/// Used only when the user picks a negative spacing; zero and positive keep the
/// normal SwiftUI path.
struct SpacedText: NSViewRepresentable {
    let content: AttributedString
    let lineSpacing: CGFloat

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: NSAttributedString())
        field.isSelectable = true
        field.isEditable = false
        field.drawsBackground = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .vertical)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.attributedStringValue = rendered
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let bounds = rendered.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: width, height: ceil(bounds.height) + 1)
    }

    private var rendered: NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(content))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        if lineSpacing < 0 {
            style.lineHeightMultiple = max(0.45, 1 + lineSpacing / 30)
        } else {
            style.lineSpacing = lineSpacing
        }
        mutable.addAttribute(
            .paragraphStyle,
            value: style,
            range: NSRange(location: 0, length: mutable.length)
        )
        return mutable
    }
}
