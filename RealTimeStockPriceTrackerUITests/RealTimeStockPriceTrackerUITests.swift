import XCTest

@MainActor
final class RealTimeStockPriceTrackerUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["feedToggle"].waitForExistence(timeout: 5))
        return app
    }

    func testSortNavigationAndDetailRemainLive() {
        let app = launch()
        app.buttons["feedToggle"].tap()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 5))
        let picker = app.segmentedControls["sortPicker"]
        picker.buttons["Price Change"].tap()
        XCTAssertTrue(picker.buttons["Price Change"].isSelected)
        picker.buttons["Price"].tap()
        XCTAssertTrue(picker.buttons["Price"].isSelected)
        app.descendants(matching: .any)["stock-AAPL"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["AAPL"].waitForExistence(timeout: 5))
        let price = app.staticTexts["detailPrice"]
        XCTAssertTrue(price.waitForExistence(timeout: 5))
        let first = price.label
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@ AND label != %@", first, "—"), object: price)
        wait(for: [changed], timeout: 5)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["feedToggle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["connectionStatus"].label, "Connected")
    }

    func testStoppedFeedKeepsDetailPriceStable() {
        let app = launch()
        let toggle = app.buttons["feedToggle"]
        toggle.tap()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertEqual(app.staticTexts["connectionStatus"].label, "Disconnected")
        app.descendants(matching: .any)["stock-AAPL"].firstMatch.tap()
        let price = app.staticTexts["detailPrice"]
        XCTAssertTrue(price.waitForExistence(timeout: 5))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", "—"), object: price)], timeout: 5)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", price.label), object: price)
        changed.isInverted = true
        wait(for: [changed], timeout: 0.75)
    }
}
