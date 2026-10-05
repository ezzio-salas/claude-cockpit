import AppKit
import CockpitCore

/// The Personalize window: a title and three colors. Every change is saved and shown on the card at once.
final class CustomizationWindowController: NSWindowController, NSTextFieldDelegate {
    private enum Metrics {
        static let padding: CGFloat = 20
        static let fieldWidth: CGFloat = 200
        static let wellSize = NSSize(width: 44, height: 24)
    }

    private let store: AppearanceStore
    private let onChange: (CockpitAppearance) -> Void

    private let titleField = NSTextField()
    private let accentWell = NSColorWell()
    private let borderWell = NSColorWell()
    private let glowWell = NSColorWell()

    init(store: AppearanceStore, onChange: @escaping (CockpitAppearance) -> Void) {
        self.store = store
        self.onChange = onChange

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Personalize Claude Cockpit"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.contentView = makeContent()
        window.setContentSize(window.contentView?.fittingSize ?? .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window with the saved appearance. The app has no Dock icon, so it activates itself to be seen.
    func present() {
        show(store.appearance)
        if window?.isVisible == false {
            window?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Construction

    private func makeContent() -> NSView {
        let introduction = NSTextField(wrappingLabelWithString: """
        Give the widget its own title and colors, or close this window to keep the defaults. \
        Changes apply as you make them. To come back here, right-click the widget and choose Customize.
        """)
        introduction.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        introduction.textColor = .secondaryLabelColor

        titleField.placeholderString = CockpitAppearance.defaultTitle
        titleField.delegate = self
        titleField.widthAnchor.constraint(equalToConstant: Metrics.fieldWidth).isActive = true

        for well in [accentWell, borderWell, glowWell] {
            well.target = self
            well.action = #selector(colorChanged)
            well.widthAnchor.constraint(equalToConstant: Metrics.wellSize.width).isActive = true
            well.heightAnchor.constraint(equalToConstant: Metrics.wellSize.height).isActive = true
        }

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Title"), titleField],
            [NSTextField(labelWithString: "Text color"), accentWell],
            [NSTextField(labelWithString: "Border color"), borderWell],
            [NSTextField(labelWithString: "Glow color"), glowWell],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        // Color wells have no text baseline to line up with their labels.
        for colorRow in 1..<grid.numberOfRows {
            grid.row(at: colorRow).rowAlignment = .none
            grid.row(at: colorRow).yPlacement = .center
        }
        grid.rowSpacing = 12
        grid.columnSpacing = 10

        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetToDefaults))
        let done = NSButton(title: "Done", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [reset, NSView(), done])
        buttons.orientation = .horizontal

        let column = NSStackView(views: [introduction, grid, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 18
        column.edgeInsets = NSEdgeInsets(
            top: Metrics.padding, left: Metrics.padding, bottom: Metrics.padding, right: Metrics.padding
        )
        let contentWidth = grid.fittingSize.width
        introduction.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        buttons.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return column
    }

    // MARK: - Changes

    private func show(_ appearance: CockpitAppearance) {
        titleField.stringValue = appearance.title
        accentWell.color = NSColor(appearance.accent)
        borderWell.color = NSColor(appearance.border)
        glowWell.color = NSColor(appearance.glow)
    }

    func controlTextDidChange(_ notification: Notification) {
        saveAndApply()
    }

    @objc private func colorChanged() {
        saveAndApply()
    }

    private func saveAndApply() {
        let appearance = CockpitAppearance(
            title: titleField.stringValue,
            accent: accentWell.color.hexColor ?? .cockpitCyan,
            border: borderWell.color.hexColor ?? .cockpitCyan,
            glow: glowWell.color.hexColor ?? .cockpitCyan
        )
        store.appearance = appearance
        onChange(appearance)
    }

    @objc private func resetToDefaults() {
        store.reset()
        show(.standard)
        onChange(.standard)
    }

    @objc private func finish() {
        NSColorPanel.shared.close()
        close()
    }
}
