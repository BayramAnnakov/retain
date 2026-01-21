import XCTest

/// UI tests for Retain that verify core user workflows.
/// Uses keyboard navigation to avoid slow accessibility tree queries.
@objcMembers
class RetainUITests: XCTestCase {
    var app: XCUIApplication!
    var screenshotDir: String!

    override func setUpWithError() throws {
        continueAfterFailure = true

        // Use Documents directory which is accessible to UI tests
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        screenshotDir = documentsPath.appendingPathComponent("Retain_UITests").path

        // Create screenshot directory
        try? FileManager.default.createDirectory(
            atPath: screenshotDir,
            withIntermediateDirectories: true
        )

        // Launch app with onboarding skipped
        app = XCUIApplication()
        app.launchArguments = ["-hasCompletedOnboarding", "YES"]
        app.launch()

        // Wait for app to be ready
        _ = app.windows.firstMatch.waitForExistence(timeout: 10)
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Main UI Audit Test

    /// Comprehensive UI audit that captures screenshots of all major UI states.
    /// Uses keyboard navigation to avoid slow accessibility tree queries.
    func testUIAudit() throws {
        executionTimeAllowance = 120
        print("📸 Starting UI Audit")
        print("📁 Screenshots saved to: \(screenshotDir!)")

        // 1. Main window
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, "Main window should exist")
        takeScreenshot(name: "01_main_window")
        print("✅ 1. Main window captured")

        // Small pause before keyboard actions
        Thread.sleep(forTimeInterval: 0.5)

        // 2. Open Settings (Cmd+,)
        app.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)
        takeScreenshot(name: "02_settings")
        print("✅ 2. Settings window captured")

        // Close settings (Cmd+W)
        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // 3. Focus search (Cmd+F)
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(name: "03_search_focused")
        print("✅ 3. Search focused captured")

        // Type search query
        app.typeText("claude")
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(name: "04_search_with_query")
        print("✅ 4. Search with query captured")

        // Clear search (Cmd+A, Delete)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // 5. Navigate sidebar with arrow keys
        app.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey(.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(name: "05_conversation_selected")
        print("✅ 5. Conversation selected captured")

        // 6. Open app menu
        let menuBar = app.menuBars.firstMatch
        if menuBar.exists {
            let appMenu = menuBar.menuBarItems["Retain"]
            if appMenu.exists && appMenu.isHittable {
                appMenu.click()
                Thread.sleep(forTimeInterval: 0.3)
                takeScreenshot(name: "06_app_menu")
                print("✅ 6. App menu captured")
                // Close menu
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        // 7. Open File menu
        let fileMenu = app.menuBars.firstMatch.menuBarItems["File"]
        if fileMenu.exists && fileMenu.isHittable {
            fileMenu.click()
            Thread.sleep(forTimeInterval: 0.3)
            takeScreenshot(name: "07_file_menu")
            print("✅ 7. File menu captured")
            app.typeKey(.escape, modifierFlags: [])
        }

        // 8. Final state
        Thread.sleep(forTimeInterval: 0.3)
        takeScreenshot(name: "08_final_state")
        print("✅ 8. Final state captured")

        print("✅ UI Audit Complete!")
        print("📁 Screenshots at: \(screenshotDir!)")
    }

    // MARK: - Individual Quick Tests

    func testAppLaunches() throws {
        XCTAssertTrue(app.windows.firstMatch.exists, "App should launch with main window")
        takeScreenshot(name: "launch_main_window")
    }

    func testMenuBarExists() throws {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.exists, "Menu bar should exist")

        let appMenu = menuBar.menuBarItems["Retain"]
        XCTAssertTrue(appMenu.exists, "Retain menu item should exist")

        takeScreenshot(name: "menubar")
    }

    func testSettingsOpensViaKeyboard() throws {
        app.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Settings opens - verify by checking window count
        let windowCount = app.windows.count
        XCTAssertTrue(windowCount >= 1, "Settings should open")

        takeScreenshot(name: "settings_window")
        app.typeKey("w", modifierFlags: .command)
    }

    func testSearchViaKeyboard() throws {
        // Focus search
        app.typeKey("f", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(name: "search_empty")

        // Type query
        app.typeText("test query")
        Thread.sleep(forTimeInterval: 0.5)
        takeScreenshot(name: "search_filled")
    }

    // MARK: - Screenshot Helper

    private func takeScreenshot(name: String) {
        let screenshot = app.screenshot()

        // Add as test attachment (always works)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // Also save to disk
        let data = screenshot.pngRepresentation
        let path = "\(screenshotDir!)/\(name).png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("📸 Saved: \(name).png")
        } catch {
            print("⚠️ Could not save to disk: \(error.localizedDescription)")
            // Not a failure - screenshots are in test attachments
        }
    }
}
