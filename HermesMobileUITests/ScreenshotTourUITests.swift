import CoreGraphics
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
            // Hide the keyboard, which covers "Connect Hermes".
            app.staticTexts["Hermes iOS"].firstMatch.tap()
            let connect = app.buttons["Connect Hermes"]
            for _ in 0..<3 where connect.exists && !connect.isHittable {
                app.swipeUp()
            }
            tapIfExists(connect)

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

                // Return to the chat before the conversation / model / voice stops.
                let back = app.navigationBars.buttons["Back"].exists
                    ? app.navigationBars.buttons["Back"]
                    : app.navigationBars.buttons.firstMatch
                if tapIfExists(back) {
                    sleep(2)
                }
            }
        }

        // Conversation list (toolbar list button on the chat).
        if tapIfExists(app.buttons["Conversations"]) {
            sleep(2)
            snap(app, "10-conversations")
            tapIfExists(app.buttons["Done"])
            sleep(1)
        }

        // New conversation action (compose button on the chat).
        if tapIfExists(app.buttons["New conversation"]) {
            sleep(2)
            snap(app, "11-new-conversation")
        }

        // Model / status chip (top-left) opens the "Model for new messages" picker.
        // The chip has no accessibility label, so match its model-name text.
        let modelChip = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "gpt-5.4-mini"))
            .firstMatch
        if tapIfExists(modelChip) {
            sleep(2)
            snap(app, "12-model-picker")
            // Dismiss the popover without matching one of its model-name buttons.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
            sleep(1)
        }

        // Voice mode overlay (auto-starts a mock session).
        if tapIfExists(app.buttons["Start voice mode"]) {
            sleep(4)
            // Nudge the interruption monitor in case the mic permission alert is up.
            app.tap()
            sleep(2)
            snap(app, "13-voice-mode")
            if !tapIfExists(app.buttons["End voice session"], timeout: 3) {
                tapIfExists(app.buttons["Close"], timeout: 3)
            }
            sleep(1)
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
