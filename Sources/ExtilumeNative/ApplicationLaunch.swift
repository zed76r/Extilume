import Darwin
import ExtilumeCore
import Foundation

enum ApplicationLaunchError: Error, Equatable {
    case invalidArguments
}

func applicationStateDirectory(
    arguments: [String],
    applicationSupportDirectory: () throws -> URL
) throws -> URL {
    if !arguments.isEmpty {
        guard arguments.count == 2,
              arguments[0] == "--state-directory",
              !arguments[1].isEmpty,
              !arguments[1].hasPrefix("--") else {
            throw ApplicationLaunchError.invalidArguments
        }
        return URL(fileURLWithPath: arguments[1], isDirectory: true)
    }

    let stateDirectory = try applicationSupportDirectory().appendingPathComponent("Extilume", isDirectory: true)
    let result = stateDirectory.path.withCString { mkdir($0, mode_t(0o700)) }
    if result != 0 && errno != EEXIST { throw RecoveryStoreError.ioFailure }
    return stateDirectory
}
