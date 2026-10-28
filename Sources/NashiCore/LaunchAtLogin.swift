import Foundation
import ServiceManagement

/// Represents the current launch-at-login registration state for the application.
public struct LaunchAtLoginStatus: Equatable {
    public let isEnabled: Bool
    public let needsApproval: Bool
    public let isUnavailable: Bool
    public let isManagedExternally: Bool

    /// Creates a new launch-at-login status value.
    public init(
        isEnabled: Bool,
        needsApproval: Bool,
        isUnavailable: Bool,
        isManagedExternally: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.needsApproval = needsApproval
        self.isUnavailable = isUnavailable
        self.isManagedExternally = isManagedExternally
    }
}

/// Errors encountered during launch-at-login registration or unregistration.
public enum LaunchAtLoginError: LocalizedError, Equatable {
    case unmanagedLaunchAgentActive
    case foreignFileExists

    public var errorDescription: String? {
        switch self {
        case .unmanagedLaunchAgentActive:
            return "Startup is managed externally (e.g. by BlockBlock or a custom LaunchAgent). Please disable it in that tool."
        case .foreignFileExists:
            return "A LaunchAgent plist with this identifier already exists and belongs to another application."
        }
    }
}

/// Manages launch-at-login registration across `SMAppService` and the user `LaunchAgent` fallback.
public enum LaunchAtLogin {
    public static let minimizedPreferenceKey = "launchMinimized"

    /// Returns the default state for the `launchMinimized` preference (`true`).
    public static var isLaunchMinimizedDefault: Bool { true }

    /// Returns whether launching minimized is enabled, defaulting to `true` when unset.
    public static func isLaunchMinimized(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.object(forKey: minimizedPreferenceKey) == nil {
            return isLaunchMinimizedDefault
        }
        return userDefaults.bool(forKey: minimizedPreferenceKey)
    }

    /// Determines whether the main window should open on application launch.
    ///
    /// Manual launches from Finder or Dock always open the window.
    /// Login launches (via `SMAppService` or `--background`) stay in the menu bar
    /// by default when `launchMinimized` is enabled (`true`), opening a window only
    /// when `launchMinimized` is explicitly disabled (`false`).
    public static func shouldOpenWindow(
        isLoginLaunch: Bool,
        isBackgroundArgument: Bool,
        launchMinimized: Bool = isLaunchMinimized()
    ) -> Bool {
        let isLoginOrBackground = isLoginLaunch || isBackgroundArgument
        if !isLoginOrBackground {
            return true
        }
        return !launchMinimized
    }

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
        directory: URL? = nil
    ) -> Bool {
        guard let identifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty,
              let direct = launchAgentURL(bundleIdentifier: identifier, directory: directory),
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

        // Check explicit Program
        if let program = plist["Program"] as? String {
            let normalized = URL(fileURLWithPath: program).standardizedFileURL.path
            if normalized == bundlePath || (execPath != nil && normalized == execPath) {
                return true
            }
        }

        // Check ProgramArguments
        guard let arguments = plist["ProgramArguments"] as? [String], !arguments.isEmpty else {
            return false
        }

        // The first argument is the command or executable being launched.
        let firstArg = arguments[0]
        let firstNormalized = URL(fileURLWithPath: firstArg).standardizedFileURL.path
        if firstNormalized == bundlePath || (execPath != nil && firstNormalized == execPath) {
            return true
        }

        // Support standard macOS `open` launches:
        // open /Applications/Nashi.app
        // open -a /Applications/Nashi.app
        // open -b <bundleIdentifier>
        let commandName = URL(fileURLWithPath: firstArg).lastPathComponent.lowercased()
        if commandName == "open" {
            let subsequent = Array(arguments.dropFirst())
            for (index, arg) in subsequent.enumerated() {
                let normalized = URL(fileURLWithPath: arg).standardizedFileURL.path
                if normalized == bundlePath || (execPath != nil && normalized == execPath) {
                    return true
                }
                if (arg == "-b" || arg == "--bundle-identifier"), index + 1 < subsequent.count {
                    let next = subsequent[index + 1]
                    if let identifier = bundleIdentifier, next == identifier {
                        return true
                    }
                }
            }
        }

        return false
    }

    /// Reads the current launch-at-login status.
    /// Note: Signed release builds manage login items via `SMAppService.mainApp` (status `.enabled`,
    /// `.requiresApproval`, or `.notRegistered`). The user `LaunchAgent` fallback is checked when
    /// `SMAppService` reports `.notFound` (e.g. ad-hoc or development copies, or persistence
    /// managed through BlockBlock), preventing false "unavailable" states.
    public static func status(
        serviceStatus: SMAppService.Status = SMAppService.mainApp.status,
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        directory: URL? = nil
    ) -> LaunchAtLoginStatus {
        let supportedBundle = isSupportedAppBundle(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier)
        let agentEnabled = hasMatchingLaunchAgent(
            bundleURL: bundleURL,
            executableURL: executableURL,
            bundleIdentifier: bundleIdentifier,
            directory: directory
        )
        let ownedAgent = hasOwnedLaunchAgent(
            bundleURL: bundleURL,
            executableURL: executableURL,
            bundleIdentifier: bundleIdentifier,
            directory: directory
        )
        let serviceEnabled = serviceStatus == .enabled || serviceStatus == .requiresApproval
        let isEnabled = serviceEnabled || agentEnabled
        let needsApproval = serviceStatus == .requiresApproval && !agentEnabled
        let isUnavailable = !supportedBundle && !isEnabled
        let isManagedExternally = agentEnabled && !ownedAgent && !serviceEnabled
        return LaunchAtLoginStatus(
            isEnabled: isEnabled,
            needsApproval: needsApproval,
            isUnavailable: isUnavailable,
            isManagedExternally: isManagedExternally
        )
    }

    /// Enables or disables launching Nashi at login using `SMAppService` with a user `LaunchAgent` fallback.
    ///
    /// Signed release builds attempt `SMAppService.mainApp.register()` first; only if `SMAppService`
    /// cannot be registered does the mechanism fall back to a user `LaunchAgent`.
    public static func setEnabled(
        _ enabled: Bool,
        launchMinimized: Bool = isLaunchMinimized(),
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        directory: URL? = nil,
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
                    directory: directory
                )
                return
            }
            do {
                try writeLaunchAgent(
                    launchMinimized: launchMinimized,
                    bundleURL: bundleURL,
                    executableURL: executableURL,
                    bundleIdentifier: bundleIdentifier,
                    directory: directory
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
                directory: directory
            )
            do {
                try removeLaunchAgent(
                    bundleURL: bundleURL,
                    executableURL: executableURL,
                    bundleIdentifier: bundleIdentifier,
                    directory: directory
                )
            } catch {
                if unregisterError != nil || hadOwnedAgent {
                    throw unregisterError ?? error
                }
            }
            if let unregisterError {
                throw unregisterError
            }
            if hasMatchingLaunchAgent(
                bundleURL: bundleURL,
                executableURL: executableURL,
                bundleIdentifier: bundleIdentifier,
                directory: directory
            ) {
                throw LaunchAtLoginError.unmanagedLaunchAgentActive
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
        directory: URL? = nil
    ) -> Error? {
        guard hasOwnedLaunchAgent(
            bundleURL: bundleURL,
            executableURL: executableURL,
            bundleIdentifier: bundleIdentifier,
            directory: directory
        ) else {
            return nil
        }
        do {
            try writeLaunchAgent(
                launchMinimized: launchMinimized,
                bundleURL: bundleURL,
                executableURL: executableURL,
                bundleIdentifier: bundleIdentifier,
                directory: directory
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
        directory: URL? = nil
    ) throws {
        guard let agentURL = launchAgentURL(bundleIdentifier: bundleIdentifier, directory: directory),
              let identifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        if FileManager.default.fileExists(atPath: agentURL.path) {
            guard let data = try? Data(contentsOf: agentURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let label = plist["Label"] as? String,
                  label == identifier else {
                throw LaunchAtLoginError.foreignFileExists
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
        directory: URL? = nil
    ) throws {
        guard let identifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty,
              let ownedURL = launchAgentURL(bundleIdentifier: identifier, directory: directory),
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
