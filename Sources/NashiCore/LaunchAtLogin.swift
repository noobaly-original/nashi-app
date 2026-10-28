import Foundation
import ServiceManagement

/// Represents the current launch-at-login registration state for the application.
public struct LaunchAtLoginStatus: Equatable {
    public let isEnabled: Bool
    public let needsApproval: Bool
    public let isUnavailable: Bool

    /// Creates a new launch-at-login status value.
    public init(isEnabled: Bool, needsApproval: Bool, isUnavailable: Bool) {
        self.isEnabled = isEnabled
        self.needsApproval = needsApproval
        self.isUnavailable = isUnavailable
    }
}

/// Manages launch-at-login registration across `SMAppService` and the user `LaunchAgent` fallback.
public enum LaunchAtLogin {
    public static let minimizedPreferenceKey = "launchMinimized"

    /// Returns whether the given bundle URL and identifier represent a valid `.app` bundle.
    public static func isSupportedAppBundle(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard bundleURL.pathExtension.lowercased() == "app",
              let identifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return false
        }
        return true
    }

    /// Returns the current user's `~/Library/LaunchAgents` directory URL.
    public static func defaultLaunchAgentsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    /// Returns the URL for the Nashi-owned `LaunchAgent` property list file.
    public static func launchAgentURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        directory: URL? = nil
    ) -> URL? {
        guard let identifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return nil
        }
        let base = directory ?? defaultLaunchAgentsDirectory()
        return base.appendingPathComponent("\(identifier).plist", isDirectory: false)
    }

    /// Returns whether the Nashi-owned `LaunchAgent` plist exists and has a matching `Label`.
    public static func hasOwnedLaunchAgent(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        directory: URL? = nil,
        launchAgentsDirectory: URL? = nil
    ) -> Bool {
        let base = directory ?? launchAgentsDirectory
        guard let identifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty,
              let direct = launchAgentURL(bundleIdentifier: identifier, directory: base),
              let data = try? Data(contentsOf: direct),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              (plist["Label"] as? String) == identifier else {
            return false
        }
        return isEnabledLaunchAgentPlist(
            at: direct,
            bundleURL: bundleURL,
            executableURL: executableURL,
            bundleIdentifier: identifier
        )
    }

    /// Returns whether any enabled `LaunchAgent` plist in the target directory launches the main app.
    public static func hasMatchingLaunchAgent(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        directory: URL? = nil
    ) -> Bool {
        !matchingLaunchAgentURLs(
            bundleURL: bundleURL,
            executableURL: executableURL,
            bundleIdentifier: bundleIdentifier,
            directory: directory
        ).isEmpty
    }

    /// Returns all enabled `LaunchAgent` plist URLs in the target directory that launch the main app.
    public static func matchingLaunchAgentURLs(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        directory: URL? = nil
    ) -> [URL] {
        let base = directory ?? defaultLaunchAgentsDirectory()
        var matches: [URL] = []
        if let direct = launchAgentURL(bundleIdentifier: bundleIdentifier, directory: base),
           isEnabledLaunchAgentPlist(at: direct, bundleURL: bundleURL, executableURL: executableURL, bundleIdentifier: bundleIdentifier) {
            matches.append(direct)
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return matches
        }
        for url in entries where url.pathExtension.lowercased() == "plist" && !matches.contains(url) {
            if isEnabledLaunchAgentPlist(at: url, bundleURL: bundleURL, executableURL: executableURL, bundleIdentifier: bundleIdentifier) {
                matches.append(url)
            }
        }
        return matches
    }

    /// Inspects a `LaunchAgent` plist and returns whether it is enabled and targets the main application bundle or executable.
    private static func isEnabledLaunchAgentPlist(
        at url: URL,
        bundleURL: URL,
        executableURL: URL?,
        bundleIdentifier: String? = nil
    ) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return false
        }
        if let disabled = plist["Disabled"] as? Bool, disabled {
            return false
        }
        if let runAtLoad = plist["RunAtLoad"] as? Bool, !runAtLoad {
            return false
        }
        let bundlePath = bundleURL.standardizedFileURL.path
        let execPath = executableURL?.standardizedFileURL.path
        var programs: [String] = []
        if let program = plist["Program"] as? String {
            programs.append(program)
        }
        if let arguments = plist["ProgramArguments"] as? [String] {
            programs.append(contentsOf: arguments)
        }
        return programs.contains { arg in
            let normalized = URL(fileURLWithPath: arg).standardizedFileURL.path
            return normalized == bundlePath || (execPath != nil && normalized == execPath)
        }
    }

    /// Reads the current launch-at-login status.
    /// Note: `SMAppService.mainApp.status == .notFound` is the normal macOS pre-registration
    /// baseline state (and also occurs when a copy is signed without an Apple Team ID or managed
    /// via a LaunchAgent / BlockBlock), so `.notFound` must not mark a valid `.app` bundle unavailable.
    public static func status(
        serviceStatus: SMAppService.Status = SMAppService.mainApp.status,
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        launchAgentsDirectory: URL? = nil
    ) -> LaunchAtLoginStatus {
        let supportedBundle = isSupportedAppBundle(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier)
        let agentEnabled = hasMatchingLaunchAgent(
            bundleURL: bundleURL,
            executableURL: executableURL,
            bundleIdentifier: bundleIdentifier,
            directory: launchAgentsDirectory
        )
        let serviceEnabled = serviceStatus == .enabled || serviceStatus == .requiresApproval
        let isEnabled = serviceEnabled || agentEnabled
        let needsApproval = serviceStatus == .requiresApproval && !agentEnabled
        let isUnavailable = !supportedBundle && !isEnabled
        return LaunchAtLoginStatus(
            isEnabled: isEnabled,
            needsApproval: needsApproval,
            isUnavailable: isUnavailable
        )
    }

    /// Enables or disables launching Nashi at login using `SMAppService` with a user `LaunchAgent` fallback.
    public static func setEnabled(
        _ enabled: Bool,
        launchMinimized: Bool = UserDefaults.standard.bool(forKey: minimizedPreferenceKey),
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        launchAgentsDirectory: URL? = nil,
        serviceStatus: () -> SMAppService.Status = { SMAppService.mainApp.status },
        serviceRegister: () throws -> Void = { try SMAppService.mainApp.register() },
        serviceUnregister: () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) throws {
        if enabled {
            var registerError: Error?
            do {
                try serviceRegister()
            } catch {
                registerError = error
            }
            let currentStatus = serviceStatus()
            if registerError == nil && (currentStatus == .enabled || currentStatus == .requiresApproval) {
                try? removeLaunchAgent(
                    bundleURL: bundleURL,
                    executableURL: executableURL,
                    bundleIdentifier: bundleIdentifier,
                    directory: launchAgentsDirectory
                )
                return
            }
            do {
                try writeLaunchAgent(
                    launchMinimized: launchMinimized,
                    bundleURL: bundleURL,
                    executableURL: executableURL,
                    bundleIdentifier: bundleIdentifier,
                    directory: launchAgentsDirectory
                )
            } catch {
                throw registerError ?? error
            }
        } else {
            var unregisterError: Error?
            let currentStatus = serviceStatus()
            if currentStatus == .enabled || currentStatus == .requiresApproval {
                do {
                    try serviceUnregister()
                } catch {
                    unregisterError = error
                }
            } else {
                try? serviceUnregister()
            }
            let hadOwnedAgent = hasOwnedLaunchAgent(
                bundleURL: bundleURL,
                executableURL: executableURL,
                bundleIdentifier: bundleIdentifier,
                directory: launchAgentsDirectory
            )
            do {
                try removeLaunchAgent(
                    bundleURL: bundleURL,
                    executableURL: executableURL,
                    bundleIdentifier: bundleIdentifier,
                    directory: launchAgentsDirectory
                )
            } catch {
                if unregisterError != nil || hadOwnedAgent {
                    throw unregisterError ?? error
                }
            }
            if let unregisterError {
                throw unregisterError
            }
        }
    }

    /// Updates the Nashi-owned `LaunchAgent` plist when the `launchMinimized` preference changes.
    @discardableResult
    public static func syncLaunchMinimized(
        _ launchMinimized: Bool,
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        launchAgentsDirectory: URL? = nil
    ) -> Error? {
        guard hasOwnedLaunchAgent(
            bundleURL: bundleURL,
            executableURL: executableURL,
            bundleIdentifier: bundleIdentifier,
            directory: launchAgentsDirectory
        ) else {
            return nil
        }
        do {
            try writeLaunchAgent(
                launchMinimized: launchMinimized,
                bundleURL: bundleURL,
                executableURL: executableURL,
                bundleIdentifier: bundleIdentifier,
                directory: launchAgentsDirectory
            )
            return nil
        } catch {
            return error
        }
    }

    /// Writes the Nashi-owned `LaunchAgent` plist to the target `LaunchAgents` directory.
    public static func writeLaunchAgent(
        launchMinimized: Bool,
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        directory: URL? = nil,
        launchAgentsDirectory: URL? = nil
    ) throws {
        let base = directory ?? launchAgentsDirectory
        guard let agentURL = launchAgentURL(bundleIdentifier: bundleIdentifier, directory: base),
              let identifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        if FileManager.default.fileExists(atPath: agentURL.path) {
            guard let data = try? Data(contentsOf: agentURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let label = plist["Label"] as? String,
                  label == identifier else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        let resolvedExecutable = executableURL ?? bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(bundleURL.deletingPathExtension().lastPathComponent, isDirectory: false)
        var arguments = [resolvedExecutable.path]
        if launchMinimized {
            arguments.append("--background")
        }
        let plist: [String: Any] = [
            "Label": identifier,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: agentURL, options: .atomic)
    }

    /// Removes only the Nashi-owned `LaunchAgent` plist (`<bundleIdentifier>.plist` with matching `Label`).
    public static func removeLaunchAgent(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        directory: URL? = nil,
        launchAgentsDirectory: URL? = nil
    ) throws {
        let base = directory ?? launchAgentsDirectory
        guard let identifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty,
              let ownedURL = launchAgentURL(bundleIdentifier: identifier, directory: base),
              FileManager.default.fileExists(atPath: ownedURL.path) else {
            return
        }
        guard let data = try? Data(contentsOf: ownedURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let label = plist["Label"] as? String,
              label == identifier else {
            return
        }
        try FileManager.default.removeItem(at: ownedURL)
    }
}
