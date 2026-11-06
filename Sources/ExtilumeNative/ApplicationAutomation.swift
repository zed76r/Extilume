import AppKit

struct ApplicationAutomationRequest: Codable, Sendable {
    let action: String
    var allowDisplayWrite: Bool = false
}

struct ApplicationAutomationReply: Codable, Sendable {
    let result: String
    let status: String
    let actions: [String]
}

// Apple Events retain macOS Automation consent; the receiver never launches another controller.
let applicationAutomationEvent: AEEventClass = 0x45584C4D // EXLM
let applicationAutomationCommand: AEEventID = 0x6374726C // ctrl

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
        if args.first == "--bundle-id", args.count == 2 {
            bundleID = args[1]; args.removeAll()
        }
        guard args.isEmpty, !bundleID.isEmpty, !bundleID.hasPrefix("--"), action == "status" || allowWrite else {
            throw ApplicationLaunchError.invalidArguments
        }
        self.bundleID = bundleID
        request = ApplicationAutomationRequest(action: action, allowDisplayWrite: allowWrite)
    }
}

@MainActor
public func runApplicationAutomationIfRequested() -> Bool {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.first == "--control" else { return false }
    do {
        let options = try ApplicationAutomationOptions(arguments: arguments)
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: options.bundleID)
        guard apps.count == 1, let app = apps.first, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw ApplicationLaunchError.anotherApplicationRunning
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
