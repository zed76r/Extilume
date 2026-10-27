import AppKit
import Darwin
import ExtilumeCore
import Foundation

enum ApplicationLaunchError: Error, Equatable {
    case invalidArguments
    case anotherApplicationRunning
}

struct ApplicationLaunchOptions: Equatable {
    let stateDirectory: URL
    let verifiesExternalHandoff: Bool
}

@MainActor
func acquireApplicationControlLease(
    directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Extilume-application-owner", isDirectory: true),
    hasOtherApplication: () -> Bool = {
        NSWorkspace.shared.runningApplications.contains {
            $0.processIdentifier != getpid()
                && ["com.extilume.app", "com.extilume.development"].contains($0.bundleIdentifier ?? "")
        }
    }
) throws -> RecoveryStore {
    if mkdir(directory.path, mode_t(0o700)) != 0 && errno != EEXIST { throw RecoveryStoreError.ioFailure }
    let lease = try RecoveryStore(directory: directory)
    try lease.acquireExclusiveOwnership()
    guard !hasOtherApplication() else { throw ApplicationLaunchError.anotherApplicationRunning }
    return lease
}

func applicationLaunchOptions(
    arguments: [String],
    applicationSupportDirectory: () throws -> URL
) throws -> ApplicationLaunchOptions {
    if !arguments.isEmpty {
        if arguments.first == "--verify-external-handoff" {
            guard arguments.count == 4,
                  arguments[1] == "--allow-display-write",
                  arguments[2] == "--state-directory",
                  !arguments[3].isEmpty,
                  !arguments[3].hasPrefix("--") else {
                throw ApplicationLaunchError.invalidArguments
            }
            return ApplicationLaunchOptions(
                stateDirectory: URL(fileURLWithPath: arguments[3], isDirectory: true),
                verifiesExternalHandoff: true
            )
        }
        guard arguments.count == 2,
              arguments[0] == "--state-directory",
              !arguments[1].isEmpty,
              !arguments[1].hasPrefix("--") else {
            throw ApplicationLaunchError.invalidArguments
        }
        return ApplicationLaunchOptions(
            stateDirectory: URL(fileURLWithPath: arguments[1], isDirectory: true),
            verifiesExternalHandoff: false
        )
    }

    let stateDirectory = try applicationSupportDirectory().appendingPathComponent("Extilume", isDirectory: true)
    let result = stateDirectory.path.withCString { mkdir($0, mode_t(0o700)) }
    if result != 0 && errno != EEXIST { throw RecoveryStoreError.ioFailure }
    return ApplicationLaunchOptions(stateDirectory: stateDirectory, verifiesExternalHandoff: false)
}

func applicationPreferenceSuiteName(for directory: URL) -> String {
    let encodedPath = Data(directory.standardizedFileURL.path.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "com.extilume.app.external-handoff.\(encodedPath)"
}

@MainActor
func externalHandoffLaunchPreferences(for directory: URL) throws -> (defaults: UserDefaults, preferences: DisplayModePreferences) {
    guard let defaults = UserDefaults(suiteName: applicationPreferenceSuiteName(for: directory)) else {
        throw RecoveryStoreError.ioFailure
    }
    return (defaults, DisplayModePreferences(defaults: defaults))
}
