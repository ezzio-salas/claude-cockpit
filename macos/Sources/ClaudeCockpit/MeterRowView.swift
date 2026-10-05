import AppKit
import CockpitCore

/// One usage limit: its name, percentage and a bar, with a caption -- when it resets -- underneath.
final class MeterRowView: NSView {
    init(label: String, percentUsed: Int, caption: String?, accent: NSColor) {
        super.init(frame: .zero)
        let color = Theme.color(for: UsageMeter.Severity(percentUsed: percentUsed), accent: accent)

        let name = NSTextField.label(Theme.text(
            label, font: Theme.displayFont(size: 10), color: Theme.primaryText, kern: 1.5
        ))
        let percent = NSTextField.label(Theme.text(
            "\(percentUsed)%", font: .monospacedDigitSystemFont(ofSize: 17, weight: .medium), color: color
        ))

        let column = NSStackView.column(spacing: 6)
        column.addFullWidth(NSStackView.splitRow(leading: name, trailing: percent))
        column.addFullWidth(MeterBarView(fraction: CGFloat(percentUsed) / 100, color: color))
        if let caption {
            column.addFullWidth(NSTextField.label(Theme.text(
                caption.uppercased(),
                font: .monospacedSystemFont(ofSize: 9.5, weight: .regular), color: Theme.secondaryText, kern: 0.5
            )))
        }

        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// A thin glowing progress bar.
final class MeterBarView: NSView {
    private static let thickness: CGFloat = 4

    private let fill = CALayer()
    private let fraction: CGFloat

    init(fraction: CGFloat, color: NSColor) {
        self.fraction = fraction
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        layer?.cornerRadius = Self.thickness / 2

        fill.backgroundColor = color.cgColor
        fill.cornerRadius = Self.thickness / 2
        fill.shadowColor = color.cgColor
        fill.shadowOpacity = 0.9
        fill.shadowRadius = 4
        fill.shadowOffset = .zero
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.thickness)
    }

    override func layout() {
        super.layout()
        // Any non-zero usage stays visible as at least a dot.
        let width = fraction > 0 ? max(bounds.width * fraction, bounds.height) : 0
        fill.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
    }
}
