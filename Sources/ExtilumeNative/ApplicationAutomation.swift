import AppKit
import Darwin
import ExtilumeCore

struct ApplicationAutomationRequest: Codable, Sendable {
    let action: String
    var allowDisplayWrite: Bool = false
    var target: ApplicationAutomationTarget? = nil
}

struct ApplicationAutomationReply: Codable, Sendable {
    let result: String
    let status: String
    let actions: [String]
    var sessionState: PrimarySessionStatus? = nil
    var selectedMode: DisplayApplicationMode? = nil
    var stateMode: DisplayApplicationMode? = nil
    var requiresExplicitActivation: Bool? = nil
}

// Apple Events retain macOS Automation consent; the receiver never launches another controller.
let applicationAutomationEvent: AEEventClass = 0x45584C4D // EXLM
let applicationAutomationCommand: AEEventID = 0x6374726C // ctrl

struct ApplicationAutomationTarget: Codable, Equatable, Sendable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func read(pid: Int32) throws -> Self {
        guard pid > 1 else { throw ApplicationLaunchError.invalidArguments }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_status != 5,
              info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else {
            throw ApplicationLaunchError.anotherApplicationRunning
        }
        return Self(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }

    func validate(processID: Int32, executable: URL, clientExecutable: URL,
                  read: (Int32) throws -> Self = Self.read) throws {
        guard processID == pid, executable.resolvingSymlinksInPath() == clientExecutable.resolvingSymlinksInPath(),
              try read(pid) == self else { throw ApplicationLaunchError.anotherApplicationRunning }
    }
}

extension ApplicationAutomationTarget {
    init(parsing text: String) throws {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let pid = Int32(parts[0]), pid > 1, let seconds = UInt64(parts[1]), seconds > 0,
              let microseconds = UInt64(parts[2]), microseconds < 1_000_000 else {
            throw ApplicationLaunchError.invalidArguments
        }
        self.init(pid: pid, startSeconds: seconds, startMicroseconds: microseconds)
    }
}

struct ApplicationAutomationOptions {
    let bundleID: String
    let request: ApplicationAutomationRequest

    init(arguments: [String]) throws {
        var args = arguments
        guard args.first == "--control", args.count >= 2 else { throw ApplicationLaunchError.invalidArguments }
        args.removeFirst()
        let action = args.removeFirst()
        guard !action.hasPrefix("--"), !action.isEmpty else { throw ApplicationLaunchError.invalidArguments }
        var bundleID = "com.extilume.development"
        var allowWrite = false
        if args.first == "--allow-display-write" { allowWrite = true; args.removeFirst() }
        var target: ApplicationAutomationTarget?
        if args.first == "--target-process", args.count >= 2 {
            target = try ApplicationAutomationTarget(parsing: args[1])
            args.removeFirst(2)
        }
        if args.first == "--bundle-id", args.count == 2 {
            bundleID = args[1]; args.removeAll()
        }
        guard args.isEmpty, !bundleID.isEmpty, !bundleID.hasPrefix("--"), action == "status" || allowWrite else {
            throw ApplicationLaunchError.invalidArguments
        }
        self.bundleID = bundleID
        request = ApplicationAutomationRequest(action: action, allowDisplayWrite: allowWrite, target: target)
    }
}

@MainActor
public func runApplicationAutomationIfRequested() -> Bool {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.first == "--control" else { return false }
    do {
        let options = try ApplicationAutomationOptions(arguments: arguments)
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: options.bundleID)
            .filter { options.request.target == nil || $0.processIdentifier == options.request.target?.pid }
        guard apps.count == 1, let app = apps.first, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw ApplicationLaunchError.anotherApplicationRunning
        }
        if let target = options.request.target {
            guard let executable = app.executableURL, let clientExecutable = Bundle.main.executableURL else {
                throw ApplicationLaunchError.invalidArguments
            }
            try target.validate(processID: app.processIdentifier, executable: executable, clientExecutable: clientExecutable)
        }
        // Address an existing PID so a race with App exit cannot implicitly launch it.
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: applicationAutomationEvent,
            eventID: applicationAutomationCommand,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: app.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let data = try JSONEncoder().encode(options.request)
        event.setParam(NSAppleEventDescriptor(string: String(decoding: data, as: UTF8.self)), forKeyword: keyDirectObject)
        let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 10)
        guard let text = reply.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let bytes = text.data(using: .utf8), bytes.count <= 65536 else { throw ApplicationLaunchError.invalidArguments }
        let result = try JSONDecoder().decode(ApplicationAutomationReply.self, from: bytes)
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
        if !["status", "accepted"].contains(result.result) { exit(EXIT_FAILURE) }
    } catch {
        print("{\"result\":\"transport-or-request-error\",\"hint\":\"Check arguments, running App version and macOS Automation permission. Outcome may be unknown; never retry writes automatically.\"}")
        exit(EXIT_FAILURE)
    }
    return true
}
