import AppKit

/// A frameless panel that floats above every window on every Space and never takes focus.
final class CockpitPanel: NSPanel {
    private static let topLeftKey = "panelTopLeft"
    private static let screenMargin: CGFloat = 12

    private let cockpitView = CockpitView()

    init(menu: NSMenu, onClick: @escaping () -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // The card draws its own glow; a system shadow would outline the transparent margin.
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false

        cockpitView.menu = menu
        cockpitView.onClick = onClick
        cockpitView.onMoved = { [weak self] in self?.saveTopLeft() }
        contentView = cockpitView
    }

    /// Shows the snapshot and resizes to fit it, keeping the top-left corner where it is.
    func render(_ snapshot: CockpitSnapshot, now: Date) {
        cockpitView.render(snapshot, now: now)

        let size = cockpitView.fittingSize
        let topLeft = isVisible ? NSPoint(x: frame.minX, y: frame.maxY) : initialTopLeft(for: size)
        setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), display: true)
        if !isVisible {
            orderFrontRegardless()
        }
    }

    private func saveTopLeft() {
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: frame.minX, y: frame.maxY)), forKey: Self.topLeftKey)
    }

    /// The saved position if it is still on a connected screen, otherwise the top-right of the main screen.
    private func initialTopLeft(for size: NSSize) -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: Self.topLeftKey).map(NSPointFromString) {
            let center = NSPoint(x: saved.x + size.width / 2, y: saved.y - size.height / 2)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(center) }) {
                return saved
            }
        }
        let visible = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(x: visible.maxX - size.width - Self.screenMargin, y: visible.maxY - Self.screenMargin)
    }
}
