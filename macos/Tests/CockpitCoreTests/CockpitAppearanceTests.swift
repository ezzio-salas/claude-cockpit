import XCTest
@testable import CockpitCore

final class HexColorTests: XCTestCase {
    func testParsesSixDigitHexWithOrWithoutTheHash() {
        let expected = HexColor(red: 1, green: 0.2, blue: 0)

        XCTAssertEqual(HexColor(hex: "#FF3300"), expected)
        XCTAssertEqual(HexColor(hex: "ff3300"), expected)
        XCTAssertEqual(HexColor(hex: "  #Ff3300 "), expected)
    }

    func testRejectsAnythingThatIsNotSixHexDigits() {
        XCTAssertNil(HexColor(hex: ""))
        XCTAssertNil(HexColor(hex: "#FFF"))
        XCTAssertNil(HexColor(hex: "#GG3300"))
        XCTAssertNil(HexColor(hex: "#FF33001"))
        XCTAssertNil(HexColor(hex: "red"))
    }

    func testWritesItselfAsUppercaseHex() {
        XCTAssertEqual(HexColor(red: 1, green: 0.2, blue: 0).hex, "#FF3300")
        XCTAssertEqual(HexColor(red: 0, green: 0, blue: 0).hex, "#000000")
    }

    func testComponentsOutsideTheUnitRangeAreClamped() {
        XCTAssertEqual(HexColor(red: 1.4, green: -0.2, blue: 0.5).hex, "#FF0080")
    }

    func testDefaultAccentSurvivesARoundTripThroughHex() {
        XCTAssertEqual(HexColor(hex: HexColor.cockpitCyan.hex)?.hex, HexColor.cockpitCyan.hex)
    }
}

final class CockpitAppearanceTests: XCTestCase {
    func testTitleIsTrimmedAndUppercased() {
        XCTAssertEqual(CockpitAppearance.normalizedTitle("  work  "), "WORK")
    }

    func testBlankTitleFallsBackToTheDefault() {
        XCTAssertEqual(CockpitAppearance.normalizedTitle(""), "CLAUDE")
        XCTAssertEqual(CockpitAppearance.normalizedTitle("   "), "CLAUDE")
    }

    func testLongTitleIsCutToWhatFitsTheHeader() {
        XCTAssertEqual(CockpitAppearance.normalizedTitle("mission control center"), "MISSION CONTRO")
    }

    func testAppearanceNormalizesItsTitle() {
        let appearance = CockpitAppearance(
            title: " side project ", accent: .cockpitCyan, border: .cockpitCyan, glow: .cockpitCyan
        )

        XCTAssertEqual(appearance.title, "SIDE PROJECT")
    }
}

final class AppearanceStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: AppearanceStore!

    override func setUp() {
        suiteName = "claude-cockpit-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = AppearanceStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testNothingSavedMeansTheDefaultAppearance() {
        XCTAssertEqual(store.appearance, .standard)
        XCTAssertEqual(store.appearance.title, "CLAUDE")
    }

    func testSavedAppearanceIsReadBack() {
        let custom = CockpitAppearance(
            title: "work",
            accent: HexColor(red: 1, green: 1, blue: 0),
            border: HexColor(red: 1, green: 0.2, blue: 0),
            glow: HexColor(red: 0, green: 1, blue: 0)
        )

        store.appearance = custom

        XCTAssertEqual(AppearanceStore(defaults: defaults).appearance, custom)
    }

    func testColorsAreStoredAsHexSoTheyCanBeSetByHand() {
        store.appearance = CockpitAppearance(
            title: "work",
            accent: HexColor(red: 1, green: 1, blue: 0),
            border: HexColor(red: 1, green: 0.2, blue: 0),
            glow: HexColor(red: 0, green: 1, blue: 0)
        )

        XCTAssertEqual(defaults.string(forKey: "title"), "WORK")
        XCTAssertEqual(defaults.string(forKey: "accentColor"), "#FFFF00")
        XCTAssertEqual(defaults.string(forKey: "borderColor"), "#FF3300")
        XCTAssertEqual(defaults.string(forKey: "glowColor"), "#00FF00")
    }

    func testUnreadableStoredColorFallsBackToTheDefaultColor() {
        defaults.set("WORK", forKey: "title")
        defaults.set("not a color", forKey: "glowColor")

        XCTAssertEqual(
            store.appearance,
            CockpitAppearance(title: "WORK", accent: .cockpitCyan, border: .cockpitCyan, glow: .cockpitCyan)
        )
    }

    func testAppearanceSavedBeforeTheAccentExistedKeepsItsColorsAndGetsTheDefaultAccent() {
        defaults.set("WORK", forKey: "title")
        defaults.set("#FF3300", forKey: "borderColor")
        defaults.set("#00FF00", forKey: "glowColor")

        XCTAssertEqual(store.appearance, CockpitAppearance(
            title: "WORK",
            accent: .cockpitCyan,
            border: HexColor(red: 1, green: 0.2, blue: 0),
            glow: HexColor(red: 0, green: 1, blue: 0)
        ))
    }

    func testResetReturnsToTheDefaultAppearance() {
        let red = HexColor(red: 1, green: 0, blue: 0)
        store.appearance = CockpitAppearance(title: "work", accent: red, border: red, glow: red)

        store.reset()

        XCTAssertEqual(store.appearance, .standard)
    }

    func testCustomizationHasNotBeenOfferedUntilRecorded() {
        XCTAssertFalse(store.hasOfferedCustomization)

        store.hasOfferedCustomization = true

        XCTAssertTrue(AppearanceStore(defaults: defaults).hasOfferedCustomization)
    }

    func testResetDoesNotOfferCustomizationAgain() {
        store.hasOfferedCustomization = true

        store.reset()

        XCTAssertTrue(store.hasOfferedCustomization)
    }
}
