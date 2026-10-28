import Foundation
import ServiceManagement

public struct LaunchAtLoginStatus: Equatable {
    public let isEnabled: Bool
    public let needsApproval: Bool
    public let isUnavailable: Bool

    public init(isEnabled: Bool, needsApproval: Bool, isUnavailable: Bool) {
        self.isEnabled = isEnabled
        self.needsApproval = needsApproval
        self.isUnavailable = isUnavailable
    }
}

public enum LaunchAtLogin {
    public static let minimizedPreferenceKey = "launchMinimized"

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

    public static func defaultLaunchAgentsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

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

    private static func isEnabledLaunchAgentPlist(
        at url: URL,
        bundleURL: URL,
        executableURL: URL?,
        bundleIdentifier: String?
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
        if let identifier = bundleIdentifier,
           let label = plist["Label"] as? String,
           label == identifier {
            return true
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
            return normalized == bundlePath || (execPath != nil && normalized == execPath) || normalized.hasPrefix(bundlePath + "/")
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
            let hadAgent = hasMatchingLaunchAgent(
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
                if unregisterError != nil || hadAgent {
                    throw unregisterError ?? error
                }
            }
            if let unregisterError, !hadAgent {
                throw unregisterError
            }
        }
    }

    public static func syncLaunchMinimized(
        _ launchMinimized: Bool,
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        launchAgentsDirectory: URL? = nil
    ) {
        guard hasMatchingLaunchAgent(
            bundleURL: bundleURL,
            executableURL: executableURL,
            bundleIdentifier: bundleIdentifier,
            directory: launchAgentsDirectory
        ) else {
            return
        }
        try? writeLaunchAgent(
            launchMinimized: launchMinimized,
            bundleURL: bundleURL,
            executableURL: executableURL,
            bundleIdentifier: bundleIdentifier,
            directory: launchAgentsDirectory
        )
    }

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

    public static func removeLaunchAgent(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        directory: URL? = nil
    ) throws {
        let urls = matchingLaunchAgentURLs(
            bundleURL: bundleURL,
            executableURL: executableURL,
            bundleIdentifier: bundleIdentifier,
            directory: directory
        )
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
