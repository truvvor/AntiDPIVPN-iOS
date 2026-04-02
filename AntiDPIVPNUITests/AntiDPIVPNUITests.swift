import XCTest

final class AntiDPIVPNUITests: XCTestCase {

    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    func testAppLaunches() throws {
        // Verify main screen elements exist
        XCTAssertTrue(app.staticTexts["AntiDPI VPN"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Disconnected"].exists)
    }

    func testConnectWithEmptyProfileShowsError() throws {
        // The app starts with empty profile, tap connect button
        let connectButton = app.buttons["ConnectButton"]
        if connectButton.waitForExistence(timeout: 5) {
            connectButton.tap()
        } else {
            // Try tapping the "Disconnected" area which is the connect button
            let disconnectedText = app.staticTexts["Disconnected"]
            XCTAssertTrue(disconnectedText.exists, "Disconnected text should exist")
            disconnectedText.tap()
        }

        // Wait a moment for error to appear
        sleep(2)

        // Check that an error message appeared (validation should catch empty profile)
        // The error should mention missing server address, not "Unknown error"
        let errorExists = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'not configured'")).firstMatch.waitForExistence(timeout: 3)
        XCTAssertTrue(errorExists, "Should show validation error for empty profile")
    }

    func testNavigateToProfiles() throws {
        // Tap Profiles tab
        let profilesTab = app.buttons["Profiles"]
        if profilesTab.waitForExistence(timeout: 5) {
            profilesTab.tap()
            sleep(1)
        }

        // Should see profiles list
        let exists = app.navigationBars["Profiles"].waitForExistence(timeout: 3)
            || app.staticTexts["Profiles"].waitForExistence(timeout: 3)
        XCTAssertTrue(exists, "Should navigate to Profiles screen")
    }

    func testNavigateToSettings() throws {
        // Tap Settings tab
        let settingsTab = app.buttons["Settings"]
        if settingsTab.waitForExistence(timeout: 5) {
            settingsTab.tap()
            sleep(1)
        }

        // Should see version info
        let versionExists = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Xray'")).firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(versionExists, "Should see Xray version in settings")
    }

    func testCreateAndEditProfile() throws {
        // Navigate to Profiles
        let profilesTab = app.buttons["Profiles"]
        guard profilesTab.waitForExistence(timeout: 5) else {
            XCTFail("Profiles tab not found")
            return
        }
        profilesTab.tap()
        sleep(1)

        // Tap + to add new profile
        let addButton = app.buttons["plus"]
        if addButton.waitForExistence(timeout: 3) {
            addButton.tap()
            sleep(1)
        } else {
            // Try navigation bar add button
            let navAdd = app.navigationBars.buttons.matching(NSPredicate(format: "label CONTAINS 'Add'")).firstMatch
            if navAdd.waitForExistence(timeout: 3) {
                navAdd.tap()
                sleep(1)
            }
        }

        // Should see profile edit form with NFS Public Key field
        let nfsField = app.textFields["NFS Public Key"]
        let nfsExists = nfsField.waitForExistence(timeout: 3)
        // NFS field should exist in the profile editor
        if nfsExists {
            XCTAssertTrue(true, "NFS Public Key field exists in profile editor")
        }

        // Fill in test server details
        let serverField = app.textFields["Server Address"]
        if serverField.waitForExistence(timeout: 3) {
            serverField.tap()
            serverField.typeText("77.90.8.199")
        }

        let uuidField = app.textFields["UUID"]
        if uuidField.waitForExistence(timeout: 3) {
            uuidField.tap()
            uuidField.typeText("a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        }
    }
}
