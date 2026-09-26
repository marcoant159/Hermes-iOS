import XCTest

/// Walks the main screens in mock pairing mode and attaches a screenshot of each.
/// Run by `.github/workflows/ios-simulator-screenshots.yml`; the workflow exports the
/// attachments from the .xcresult. Missing elements don't stop the tour — the screenshot
/// of whatever is on screen is the useful output.
final class ScreenshotTourUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testScreenshotTour() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_DEFAULTS_SUITE"] = "uitest.defaults.\(UUID().uuidString)"
        app.launchEnvironment["UITEST_KEYCHAIN_SERVICE"] = "uitest.keychain.\(UUID().uuidString)"
        app.launchEnvironment["UITEST_PAIRING_MODE"] = "mock"

        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for label in ["Allow", "Allow While Using App", "OK", "Permitir", "Permitir Durante o Uso do App"] {
                if alert.buttons[label].exists {
                    alert.buttons[label].tap()
                    return true
                }
            }
            return false
        }

        app.launch()
        sleep(3)
        snap(app, "01-onboarding")

        if tapIfExists(app.buttons["Enter Code Manually"]) {
            let setupCodeField = app.textFields["Setup code"]
            if setupCodeField.waitForExistence(timeout: 5) {
                setupCodeField.tap()
                setupCodeField.typeText("ABCD-EFGH")
            }
            snap(app, "02-pairing-code")
            tapIfExists(app.buttons["Connect Hermes"])

            let continueButton = app.buttons["Continue"]
            if continueButton.waitForExistence(timeout: 5) {
                snap(app, "03-after-pairing")
                continueButton.tap()
            }
        }

        _ = app.buttons["Open settings"].waitForExistence(timeout: 10)
        sleep(2)
        snap(app, "04-chat")

        let composer = [app.textFields["chat.composer"], app.textFields["Reply to Hermes"], app.textViews["Reply to Hermes"]]
            .first { $0.exists }
        if let composer {
            composer.tap()
            composer.typeText("Como estão os reservatórios?")
            snap(app, "05-chat-typing")
            if tapIfExists(app.buttons["Send message"]) {
                sleep(6)
                snap(app, "06-chat-reply")
            }
        }

        if tapIfExists(app.buttons["Open settings"]) {
            sleep(2)
            snap(app, "07-settings")
            app.swipeUp()
            sleep(1)
            snap(app, "08-settings-scrolled")
            app.swipeDown()

            if tapIfExists(app.buttons["settings.hermesHost"]) {
                sleep(2)
                snap(app, "09-host")
            }
        }
    }

    @MainActor
    @discardableResult
    private func tapIfExists(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        guard element.waitForExistence(timeout: timeout), element.isHittable else { return false }
        element.tap()
        return true
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
