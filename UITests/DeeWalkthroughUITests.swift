import XCTest

/// 0.6.0: walks the whole introduction (persona step included) and the settings'
/// companion switch. Screenshots are attached to the test result; with
/// `DEE_SHOT_DIR` set (`TEST_RUNNER_DEE_SHOT_DIR` for xcodebuild) they are also
/// written there as `wrap-sim-<n>.png`.
final class DeeWalkthroughUITests: XCTestCase {
    private var shot = 0

    override func setUp() {
        continueAfterFailure = false
    }

    private func snap(_ name: String) {
        shot += 1
        let s = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: s)
        a.name = "\(shot)-\(name)"
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["DEE_SHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("wrap-sim-\(name).png")
            try? s.pngRepresentation.write(to: url)
        }
    }

    /// System alerts (camera, mic, speech) that the app may raise once Dee starts.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<4 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 1.5) else { return }
            for label in ["Allow", "OK", "Allow While Using App", "Don’t Allow", "Don't Allow"] {
                let b = alert.buttons[label]
                if b.exists { b.tap(); break }
            }
        }
    }

    func testWalkIntroductionWithPersonaStep() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-DeeResetOnboarding"]
        app.launch()
        let next = app.buttons["onboardingNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Meet Mira"].waitForExistence(timeout: 3), "a fresh install meets Mira")
        snap("01-meet")

        // Intro pages and permission cards: Next until the provider step.
        var guardCount = 0
        while !app.buttons["providerOpenAI"].exists, guardCount < 12 {
            next.tap()
            guardCount += 1
            if app.buttons["providerOpenAI"].waitForExistence(timeout: 1) { break }
            if guardCount == 1 {
                XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Hey Mira'")).count > 0,
                              "a fresh install's wake phrase is Mira's")
            }
            snap(String(format: "%02d-intro", guardCount + 1))
        }
        XCTAssertTrue(app.buttons["providerOpenAI"].exists)
        snap("20-provider-openai")
        app.buttons["providerLan"].tap()
        XCTAssertTrue(app.textFields["serverAddressField"].waitForExistence(timeout: 5))
        snap("21-provider-lan")
        app.buttons["providerOpenAI"].tap()

        // Persona step.
        next.tap()
        XCTAssertTrue(app.staticTexts["Choose your companion"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["persona_mira"].exists)
        snap("30-persona-top")
        for id in ["vera", "rio", "atlas", "nova", "haven"] {
            XCTAssertTrue(app.buttons["persona_\(id)"].exists, "card for \(id)")
        }
        XCTAssertFalse(app.buttons["persona_classic"].exists, "a fresh install is not offered Classic")
        app.swipeUp()
        snap("31-persona-bottom")
        app.buttons["persona_nova"].tap()
        XCTAssertTrue(app.buttons["persona_nova"].isSelected)
        snap("32-persona-nova")

        // Wake phrase follows the persona; the pages say "their".
        next.tap()
        XCTAssertTrue(app.staticTexts["Their wake phrase"].waitForExistence(timeout: 5))
        let field = app.textFields["wakePhraseField"]
        XCTAssertTrue(field.exists)
        XCTAssertEqual(field.value as? String, "Hey Nova")
        snap("40-wake")
        next.tap()
        XCTAssertTrue(app.staticTexts["Their voice"].waitForExistence(timeout: 5))
        snap("41-voice")
        next.tap()
        XCTAssertTrue(app.staticTexts["Speak first?"].waitForExistence(timeout: 5))
        snap("42-speakfirst")
        // Then any permission cards still undecided, then the last page.
        var cards = 0
        repeat {
            next.tap()
            cards += 1
            if app.staticTexts["Almost there"].waitForExistence(timeout: 2) { break }
            snap(String(format: "%02d-late-card", 42 + cards))
        } while cards < 6
        XCTAssertTrue(app.staticTexts["Almost there"].exists)
        XCTAssertFalse(app.buttons["onboardingDone"].isEnabled, "no provider yet")
        snap("49-done")
    }

    func testSettingsCompanionSwitch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-DeeSkipOnboarding"]
        app.launch()
        let gear = app.buttons["settingsButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 15))
        dismissSystemAlerts()
        gear.tap()
        let change = app.buttons["changeCompanion"]
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        snap("50-settings")
        change.tap()
        let rio = app.buttons["persona_rio"]
        if !rio.waitForExistence(timeout: 5) { snap("51x-after-change"); print(app.debugDescription) }
        XCTAssertTrue(rio.exists)
        snap("51-companion-sheet")
        app.buttons["persona_rio"].tap()
        let confirm = app.buttons["Switch to Rio"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        snap("52-switch-confirm")
        confirm.tap()
        XCTAssertTrue(app.buttons["persona_rio"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["persona_rio"].isSelected)
        snap("53-switched")
        app.navigationBars["Choose your companion"].buttons.firstMatch.tap()   // back to the settings
        let rioRow = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Rio'")).firstMatch
        XCTAssertTrue(rioRow.waitForExistence(timeout: 5), "the Companion section shows Rio")
        snap("54-settings-rio")
        // Cancel discards the unsaved switch.
        app.navigationBars.buttons["Cancel"].tap()
    }
}
