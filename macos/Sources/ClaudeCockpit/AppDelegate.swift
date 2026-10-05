import AppKit
import CockpitCore
import os

/// Polls Claude for usage and cost and Cursor for usage and activity, and keeps the panel showing the latest
/// good readings.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshInterval: TimeInterval = 60
    /// Countdowns and the stale age move on without a fetch.
    private static let redrawInterval: TimeInterval = 30
    /// Cursor's plan usage moves slowly and costs a start of its CLI to read, so the timer reads it less
    /// often than Claude's. A click reads it at once.
    private static let cursorUsageInterval: TimeInterval = 300

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
    /// `defaults write local.claude-cockpit cursorCommand <name or path>` points the widget at another
    /// Cursor CLI.
    private let cursorUsageFetcher = CursorUsageFetcher(
        command: UserDefaults.standard.string(forKey: "cursorCommand") ?? "cursor-agent"
    )
    private let appearanceStore = AppearanceStore()
    private lazy var customization = CustomizationWindowController(store: appearanceStore) { [weak self] in
        self?.panel.apply($0)
        self?.render()
    }
    private lazy var panel = CockpitPanel(menu: makeMenu(), onClick: { [weak self] in self?.refreshEverything() })

    private var lastReading: (meters: [UsageMeter], takenAt: Date)?
    /// Why the most recent fetch failed; nil after a success.
    private var failure: String?
    /// Nil when there are no Claude Code transcripts on this machine.
    private var claudeCost: ClaudeCost?
    /// Nil when Cursor is not in use on this machine or its database could not be read.
    private var cursorActivity: CursorActivity?
    /// The last good reading of Cursor's plan usage; nil when the Cursor CLI is not installed.
    private var cursorUsage: (usage: CursorUsage, takenAt: Date)?
    /// Whether the most recent read of it failed, which marks the reading stale.
    private var cursorUsageFailed = false
    /// When the timer next reads it.
    private var cursorUsageDue = Date.distantPast
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

    /// A refresh the person asked for, which reads Cursor's plan usage too.
    @objc private func refreshEverything() {
        cursorUsageDue = .distantPast
        refresh()
    }

    @objc private func refresh() {
        guard !isFetching else { return }
        isFetching = true
        render()

        let readsCursorUsage = Date() >= cursorUsageDue
        if readsCursorUsage {
            cursorUsageDue = Date().addingTimeInterval(Self.cursorUsageInterval)
        }

        Task { @MainActor in
            async let usage = fetcher.fetch()
            async let cost = costEstimator.estimate(now: Date())
            async let activity = readCursorActivity()
            async let planUsage = fetchCursorUsage(isDue: readsCursorUsage)
            let result = await usage
            let estimate = await cost
            let unpriced = estimate?.last7Days.unpricedModels ?? []
            if !unpriced.isEmpty, unpriced != claudeCost?.last7Days.unpricedModels {
                log.notice("Cost estimate omits models with no known price: \(unpriced.joined(separator: ", "), privacy: .public)")
            }
            claudeCost = estimate
            cursorActivity = await activity
            record(await planUsage)
            isFetching = false
            record(result)
            render()
        }
    }

    /// The plan usage or why it could not be read; nil when this poll does not read it.
    private func fetchCursorUsage(isDue: Bool) async -> Result<CursorUsage, CursorUsageFetcher.FetchError>? {
        isDue ? await cursorUsageFetcher.fetch() : nil
    }

    private func record(_ result: Result<CursorUsage, CursorUsageFetcher.FetchError>?) {
        switch result {
        case nil:
            break
        case .success(let usage):
            cursorUsage = (usage, Date())
            cursorUsageFailed = false
        case .failure(.cliNotFound):
            // No Cursor CLI is the ordinary case of a machine without Cursor, not a fault.
            cursorUsage = nil
            cursorUsageFailed = false
        case .failure(let error):
            cursorUsageFailed = true
            log.error("Cursor usage fetch failed: \(String(describing: error), privacy: .public)")
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
        let isCursorStale = cursorUsage != nil && cursorUsageFailed
        let cursorNote: String
        if let cursorUsage, isCursorStale {
            cursorNote = "STALE · \(CompactDuration.text(now.timeIntervalSince(cursorUsage.takenAt)))"
        } else {
            cursorNote = cursorUsage?.usage.resets.map { "RESETS \($0.uppercased())" } ?? ""
        }

        panel.render(
            CockpitSnapshot(
                body: body,
                status: status,
                isStale: isStale,
                claudeCost: claudeCost,
                cursorUsage: cursorUsage?.usage,
                cursorNote: cursorNote,
                isCursorStale: isCursorStale,
                cursor: cursorActivity
            ),
            now: now
        )
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(refreshEverything), keyEquivalent: "").target = self
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
