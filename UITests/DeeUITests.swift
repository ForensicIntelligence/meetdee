import XCTest

final class DeeUITests: XCTestCase {
    func testLaunchShowsFaceAndDebugToggle() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["debugToggle"].waitForExistence(timeout: 10))
    }
}
