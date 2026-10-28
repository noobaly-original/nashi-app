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

    /// Verifies that `SMAppService.Status.notFound` does not mark a valid `.app` bundle unavailable.
    func testNotFoundServiceStatusDoesNotMarkAppBundleUnavailable() {
        let status = LaunchAtLogin.status(
            serviceStatus: .notFound,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            launchAgentsDirectory: temporaryDirectory
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
            launchAgentsDirectory: temporaryDirectory,
            serviceStatus: { .notFound },
            serviceRegister: {}
        )

        let status = LaunchAtLogin.status(
            serviceStatus: .notFound,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            launchAgentsDirectory: temporaryDirectory
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
            launchAgentsDirectory: temporaryDirectory
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
            launchAgentsDirectory: temporaryDirectory,
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
            launchAgentsDirectory: temporaryDirectory
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
            launchAgentsDirectory: temporaryDirectory
        )
        XCTAssertTrue(externalStatus.isEnabled, "An external LaunchAgent targeting the main executable is recognized as enabled in read-only status")

        XCTAssertNil(LaunchAtLogin.syncLaunchMinimized(
            true,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            launchAgentsDirectory: temporaryDirectory
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
            launchAgentsDirectory: temporaryDirectory
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalMainPlistURL.path), "removeLaunchAgent must not delete external LaunchAgent plists")
    }
}
