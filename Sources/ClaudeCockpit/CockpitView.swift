import AppKit
import CockpitCore

/// What the widget shows at one moment.
struct CockpitSnapshot {
    enum Body {
        case meters([UsageMeter])
        case message(String)
    }

    let body: Body
    /// Short header note such as `SYNC` or `STALE · 2m`; empty when there is nothing to report.
    let status: String
    let isStale: Bool
    /// Shown as two rows under the meters; nil hides them.
    let claudeCost: ClaudeCost?
    /// Shown as its own section below the Claude rows; nil hides the section.
    let cursor: CursorActivity?
}

/// The glass card. Dragging it moves the window; a plain click reports `onClick`.
final class CockpitView: NSView {
    private enum Metrics {
        /// Transparent space around the card where its glow is drawn.
        static let glowMargin: CGFloat = 14
        static let cornerRadius: CGFloat = 16
        static let cardWidth: CGFloat = 260
        static let padding: CGFloat = 16
        static let dragThreshold: CGFloat = 3
    }

    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?

    private let glow = CALayer()
    private let surface = NSView()
    private let titleLabel = NSTextField.label(NSAttributedString())
    private let statusLabel = NSTextField.label(NSAttributedString())
    private let bodyStack = NSStackView.column(spacing: 14)
    private let costStack = NSStackView.column(spacing: 9)
    private let cursorStack = NSStackView.column(spacing: 9)
    private var accent = NSColor(CockpitAppearance.standard.accent)
    private var drag: (mouseStart: NSPoint, windowStart: NSPoint, didMove: Bool)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)

        glow.shadowOpacity = 0.55
        glow.shadowRadius = 9
        glow.shadowOffset = .zero
        layer?.addSublayer(glow)

        let card = makeCard()
        let content = makeContent()
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: Metrics.padding),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Metrics.padding),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Metrics.padding),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Metrics.padding),
        ])
        apply(.standard)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Takes effect on the title, border and glow at once, and on the rest of the card at the next `render`.
    func apply(_ appearance: CockpitAppearance) {
        accent = NSColor(appearance.accent)
        titleLabel.attributedStringValue = sectionTitleText(appearance.title)
        surface.layer?.borderColor = NSColor(appearance.border).withAlphaComponent(0.45).cgColor
        glow.shadowColor = NSColor(appearance.glow).cgColor
    }

    func render(_ snapshot: CockpitSnapshot, now: Date) {
        statusLabel.attributedStringValue = Theme.text(
            snapshot.status,
            font: Theme.displayFont(size: 8),
            color: snapshot.isStale ? Theme.amber : accent.withAlphaComponent(0.6),
            kern: 1.5
        )
        // An empty label still has a default line height, which would nudge the header as the status comes and goes.
        statusLabel.isHidden = snapshot.status.isEmpty

        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch snapshot.body {
        case .meters(let meters):
            meters.forEach { bodyStack.addFullWidth(MeterRowView(meter: $0, now: now, accent: accent)) }
        case .message(let message):
            bodyStack.addFullWidth(NSTextField.label(Theme.text(
                message, font: Theme.displayFont(size: 9), color: Theme.primaryText, kern: 1.5
            )))
        }
        bodyStack.alphaValue = snapshot.isStale ? 0.45 : 1

        costStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        costStack.isHidden = snapshot.claudeCost == nil
        if let cost = snapshot.claudeCost {
            let isPartial = !cost.unpricedModels.isEmpty
            costStack.addFullWidth(Self.statRow("TODAY", value: apiEquivalent(cost.today, isPartial: isPartial)))
            costStack.addFullWidth(
                Self.statRow("7 DAYS", value: apiEquivalent(cost.last7Days, isPartial: isPartial))
            )
        }

        cursorStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cursorStack.isHidden = snapshot.cursor == nil
        if let cursor = snapshot.cursor {
            cursorStack.addFullWidth(NSTextField.label(sectionTitleText("CURSOR")))
            cursorStack.addFullWidth(Self.statRow("TODAY", value: requestCount(cursor.requestsToday)))
            cursorStack.addFullWidth(Self.statRow("7 DAYS", value: requestCount(cursor.requestsLast7Days)))
            if let model = cursor.topModel {
                cursorStack.addFullWidth(Self.statRow("TOP MODEL", value: Self.statValue(model.uppercased())))
            }
        }
    }

    // MARK: - Construction

    /// Blurred backdrop plus a tinted, outlined surface that holds the content.
    private func makeCard() -> NSView {
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = Self.roundedMask(radius: Metrics.cornerRadius)

        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor(srgbRed: 0.02, green: 0.04, blue: 0.07, alpha: 0.55).cgColor
        surface.layer?.cornerRadius = Metrics.cornerRadius
        surface.layer?.borderWidth = 1

        for view in [glass, surface] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.glowMargin),
                view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.glowMargin),
                view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.glowMargin),
                view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.glowMargin),
            ])
        }
        surface.widthAnchor.constraint(equalToConstant: Metrics.cardWidth).isActive = true
        return surface
    }

    private func makeContent() -> NSView {
        let content = NSStackView.column(spacing: 14)
        content.addFullWidth(NSStackView.splitRow(leading: titleLabel, trailing: statusLabel))
        content.addFullWidth(bodyStack)
        content.addFullWidth(costStack)
        content.addFullWidth(cursorStack)
        content.setCustomSpacing(20, after: costStack)
        return content
    }

    private func sectionTitleText(_ name: String) -> NSAttributedString {
        Theme.text(name, font: Theme.displayFont(size: 11, weight: .bold), color: accent, kern: 3)
    }

    private static func statRow(_ name: String, value: NSAttributedString) -> NSView {
        let label = NSTextField.label(Theme.text(
            name, font: Theme.displayFont(size: 10), color: Theme.primaryText, kern: 1.5
        ))
        return NSStackView.splitRow(leading: label, trailing: NSTextField.label(value))
    }

    private static func statValue(_ text: String, color: NSColor = Theme.primaryText) -> NSAttributedString {
        Theme.text(text, font: .monospacedSystemFont(ofSize: 11, weight: .medium), color: color, kern: 0.5)
    }

    /// `30 REQUESTS`, with the number emphasized.
    private func requestCount(_ count: Int) -> NSAttributedString {
        emphasized("\(count)", unit: count == 1 ? "REQUEST" : "REQUESTS")
    }

    /// `~$140 API EQ`: what the usage would cost at API prices, which a subscription does not charge.
    private func apiEquivalent(_ dollars: Double, isPartial: Bool) -> NSAttributedString {
        emphasized(CostText.text(dollars, isPartial: isPartial), unit: "API EQ")
    }

    private func emphasized(_ figure: String, unit: String) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: Self.statValue(figure, color: accent))
        value.append(Theme.text(
            " \(unit)",
            font: .monospacedSystemFont(ofSize: 9.5, weight: .regular), color: Theme.secondaryText, kern: 0.5
        ))
        return value
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Glow

    override func layout() {
        super.layout()
        let cardRect = bounds.insetBy(dx: Metrics.glowMargin, dy: Metrics.glowMargin)
        guard cardRect.width > Metrics.cornerRadius * 2, cardRect.height > Metrics.cornerRadius * 2 else { return }

        let outline = CGPath(
            roundedRect: cardRect,
            cornerWidth: Metrics.cornerRadius,
            cornerHeight: Metrics.cornerRadius,
            transform: nil
        )
        // Keep only the halo outside the card, so the glow never tints the glass.
        let halo = CGMutablePath()
        halo.addRect(bounds)
        halo.addPath(outline)
        let mask = CAShapeLayer()
        mask.path = halo
        mask.fillRule = .evenOdd

        glow.frame = bounds
        glow.shadowPath = outline
        glow.mask = mask
    }

    // MARK: - Mouse

    // Labels and bars never take the mouse; the whole card is one drag and click target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        drag = (NSEvent.mouseLocation, window.frame.origin, false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, var drag else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - drag.mouseStart.x
        let dy = mouse.y - drag.mouseStart.y
        guard drag.didMove || hypot(dx, dy) >= Metrics.dragThreshold else { return }

        drag.didMove = true
        self.drag = drag
        window.setFrameOrigin(NSPoint(x: drag.windowStart.x + dx, y: drag.windowStart.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        if drag.didMove {
            onMoved?()
        } else {
            onClick?()
        }
    }
}
