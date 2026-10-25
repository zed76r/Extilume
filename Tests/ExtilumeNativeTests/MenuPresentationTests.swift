import AppKit
import XCTest
import ExtilumeCore
@testable import ExtilumeNative

@MainActor
final class MenuPresentationTests: XCTestCase {
    func testInteractivePresentation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard ["pilot", "matrix"].contains(environment["EXTILUME_MENU_PRESENTATION"] ?? ""),
              let path = environment["EXTILUME_MENU_PRESENTATION_DIRECTORY"], path.hasPrefix("/") else {
            throw XCTSkip("Interactive menu presentation requires the explicit isolated runner")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw PresentationError.invalidDirectory
        }
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: directory.appendingPathComponent("plan.json")))
        guard !plan.scenarios.isEmpty, plan.scenarios.count <= 50 else { throw PresentationError.invalidPlan }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 420, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Extilume TEST — isolated menu presentation"
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Extilume TEST"
        statusItem.button?.setAccessibilityLabel("Extilume TEST menu host")
        let observer = PresentationMenuObserver()
        var fixture: PresentationFixture?
        var completed: [String] = []
        var lastLedgerCheck = ""
        defer {
            fixture?.delegate.menu.cancelTracking()
            NSStatusBar.system.removeStatusItem(statusItem)
            window.close()
        }
        for scenario in plan.scenarios {
            if !scenario.reuse {
                fixture = PresentationFixture(directory: directory)
                fixture?.session.selectedMode = scenario.mode.flatMap(DisplayApplicationMode.init(rawValue:))
                fixture?.session.requiresExplicitActivation = scenario.explicitActivation
                fixture?.delegate.startSession()
            }
            let current = try XCTUnwrap(fixture)
            current.scenario = scenario.name
            try current.persist()
            if let state = scenario.state { current.session.emit(try status(state)) }
            await drainMainQueue()
            if let mismatchedMode = scenario.mismatchedMode {
                current.session.selectedMode = DisplayApplicationMode(rawValue: mismatchedMode)
                current.session.modeDidChange?()
            }
            observer.closed = false
            current.menuEvents = []
            observer.onEvent = { [weak current] in current?.recordMenuEvent($0) }
            current.delegate.menu.delegate = observer
            statusItem.menu = current.delegate.menu
            try write(directory, "ready.json", [
                "pid": ProcessInfo.processInfo.processIdentifier, "scenario": scenario.name,
                "host": "Release XCTest isolated test status menu", "productStatusButtonPresent": false,
                "items": current.delegate.menu.items.filter { !$0.isSeparatorItem }.map {
                    ["title": $0.title, "hidden": $0.isHidden, "enabled": $0.isEnabled,
                     "mark": $0.state.rawValue, "toolTip": $0.toolTip ?? ""] as [String: Any]
                }
            ])
            let deadline = Date(timeIntervalSinceNow: 20)
            while !observer.closed || !FileManager.default.fileExists(atPath: directory.appendingPathComponent(scenario.name + "-continue").path) {
                if Date() >= deadline || FileManager.default.fileExists(atPath: directory.appendingPathComponent("abort.json").path) {
                    current.delegate.menu.cancelTracking()
                    throw PresentationError.cancelled(scenario.name)
                }
                try await Task.sleep(for: .milliseconds(50))
                if let data = try? Data(contentsOf: directory.appendingPathComponent("ledger-check-request.json")),
                   let check = try? JSONDecoder().decode(LedgerCheck.self, from: data),
                   check.scenario == scenario.name, check.id != lastLedgerCheck {
                    await drainMainQueue()
                    try current.persist()
                    try write(directory, "ledger-check-result.json", ["id": check.id, "scenario": scenario.name,
                                                                       "calls": current.calls])
                    lastLedgerCheck = check.id
                }
            }
            await drainMainQueue()
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(scenario.name + "-continue").path),
                  current.calls == scenario.expectedCalls, current.writeError == nil,
                  current.starts == ["registerEvents:true,recoveryOnly:false"] else {
                throw PresentationError.calls(scenario.name, current.calls)
            }
            if let completion = scenario.completeQuit {
                try current.session.completeQuit(completion)
                let completionDeadline = Date(timeIntervalSinceNow: 2)
                while current.calls != scenario.expectedAfterCompletion && Date() < completionDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard current.calls == scenario.expectedAfterCompletion else {
                    throw PresentationError.calls(scenario.name, current.calls)
                }
            }
            try write(directory, scenario.name + "-host-result.json", [
                "pid": ProcessInfo.processInfo.processIdentifier, "scenario": scenario.name,
                "calls": current.calls, "starts": current.starts,
                "terminationDecisions": current.terminationDecisions,
                "controlledQuitCompletions": current.session.completedQuits,
                "productStatusButtonPresent": false
            ])
            completed.append(scenario.name)
        }
        try write(directory, "result.json", ["pid": ProcessInfo.processInfo.processIdentifier,
                                             "completed": completed, "productStatusButtonPresent": false])
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func status(_ name: String) throws -> PrimarySessionStatus {
        switch name {
        case "waiting": .waiting
        case "unsupported": .unsupported("测试受控条件不符：外接显示器身份尚未确认，模式不会应用")
        case "applying": .applying
        case "applied": .applied
        case "manualConfiguration": .manualConfiguration
        case "manualConfigurationForQuit": .manualConfigurationForQuit
        case "applicationFailedRestored": .applicationFailedRestored
        case "recoveryIncomplete": .recoveryIncomplete
        case "unconfirmed": .unconfirmed
        case "confirmationFailed": .confirmationFailed
        case "restoringAndQuitting": .restoringAndQuitting
        case "quitFailed": .quitFailed
        case "quitWaitingForDisplays": .quitWaitingForDisplays
        default: throw PresentationError.invalidPlan
        }
    }

    private func write(_ directory: URL, _ name: String, _ value: [String: Any]) throws {
        let url = directory.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private struct Plan: Decodable { let scenarios: [Scenario] }
    private struct LedgerCheck: Decodable { let id: String; let scenario: String }
    private struct Scenario: Decodable {
        let name: String
        let mode: String?
        let state: String?
        let reuse: Bool
        let explicitActivation: Bool
        let mismatchedMode: String?
        let expectedCalls: [String]
        let completeQuit: Bool?
        let expectedAfterCompletion: [String]?
    }
    private enum PresentationError: Error {
        case invalidDirectory, invalidPlan, missingQuitCompletion
        case cancelled(String)
        case calls(String, [String])
    }
    private final class PresentationMenuObserver: NSObject, NSMenuDelegate {
        var closed = false
        var onEvent: ((String) -> Void)?
        func menuWillOpen(_ menu: NSMenu) { closed = false; onEvent?("willOpen") }
        func menuDidClose(_ menu: NSMenu) { closed = true; onEvent?("didClose") }
    }
    @MainActor
    private final class PresentationFixture {
        let directory: URL
        let session = PresentationSession()
        var calls: [String] = []
        var starts: [String] = []
        var terminationDecisions: [UInt] = []
        var writeError: Error?
        var menuEvents: [[String: Any]] = []
        var scenario = "initializing"
        var delegate: MenuBarApplicationDelegate!
        init(directory: URL) {
            self.directory = directory
            session.record = { [weak self] in self?.record($0) }
            session.recordStart = { [weak self] in self?.starts.append($0) }
            delegate = MenuBarApplicationDelegate(
                controllerFactory: { [session] in session }, developmentBuild: true,
                requestTermination: { [weak self] in
                    guard let self else { return }
                    record("requestTermination")
                    // Exercise the real lifecycle guard without asking NSApplication to terminate.
                    terminationDecisions.append(delegate.applicationShouldTerminate(.shared).rawValue)
                },
                replyTermination: { [weak self] in self?.record("replyTermination:\($0)") },
                openSettings: { [weak self] in self?.record("openSettings:\($0.absoluteString)") }
            )
        }
        func record(_ call: String) {
            calls.append(call)
            do { try persist() } catch { writeError = error }
        }
        func persist() throws {
            let url = directory.appendingPathComponent("ledger.json")
            try JSONSerialization.data(withJSONObject: ["scenario": scenario, "calls": calls], options: [.sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        func recordMenuEvent(_ type: String) {
            menuEvents.append(["type": type, "uptime": ProcessInfo.processInfo.systemUptime,
                               "hostActive": NSApplication.shared.isActive,
                               "eventType": NSApplication.shared.currentEvent?.type.rawValue ?? 0])
            do {
                let url = directory.appendingPathComponent(scenario + "-menu-events.json")
                try JSONSerialization.data(withJSONObject: menuEvents, options: [.sortedKeys]).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { writeError = error }
        }
    }
    private final class PresentationSession: PrimaryApplicationControlling, DisplayModeSelecting {
        var selectedMode: DisplayApplicationMode?
        var requiresExplicitActivation = false
        var modeDidChange: (@MainActor () -> Void)?
        var record: ((String) -> Void)?
        var recordStart: ((String) -> Void)?
        var completedQuits: [Bool] = []
        private var onStatus: (@Sendable (PrimarySessionStatus) -> Void)?
        private var quitCompletion: (@Sendable (Bool) -> Void)?
        func startApplication(registerEvents: Bool, recoveryOnly: Bool,
                              onStatus: @escaping @Sendable (PrimarySessionStatus) -> Void) {
            recordStart?("registerEvents:\(registerEvents),recoveryOnly:\(recoveryOnly)")
            self.onStatus = onStatus
        }
        func emit(_ status: PrimarySessionStatus) { onStatus?(status) }
        func selectMode(_ mode: DisplayApplicationMode) {
            record?("selectMode:\(mode.rawValue)")
            selectedMode = mode
            requiresExplicitActivation = false
            modeDidChange?()
            emit(.applying)
        }
        func restoreForConfiguration() { record?("restoreForConfiguration"); emit(.applying) }
        func retryApplication() { record?("retryApplication"); emit(.applying) }
        func recoverApplication() { record?("recoverApplication"); emit(.applying) }
        func confirmCurrentConfiguration() { record?("confirmCurrentConfiguration"); emit(.applying) }
        func quitApplication(completion: @escaping @Sendable (Bool) -> Void) {
            record?("quitApplication")
            quitCompletion = completion
        }
        func completeQuit(_ value: Bool) throws {
            guard let completion = quitCompletion else { throw PresentationError.missingQuitCompletion }
            quitCompletion = nil
            completedQuits.append(value)
            completion(value)
        }
    }
}
