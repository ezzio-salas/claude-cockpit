import AppKit
import CockpitCore

/// One usage limit: its name, percentage, a bar, and when it resets.
final class MeterRowView: NSView {
    init(meter: UsageMeter, now: Date, accent: NSColor) {
        super.init(frame: .zero)
        let color = Theme.color(for: meter.severity, accent: accent)

        let name = NSTextField.label(Theme.text(
            meter.label, font: Theme.displayFont(size: 10), color: Theme.primaryText, kern: 1.5
        ))
        let percent = NSTextField.label(Theme.text(
            "\(meter.percentUsed)%", font: .monospacedDigitSystemFont(ofSize: 17, weight: .medium), color: color
        ))
        let reset = NSTextField.label(Theme.text(
            Self.resetText(for: meter.reset, now: now).uppercased(),
            font: .monospacedSystemFont(ofSize: 9.5, weight: .regular), color: Theme.secondaryText, kern: 0.5
        ))

        let column = NSStackView.column(spacing: 6)
        column.addFullWidth(NSStackView.splitRow(leading: name, trailing: percent))
        column.addFullWidth(MeterBarView(fraction: CGFloat(meter.percentUsed) / 100, color: color))
        column.addFullWidth(reset)

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

    private static func resetText(for reset: UsageMeter.Reset, now: Date) -> String {
        switch reset {
        case .at(let date): return ResetCountdown.text(until: date, now: now)
        case .unparsed(let text): return "resets \(text)"
        }
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
