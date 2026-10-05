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
    private let statusLabel = NSTextField.label(NSAttributedString())
    private let bodyStack = NSStackView.column(spacing: 14)
    private var drag: (mouseStart: NSPoint, windowStart: NSPoint, didMove: Bool)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)

        glow.shadowColor = Theme.cyan.cgColor
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func render(_ snapshot: CockpitSnapshot, now: Date) {
        statusLabel.attributedStringValue = Theme.text(
            snapshot.status,
            font: Theme.displayFont(size: 8),
            color: snapshot.isStale ? Theme.amber : Theme.cyan.withAlphaComponent(0.6),
            kern: 1.5
        )
        // An empty label still has a default line height, which would nudge the header as the status comes and goes.
        statusLabel.isHidden = snapshot.status.isEmpty

        bodyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch snapshot.body {
        case .meters(let meters):
            meters.forEach { bodyStack.addFullWidth(MeterRowView(meter: $0, now: now)) }
        case .message(let message):
            bodyStack.addFullWidth(NSTextField.label(Theme.text(
                message, font: Theme.displayFont(size: 9), color: Theme.primaryText, kern: 1.5
            )))
        }
        bodyStack.alphaValue = snapshot.isStale ? 0.45 : 1
    }

    // MARK: - Construction

    /// Blurred backdrop plus a tinted, outlined surface that holds the content.
    private func makeCard() -> NSView {
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.maskImage = Self.roundedMask(radius: Metrics.cornerRadius)

        let surface = NSView()
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor(srgbRed: 0.02, green: 0.04, blue: 0.07, alpha: 0.55).cgColor
        surface.layer?.cornerRadius = Metrics.cornerRadius
        surface.layer?.borderWidth = 1
        surface.layer?.borderColor = Theme.cyan.withAlphaComponent(0.45).cgColor

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
        let title = NSTextField.label(Theme.text(
            "CLAUDE", font: Theme.displayFont(size: 11, weight: .bold), color: Theme.cyan, kern: 3
        ))
        let content = NSStackView.column(spacing: 14)
        content.addFullWidth(NSStackView.splitRow(leading: title, trailing: statusLabel))
        content.addFullWidth(bodyStack)
        return content
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
