import XCTest

final class PuckyUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Skip the on-device MLX model load — it's slow and unreliable
        // on simulator. AppState.initialize() reads this flag via
        // ProcessInfo.processInfo.arguments and jumps straight to the
        // loaded-model path so the chrome shows up immediately.
        app.launchArguments += ["--pucky-ui-test"]
        app.launch()
    }

    /// Pucky uses a paged horizontal `ScrollView` (no tab bar). The
    /// three pages — Code, Chat, Preview — are reached by swiping.
    /// SwiftUI's lazy paging keeps all three pages mounted, so we
    /// check `frame.minX` on a chat-side element to tell which page
    /// is currently visible: minX ≈ 0 means the chat page is the
    /// active one, minX ≪ 0 means it has scrolled off-screen.
    func testSwipeNavigation() throws {
        let chatHero = app.staticTexts["New"].firstMatch
        XCTAssertTrue(chatHero.waitForExistence(timeout: 10))

        let window = app.windows.firstMatch
        let screenWidth = window.frame.width
        XCTAssertTrue(abs(chatHero.frame.midX - screenWidth / 2) < 50,
                      "chat hero should be centred on screen at start")

        // Chat → Code.
        window.swipeRight()
        let codeHeader = app.otherElements["CodeHeader"]
        XCTAssertTrue(codeHeader.waitForExistence(timeout: 5))
        // After swiping right (showing Code on the left), the
        // chat hero's frame should now be off to the right.
        XCTAssertTrue(chatHero.frame.minX > screenWidth / 2,
                      "chat hero should be off-screen to the right")

        // Code → Chat.
        window.swipeLeft()
        XCTAssertTrue(abs(chatHero.frame.midX - screenWidth / 2) < 50,
                      "chat hero should be re-centred")

        // Chat → Preview. The webview content is opaque to XCUI, so
        // verify the chat hero has slid off-screen to the LEFT.
        window.swipeLeft()
        XCTAssertTrue(chatHero.frame.maxX < screenWidth / 2,
                      "chat hero should be off-screen to the left")

        // Preview → Chat.
        window.swipeRight()
        XCTAssertTrue(abs(chatHero.frame.midX - screenWidth / 2) < 50,
                      "chat hero should be re-centred")
    }

    func testChatEmptyState() throws {
        XCTAssertTrue(app.staticTexts["New"].firstMatch.waitForExistence(timeout: 10))
    }

    /// Smoke-test the input field round-trip. We don't rely on the
    /// model actually generating (the UI-test bypass skips the MLX
    /// load), so the assertion stops at "the send button is wired
    /// up and present" — anything past that is real-model territory.
    /// We don't require `isHittable` because the on-screen keyboard
    /// can cover the bottom of the chat layout depending on simulator
    /// keyboard preferences.
    func testSendMessage() throws {
        let input = app.textFields["ChatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Build me a todo app")

        let sendButton = app.buttons["ChatSendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 2))
    }
}
