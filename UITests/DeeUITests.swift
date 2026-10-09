import XCTest

final class DeeUITests: XCTestCase {
    func testLaunchShowsInput() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.textFields["messageField"].waitForExistence(timeout: 10) || app.textViews["messageField"].waitForExistence(timeout: 1))
    }
}
