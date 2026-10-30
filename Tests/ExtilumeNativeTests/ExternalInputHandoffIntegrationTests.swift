import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

@MainActor
final class ExternalInputHandoffIntegrationTests: XCTestCase {
    private final class Preferences: DisplayModePreferenceStoring {
        var selectedMode: DisplayApplicationMode?
        var internalControlLocked = false
        var externalHandoffRequested = false
        var failNextSelection = false
        func select(_ mode: DisplayApplicationMode) throws {
            if failNextSelection { failNextSelection = false; throw RecoveryStoreError.ioFailure }
            selectedMode = mode
        }
        func lockInternalControl() throws { internalControlLocked = true }
        func setExternalHandoffRequested(_ requested: Bool) throws { externalHandoffRequested = requested }
    }

    private final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var selections: [UInt16] = []
        var factories = 0
        var reads = 0
        var results: [String] = []
    }

    func testExplicitSourceDisablesBeforeSendingAndZeroUUIDFallsBack() async throws {
        for zeroUUID in [false, true] {
            let fixture = try ExternalApplicationControllerTests.Fixture()
            fixture.zeroWhileDisabled = zeroUUID
            let name = "Extilume.InputIntegration.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let counts = Counts()
            let capabilities = ExternalDisplayInputCapabilities(target: fixture.identity, inputValues: [0x0F, 0x11])
            let settings = ExternalDisplayInputSettings(defaults: defaults, permitsExplicitInputSelection: true,
                discoverInputs: { check in try check(); return capabilities }, explicitController: { grant in
                    counts.lock.withLock { counts.factories += 1 }
                    return Self.inputController(grant: grant, fixture: fixture, counts: counts, capabilities: capabilities)
                })
            let coordinator = try DisplayModeCoordinator(directory: fixture.directory, preferences: Preferences(),
                availableModes: [.externalPrimary, .internalOnly], inputSettings: settings) { _, _, store in
                    try fixture.controller(recoveryStore: store)
                }
            coordinator.startApplication(registerEvents: false, recoveryOnly: false) { status in
                fixture.lock.withLock { fixture.statuses.append(status) }
            }
            coordinator.detectInputSources()
            await waitForDetection(settings)
            XCTAssertEqual(coordinator.detectedInputOptions, [0x0F, 0x11])
            coordinator.disableExternal(selectingInput: 0x0F)
            try await fixture.waitFor(.applied)
            XCTAssertEqual(fixture.writeCount, 1)
            XCTAssertTrue(try fixture.record().requiresRecovery)
            XCTAssertEqual(counts.lock.withLock { counts.selections }, zeroUUID ? [] : [0x0F])
            XCTAssertFalse(settings.automaticInputEnabled)
            XCTAssertNil(settings.automaticSession)
        }
    }

    func testUndetectedConnectionStillDisablesWithoutInputPreparation() async throws {
        let fixture = try ExternalApplicationControllerTests.Fixture()
        let name = "Extilume.InputFallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let counts = Counts()
        let settings = ExternalDisplayInputSettings(defaults: defaults, permitsExplicitInputSelection: true,
            discoverInputs: { _ in throw ExternalDisplayInputFailure.unsupportedTransport }, explicitController: { grant in
                counts.lock.withLock { counts.factories += 1 }
                return ExternalDisplayInputController(explicitSelectionAuthorization: grant)
            })
        let coordinator = try DisplayModeCoordinator(directory: fixture.directory, preferences: Preferences(),
            availableModes: [.externalPrimary, .internalOnly], inputSettings: settings) { _, _, store in
                try fixture.controller(recoveryStore: store)
            }
        coordinator.startApplication(registerEvents: false, recoveryOnly: false) { status in
            fixture.lock.withLock { fixture.statuses.append(status) }
        }
        coordinator.detectInputSources()
        await waitForDetection(settings)
        XCTAssertFalse(coordinator.canSelectDetectedInput)
        coordinator.selectMode(.internalOnly)
        try await fixture.waitFor(.applied)
        XCTAssertEqual(fixture.writeCount, 1)
        XCTAssertEqual(counts.lock.withLock { counts.factories }, 0)
    }

    func testAlreadyDisabledSourceSelectionDoesNotReenableOrDisableAgain() async throws {
        let fixture = try ExternalApplicationControllerTests.Fixture()
        try fixture.seedHeld()
        let controller = try fixture.controller()
        fixture.start(controller, recoveryOnly: true)
        try await fixture.waitFor(.applied)
        let counts = Counts()
        controller.configureAutomaticInput(nil) { result in
            counts.lock.withLock { counts.results.append(String(describing: result)) }
        }
        let configuration = ExternalDisplayInputConfiguration(target: fixture.identity, pcInput: 0x11, automaticEnabled: true)
        let deadline = try ContinuousClock.nanoseconds() + 3_000_000_000
        let grant = ExternalDisplayInputSelectionAuthorization(configuration: configuration, deadlineNanoseconds: deadline)
        let capabilities = ExternalDisplayInputCapabilities(target: fixture.identity, inputValues: [0x11])
        let input = Self.inputController(grant: grant, fixture: fixture, counts: counts, capabilities: capabilities)
        let session = ExternalAutomaticInputSession(configuration: configuration, capabilities: capabilities,
            controller: input, deadlineNanoseconds: deadline)
        controller.selectInputWhileDisabled(session)
        try await fixture.waitFor(.applied, count: 2)
        XCTAssertEqual(fixture.writeCount, 0)
        XCTAssertEqual(counts.lock.withLock { counts.selections }, [0x11], String(describing: counts.lock.withLock { (counts.reads, counts.results) }))
        controller.selectInputWhileDisabled(session)
        try await fixture.waitFor(.applied, count: 3)
        XCTAssertEqual(counts.lock.withLock { counts.selections }, [0x11])
    }

    func testFailedSourceRequestCannotLeakIntoOrdinaryDisable() async throws {
        for failure in ["preferences", "factory"] {
            let fixture = try ExternalApplicationControllerTests.Fixture()
            let name = "Extilume.InputFailure.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let counts = Counts(), preferences = Preferences()
            let capabilities = ExternalDisplayInputCapabilities(target: fixture.identity, inputValues: [0x11])
            let settings = ExternalDisplayInputSettings(defaults: defaults, permitsExplicitInputSelection: true,
                discoverInputs: { _ in capabilities }, explicitController: { grant in
                    Self.inputController(grant: grant, fixture: fixture, counts: counts, capabilities: capabilities)
                })
            var failFactory = failure == "factory"
            let coordinator = try DisplayModeCoordinator(directory: fixture.directory, preferences: preferences,
                availableModes: [.externalPrimary, .internalOnly], inputSettings: settings) { _, _, store in
                    if failFactory { failFactory = false; throw RecoveryStoreError.ioFailure }
                    return try fixture.controller(recoveryStore: store)
                }
            coordinator.startApplication(registerEvents: false, recoveryOnly: false) { status in
                fixture.lock.withLock { fixture.statuses.append(status) }
            }
            coordinator.detectInputSources()
            await waitForDetection(settings)
            preferences.failNextSelection = failure == "preferences"
            coordinator.disableExternal(selectingInput: 0x11)
            XCTAssertEqual(fixture.writeCount, 0)
            coordinator.selectMode(.internalOnly)
            try await fixture.waitFor(.applied)
            XCTAssertEqual(fixture.writeCount, 1)
            XCTAssertEqual(counts.lock.withLock { counts.reads }, 0)
            XCTAssertTrue(counts.lock.withLock { counts.selections.isEmpty })
        }
    }

    private func waitForDetection(_ settings: ExternalDisplayInputSettings) async {
        for _ in 0..<200 {
            if !settings.detectingInputSources { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("input detection did not finish")
    }

    private nonisolated static func inputController(grant: ExternalDisplayInputSelectionAuthorization,
        fixture: ExternalApplicationControllerTests.Fixture, counts: Counts,
        capabilities: ExternalDisplayInputCapabilities) -> ExternalDisplayInputController {
        ExternalDisplayInputController(explicitSelectionAuthorization: grant,
            bootSessionReader: { fixture.identity.bootSession }, probe: { request in
                switch request.operation {
                case .capabilities:
                    counts.lock.withLock { counts.reads += 1 }
                    return .capabilities(capabilities)
                case .selectInput(let value):
                    XCTAssertFalse(fixture.readExternal().isEnabled)
                    counts.lock.withLock { counts.selections.append(value) }
                    return .confirmed(target: fixture.identity, input: value)
                }
            })
    }
}
