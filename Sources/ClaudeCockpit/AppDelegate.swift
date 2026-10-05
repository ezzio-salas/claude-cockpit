import AppKit
import CockpitCore
import os

/// Polls Claude for usage and cost and Cursor for activity, and keeps the panel showing the latest good readings.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshInterval: TimeInterval = 60
    /// Countdowns and the stale age move on without a fetch.
    private static let redrawInterval: TimeInterval = 30

    private let log = Logger(subsystem: "local.claude-cockpit", category: "usage")
    /// `defaults write local.claude-cockpit cliCommand <name or path>` points the widget at another CLI.
    private let fetcher = UsageFetcher(command: UserDefaults.standard.string(forKey: "cliCommand") ?? "claude")
    /// `defaults write local.claude-cockpit transcriptsDirectory <path>` points the cost estimate at the
    /// transcripts of a Claude profile that keeps its own config directory.
    private let costEstimator = ClaudeCostEstimator(
        transcripts: UserDefaults.standard.string(forKey: "transcriptsDirectory")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? ClaudeCostEstimator.defaultTranscripts
    )
    private let cursorReader = CursorActivityReader()
    private let appearanceStore = AppearanceStore()
    private lazy var customization = CustomizationWindowController(store: appearanceStore) { [weak self] in
        self?.panel.apply($0)
        self?.render()
    }
    private lazy var panel = CockpitPanel(menu: makeMenu(), onClick: { [weak self] in self?.refresh() })

    private var lastReading: (meters: [UsageMeter], takenAt: Date)?
    /// Why the most recent fetch failed; nil after a success.
    private var failure: String?
    /// Nil when there are no Claude Code transcripts on this machine.
    private var claudeCost: ClaudeCost?
    /// Nil when Cursor is not in use on this machine or its database could not be read.
    private var cursorActivity: CursorActivity?
    private var isFetching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        panel.apply(appearanceStore.appearance)
        refresh()
        Timer.scheduledTimer(
            timeInterval: Self.refreshInterval, target: self, selector: #selector(refresh), userInfo: nil, repeats: true
        )
        Timer.scheduledTimer(
            timeInterval: Self.redrawInterval, target: self, selector: #selector(render), userInfo: nil, repeats: true
        )
        offerCustomizationOnFirstLaunch()
    }

    /// The first launch offers personalization once; afterwards it is reached from the card's menu.
    private func offerCustomizationOnFirstLaunch() {
        guard !appearanceStore.hasOfferedCustomization else { return }
        appearanceStore.hasOfferedCustomization = true
        customization.present()
    }

    @objc private func showCustomization() {
        customization.present()
    }

    @objc private func refresh() {
        guard !isFetching else { return }
        isFetching = true
        render()

        Task { @MainActor in
            async let usage = fetcher.fetch()
            async let cost = costEstimator.estimate(now: Date())
            async let activity = readCursorActivity()
            let result = await usage
            let estimate = await cost
            if let unpriced = estimate?.unpricedModels, !unpriced.isEmpty, unpriced != claudeCost?.unpricedModels {
                log.notice("Cost estimate omits models with no known price: \(unpriced.joined(separator: ", "), privacy: .public)")
            }
            claudeCost = estimate
            cursorActivity = await activity
            isFetching = false
            record(result)
            render()
        }
    }

    private func readCursorActivity() async -> CursorActivity? {
        let reader = cursorReader
        do {
            return try await Task.detached(priority: .utility) { try reader.read(now: Date()) }.value
        } catch {
            log.error("Cursor activity read failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func record(_ result: Result<String, UsageFetcher.FetchError>) {
        switch result {
        case .success(let report):
            let meters = UsageParser.parse(report, now: Date())
            if meters.isEmpty {
                failure = "UNRECOGNIZED OUTPUT"
                log.error("No usage lines in CLI output: \(report, privacy: .public)")
            } else {
                lastReading = (meters, Date())
                failure = nil
            }
        case .failure(let error):
            failure = Self.message(for: error)
            log.error("Usage fetch failed: \(String(describing: error), privacy: .public)")
        }
    }

    @objc private func render() {
        let now = Date()
        let isStale = lastReading != nil && failure != nil
        let status: String
        if isFetching {
            status = "SYNC"
        } else if isStale, let lastReading {
            status = "STALE · \(CompactDuration.text(now.timeIntervalSince(lastReading.takenAt)))"
        } else {
            status = ""
        }

        let body: CockpitSnapshot.Body
        if let lastReading {
            body = .meters(lastReading.meters)
        } else {
            body = .message(failure ?? "READING USAGE")
        }
        panel.render(
            CockpitSnapshot(
                body: body, status: status, isStale: isStale, claudeCost: claudeCost, cursor: cursorActivity
            ),
            now: now
        )
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Customize…", action: #selector(showCustomization), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Cockpit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    /// The app shows no menu bar, but text fields rely on these items for their keyboard shortcuts.
    private static func makeMainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit
        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        return mainMenu
    }

    private static func message(for error: UsageFetcher.FetchError) -> String {
        switch error {
        case .cliNotFound: return "CLAUDE CLI NOT FOUND"
        case .timedOut: return "TIMED OUT"
        case .launchFailed, .failed: return "COULD NOT READ USAGE"
        }
    }
}
