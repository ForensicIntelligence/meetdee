import XCTest

final class DeeUITests: XCTestCase {
    /// v0.6: onboarding is skipped (a mode-1 config placeholder, DEBUG only).
    func testLaunchShowsFaceAndDebugToggle() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-DeeSkipOnboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["debugToggle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["settingsButton"].exists)
        XCTAssertTrue(app.buttons["wakeState"].exists)
    }

    /// v0.6: first launch shows onboarding; Skip jumps to the provider step; Start
    /// stays disabled until a provider works.
    func testOnboardingSkipsToProviderAndNeedsOne() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-DeeResetOnboarding"]
        app.launch()
        XCTAssertTrue(app.buttons["onboardingNext"].waitForExistence(timeout: 15))
        app.buttons["onboardingSkip"].tap()
        XCTAssertTrue(app.buttons["providerOpenAI"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["apiKeyField"].exists)
        app.buttons["providerLan"].tap()
        XCTAssertTrue(app.textFields["serverAddressField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["testConnection"].exists)
    }
}
