import XCTest
import ServiceManagement
@testable import NashiCore

final class LaunchAtLoginTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var appBundleURL: URL!
    private var executableURL: URL!

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

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

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

        LaunchAtLogin.syncLaunchMinimized(
            false,
            bundleURL: appBundleURL,
            executableURL: executableURL,
            bundleIdentifier: "local.tangerine.replica",
            launchAgentsDirectory: temporaryDirectory
        )
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
}
