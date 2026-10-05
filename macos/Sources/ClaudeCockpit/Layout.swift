import AppKit

extension NSStackView {
    /// A vertical stack; add views with `addFullWidth(_:)` to have them span it.
    static func column(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// A row with one view pinned to each side, sharing a baseline.
    static func splitRow(leading: NSView, trailing: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .lastBaseline
        stack.addView(leading, in: .leading)
        stack.addView(trailing, in: .trailing)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        return stack
    }

    func addFullWidth(_ view: NSView) {
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}

extension NSTextField {
    static func label(_ text: NSAttributedString) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: text)
        field.maximumNumberOfLines = 1
        return field
    }
}
