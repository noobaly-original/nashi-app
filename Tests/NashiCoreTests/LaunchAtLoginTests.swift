import XCTest
import ServiceManagement
@testable import NashiCore

/// Tests launch-at-login status evaluation, `LaunchAgent` fallback persistence, and ownership boundaries.
final class LaunchAtLoginTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var appBundleURL: URL!
    private var executableURL: URL!

    /// Sets up an isolated temporary directory and mock `Nashi.app` bundle for each test.
    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Nashi-LaunchAtLoginTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        appBundleURL = temporaryDirectory.appendingPathComponent("Nashi.app", isDirectory: true)
        executableURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Nashi", isDirectory: false)
        try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: executableURL)
    }

    /// Cleans up the temporary test directory after each test.
    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    /// Verifies window visibility decisions across manual launches, login launches, and the `launchMinimized` setting.
    func testWindowOpenDecisionForManualAndLoginLaunches() {
        XCTAssertTrue(LaunchAtLogin.isLaunchMinimizedDefault, "Launch minimized defaults to true so login launches remain in the menu bar as on main")

        let suiteName = "test-launch-minimized-" + UUID().uuidString
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        defer { mockDefaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(LaunchAtLogin.isLaunchMinimized(userDefaults: mockDefaults), "When unset in UserDefaults, isLaunchMinimized defaults to true")

        mockDefaults.set(false, forKey: LaunchAtLogin.minimizedPreferenceKey)
        XCTAssertFalse(LaunchAtLogin.isLaunchMinimized(userDefaults: mockDefaults))

        mockDefaults.set(true, forKey: LaunchAtLogin.minimizedPreferenceKey)
        XCTAssertTrue(LaunchAtLogin.isLaunchMinimized(userDefaults: mockDefaults))

        // Manual launches from Finder or Dock must ALWAYS open the window regardless of launchMinimized.
        XCTAssertTrue(LaunchAtLogin.shouldOpenWindow(isLoginLaunch: false, isBackgroundArgument: false, launchMinimized: true),
                      "Manual launch must open the window even when launchMinimized is true")
        XCTAssertTrue(LaunchAtLogin.shouldOpenWindow(isLoginLaunch: false, isBackgroundArgument: false, launchMinimized: false),
                      "Manual launch must open the window when launchMinimized is false")

        // Login launches (via SMAppService) must stay in the menu bar when launchMinimized is true (default).
        XCTAssertFalse(LaunchAtLogin.shouldOpenWindow(isLoginLaunch: true, isBackgroundArgument: false, launchMinimized: true),
                       "Login launch with launchMinimized=true must remain minimized in the menu bar")
        // Login launches open a window only when launchMinimized is explicitly false.
        XCTAssertTrue(LaunchAtLogin.shouldOpenWindow(isLoginLaunch: true, isBackgroundArgument: false, launchMinimized: false),
                      "Login launch with launchMinimized=false must open the window")

        // Background launches (via LaunchAgent fallback argument) follow the same rule.
        XCTAssertFalse(LaunchAtLogin.shouldOpenWindow(isLoginLaunch: false, isBackgroundArgument: true, launchMinimized: true),
                       "Background launch with launchMinimized=true must remain minimized in the menu bar")
        XCTAssertTrue(LaunchAtLogin.shouldOpenWindow(isLoginLaunch: false, isBackgroundArgument: true, launchMinimized: false),
                      "Background launch with launchMinimized=false must open the window")
    }

    /// Verifies that `SMAppService.Status.notFound` does not mark a valid `.app` bundle unavailable.
    func testNotFoundServiceStatusDoesNotMarkAppBundleUnavailable() {
        let status = LaunchAtLogin.status(
            serviceStatus: .notFound,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            directory: temporaryDirectory
        )
        XCTAssertFalse(status.isUnavailable, "SMAppService .notFound is the normal pre-registration or BlockBlock/LaunchAgent state and must not disable Launch at login for an .app bundle")
        XCTAssertFalse(status.isEnabled)
        XCTAssertFalse(status.needsApproval)
    }

    /// Verifies that `setEnabled` falls back to writing a `LaunchAgent` plist when `SMAppService` remains `.notFound`, and syncs `--background` on `syncLaunchMinimized`.
    func testFallbackLaunchAgentIsWrittenAndRecognizedWhenServiceRemainsNotFound() throws {
        try LaunchAtLogin.setEnabled(
            true,
            launchMinimized: true,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            directory: temporaryDirectory,
            serviceStatus: { .notFound },
            serviceRegister: {}
        )

        let status = LaunchAtLogin.status(
            serviceStatus: .notFound,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            directory: temporaryDirectory
        )
        XCTAssertTrue(status.isEnabled)
        XCTAssertFalse(status.isUnavailable)
        XCTAssertFalse(status.needsApproval)

        let plistURL = try XCTUnwrap(LaunchAtLogin.launchAgentURL(
            bundleIdentifier: "local.tangerine.replica",
            directory: temporaryDirectory
        ))
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [executableURL.path, "--background"])

        let syncError = LaunchAtLogin.syncLaunchMinimized(
            false,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            directory: temporaryDirectory
        )
        XCTAssertNil(syncError)
        let updatedData = try Data(contentsOf: plistURL)
        let updatedPlist = try XCTUnwrap(PropertyListSerialization.propertyList(from: updatedData, options: [], format: nil) as? [String: Any])
        XCTAssertEqual(updatedPlist["ProgramArguments"] as? [String], [executableURL.path])

        try LaunchAtLogin.setEnabled(
            false,
            launchMinimized: false,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            directory: temporaryDirectory,
            serviceStatus: { .notFound },
            serviceUnregister: {}
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))
    }

    /// Verifies that helper binaries inside the app bundle do not falsely match as a main-app `LaunchAgent`, and foreign plists are not deleted by `removeLaunchAgent`.
    func testHelperLaunchAgentIsIgnoredAndForeignPlistIsNotDeleted() throws {
        let helperURL = appBundleURL
            .appendingPathComponent("Contents/Resources/Tools/ffmpeg", isDirectory: false)
        let helperPlistURL = temporaryDirectory.appendingPathComponent("custom.helper.agent.plist")
        let helperPlist: [String: Any] = [
            "Label": "custom.helper.agent",
            "ProgramArguments": [helperURL.path],
            "RunAtLoad": true
        ]
        let helperData = try PropertyListSerialization.data(fromPropertyList: helperPlist, format: .xml, options: 0)
        try helperData.write(to: helperPlistURL)

        let helperStatus = LaunchAtLogin.status(
            serviceStatus: .notFound,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            directory: temporaryDirectory
        )
        XCTAssertFalse(helperStatus.isEnabled, "A LaunchAgent targeting a helper inside the bundle must not mark the main app as enabled")

        let externalMainPlistURL = temporaryDirectory.appendingPathComponent("external.nashi.launcher.plist")
        let externalMainPlist: [String: Any] = [
            "Label": "external.nashi.launcher",
            "ProgramArguments": [executableURL.path],
            "RunAtLoad": true
        ]
        let externalMainData = try PropertyListSerialization.data(fromPropertyList: externalMainPlist, format: .xml, options: 0)
        try externalMainData.write(to: externalMainPlistURL)

        let externalStatus = LaunchAtLogin.status(
            serviceStatus: .notFound,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            directory: temporaryDirectory
        )
        XCTAssertTrue(externalStatus.isEnabled, "An external LaunchAgent targeting the main executable is recognized as enabled in read-only status")
        XCTAssertTrue(externalStatus.isManagedExternally, "An external LaunchAgent with a different label is marked as managed externally")

        // Attempting to disable launch at login when only an external agent exists must throw an unmanaged agent error and preserve the external plist.
        XCTAssertThrowsError(try LaunchAtLogin.setEnabled(
            false,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            directory: temporaryDirectory,
            serviceStatus: { .notFound },
            serviceRegister: {},
            serviceUnregister: {}
        )) { error in
            XCTAssertEqual(error as? LaunchAtLoginError, .unmanagedLaunchAgentActive)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalMainPlistURL.path), "Disabling must not delete external LaunchAgents")

        // Secondary command line argument matches (e.g. ditto or cp taking Nashi.app as an argument) must NOT match as active.
        let dittoPlistURL = temporaryDirectory.appendingPathComponent("backup.ditto.plist")
        let dittoPlist: [String: Any] = [
            "Label": "backup.ditto",
            "ProgramArguments": ["/usr/bin/ditto", appBundleURL.path, "/Volumes/Backup/Nashi.app"],
            "RunAtLoad": true
        ]
        let dittoData = try PropertyListSerialization.data(fromPropertyList: dittoPlist, format: .xml, options: 0)
        try dittoData.write(to: dittoPlistURL)

        // Standard macOS `open` commands targeting the app bundle or bundle identifier MUST be recognized as launch at login.
        let openPlistURL = temporaryDirectory.appendingPathComponent("open.launcher.plist")
        let openPlist: [String: Any] = [
            "Label": "open.launcher",
            "ProgramArguments": ["/usr/bin/open", "-a", appBundleURL.path],
            "RunAtLoad": true
        ]
        let openData = try PropertyListSerialization.data(fromPropertyList: openPlist, format: .xml, options: 0)
        try openData.write(to: openPlistURL)

        let openIdentifierPlistURL = temporaryDirectory.appendingPathComponent("open.id.launcher.plist")
        let openIdPlist: [String: Any] = [
            "Label": "open.id.launcher",
            "ProgramArguments": ["open", "-b", "local.tangerine.replica"],
            "RunAtLoad": true
        ]
        let openIdData = try PropertyListSerialization.data(fromPropertyList: openIdPlist, format: .xml, options: 0)
        try openIdData.write(to: openIdentifierPlistURL)

        let isolatedDir = temporaryDirectory.appendingPathComponent("ditto_only", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedDir, withIntermediateDirectories: true)
        try dittoData.write(to: isolatedDir.appendingPathComponent("backup.ditto.plist"))
        let dittoStatus = LaunchAtLogin.status(
            serviceStatus: .notFound,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            directory: isolatedDir
        )
        XCTAssertFalse(dittoStatus.isEnabled, "A LaunchAgent invoking ditto with the app bundle as an argument must not be recognized as launch at login")

        let openIsolatedDir = temporaryDirectory.appendingPathComponent("open_only", isDirectory: true)
        try FileManager.default.createDirectory(at: openIsolatedDir, withIntermediateDirectories: true)
        try openData.write(to: openIsolatedDir.appendingPathComponent("open.launcher.plist"))
        let openStatus = LaunchAtLogin.status(
            serviceStatus: .notFound,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            directory: openIsolatedDir
        )
        XCTAssertTrue(openStatus.isEnabled, "A LaunchAgent invoking open targeting the app bundle must be recognized as launch at login")

        XCTAssertNil(LaunchAtLogin.syncLaunchMinimized(
            true,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            directory: temporaryDirectory
        ))
        let ownedURL = try XCTUnwrap(LaunchAtLogin.launchAgentURL(
            bundleIdentifier: "local.tangerine.replica",
            directory: temporaryDirectory
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path), "syncLaunchMinimized must not create a duplicate plist when only an external LaunchAgent exists")

        try LaunchAtLogin.removeLaunchAgent(
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            directory: temporaryDirectory
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalMainPlistURL.path), "removeLaunchAgent must not delete external LaunchAgent plists")

        // Unparseable / corrupt files at the owned path must be preserved rather than deleted.
        let corruptOwnedURL = temporaryDirectory.appendingPathComponent("corrupt.app.plist")
        try "not a valid plist content".write(to: corruptOwnedURL, atomically: true, encoding: .utf8)
        try LaunchAtLogin.removeLaunchAgent(
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "corrupt.app",
            directory: temporaryDirectory
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptOwnedURL.path), "removeLaunchAgent must preserve unparseable plists")

        // writeLaunchAgent must not overwrite a foreign plist if one exists at the destination.
        let foreignURL = temporaryDirectory.appendingPathComponent("alien.target.plist")
        let foreignPlist: [String: Any] = [
            "Label": "someone.else.tool",
            "ProgramArguments": ["/bin/echo"]
        ]
        let foreignData = try PropertyListSerialization.data(fromPropertyList: foreignPlist, format: .xml, options: 0)
        try foreignData.write(to: foreignURL)
        XCTAssertThrowsError(try LaunchAtLogin.writeLaunchAgent(
            launchMinimized: false,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "alien.target",
            directory: temporaryDirectory
        ), "writeLaunchAgent must refuse to overwrite an existing plist with non-matching Label")
        XCTAssertEqual(try Data(contentsOf: foreignURL), foreignData, "Existing foreign plist data must remain intact")
    }
}
