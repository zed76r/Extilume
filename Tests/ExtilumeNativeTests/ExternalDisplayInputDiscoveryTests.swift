import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

private final class DiscoveryBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.withLock { value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

private struct DiscoveryStub: ExternalDisplayInputControlling {
    func availability(for target: ExternalDisplayIdentity) -> ExternalDisplayInputAvailability { .available }
    func readCapabilities(for target: ExternalDisplayIdentity, deadlineNanoseconds: UInt64) throws -> ExternalDisplayInputCapabilities {
        throw ExternalDisplayInputFailure.unsupportedTransport
    }
    func sendOnce(_ configuration: ExternalDisplayInputConfiguration, capabilities: ExternalDisplayInputCapabilities,
                  deadlineNanoseconds: UInt64) throws { XCTFail("unexpected write") }
}

@MainActor
final class ExternalDisplayInputDiscoveryTests: XCTestCase {
    func testDefaultAndDisabledProgrammaticDetectionNeverProbeOrGrant() throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let calls = DiscoveryBox(0)
        let settings = ExternalDisplayInputSettings(defaults: defaults, inputController: DiscoveryStub(),
            discoverInputs: { _ in calls.update { $0 += 1 }; throw ExternalDisplayInputFailure.unsupportedTransport },
            explicitController: { _ in XCTFail("unexpected grant"); return DiscoveryStub() })
        XCTAssertFalse(settings.detectingInputSources)
        XCTAssertEqual(settings.detectedInputOptions, [])
        XCTAssertNil(settings.explicitSession(selecting: 0x11))
        settings.detectInputSources()
        XCTAssertFalse(settings.detectingInputSources)
        XCTAssertEqual(calls.read(), 0)
        XCTAssertNil(settings.explicitSession(selecting: 0x11))
        XCTAssertFalse(settings.automaticInputEnabled)
        XCTAssertNil(settings.automaticSession)
    }

    func testDetectionProducesExactShortLivedGrantWithoutEnablingAutomaticMode() async throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let caps = capabilities([0x12, 0x11])
        let clock = DiscoveryBox(UInt64(100))
        let calls = DiscoveryBox(0)
        var granted: ExternalDisplayInputSelectionAuthorization?
        let settings = ExternalDisplayInputSettings(defaults: defaults, inputController: DiscoveryStub(),
            permitsExplicitInputSelection: true,
            discoverInputs: { check in
                calls.update { $0 += 1 }
                try check()
                return caps
            }, explicitController: { grant in granted = grant; return DiscoveryStub() },
            now: { clock.read() })
        let completed = expectation(description: "discovery completed")
        settings.inputSettingsDidChange = { if !settings.detectingInputSources { completed.fulfill() } }
        settings.detectInputSources()
        settings.detectInputSources()
        await fulfillment(of: [completed], timeout: 2)
        settings.inputSettingsDidChange = nil
        XCTAssertEqual(calls.read(), 1)
        XCTAssertEqual(settings.detectedInputOptions, [0x11, 0x12])
        XCTAssertNil(settings.explicitSession(selecting: 0x0F))
        let session = try XCTUnwrap(settings.explicitSession(selecting: 0x12))
        let grant = try XCTUnwrap(granted)
        XCTAssertEqual(grant.configuration, ExternalDisplayInputConfiguration(target: caps.target, pcInput: 0x12, automaticEnabled: true))
        XCTAssertEqual(session.configuration, grant.configuration)
        XCTAssertEqual(grant.deadlineNanoseconds, 3_000_000_100)
        XCTAssertFalse(settings.automaticInputEnabled)
        XCTAssertNil(settings.automaticSession)
        clock.update { $0 = 30_000_000_100 }
        XCTAssertEqual(settings.detectedInputOptions, [])
        XCTAssertNil(settings.explicitSession(selecting: 0x11))
    }

    func testUnsupportedThrownEmptyAndInvalidCapabilitiesDegrade() async throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        let valid = capabilities([0x11])
        let cases: [Result<ExternalDisplayInputCapabilities, ExternalDisplayInputFailure>] = [
            .failure(.unsupportedTransport), .failure(.timedOut),
            .success(ExternalDisplayInputCapabilities(target: valid.target, inputValues: [])),
            .success(ExternalDisplayInputCapabilities(target: valid.target, inputValues: [0x100]))
        ]
        for result in cases {
            let settings = ExternalDisplayInputSettings(defaults: defaults, inputController: DiscoveryStub(),
                permitsExplicitInputSelection: true, discoverInputs: { _ in try result.get() },
                explicitController: { _ in XCTFail("unexpected grant"); return DiscoveryStub() })
            let completed = expectation(description: "failed detection")
            settings.inputSettingsDidChange = { if !settings.detectingInputSources { completed.fulfill() } }
            settings.detectInputSources()
            await fulfillment(of: [completed], timeout: 2)
            settings.inputSettingsDidChange = nil
            XCTAssertEqual(settings.detectedInputOptions, [])
            XCTAssertNil(settings.explicitSession(selecting: 0x11))
            XCTAssertTrue(settings.inputDiscoveryMessage?.contains("可直接停用外接屏") == true)
            XCTAssertFalse(settings.automaticInputEnabled)
            XCTAssertNil(settings.automaticSession)
        }
    }

    func testCancellationRejectsWorkerAndOldResultCannotReplaceNewDetection() async throws {
        let (name, defaults) = try preferences()
        defer { defaults.removePersistentDomain(forName: name) }
        for staleFailure in [false, true] {
            let old = capabilities([0x11])
            let newer = capabilities([0x12])
            let calls = DiscoveryBox(0)
            let oldCancelled = DiscoveryBox(false)
            let releaseOld = DispatchSemaphore(value: 0)
            let oldStarted = expectation(description: "old worker started")
            let oldReturned = expectation(description: "old worker returned")
            let settings = ExternalDisplayInputSettings(defaults: defaults, inputController: DiscoveryStub(),
                permitsExplicitInputSelection: true, discoverInputs: { check in
                    var number = 0
                    calls.update { $0 += 1; number = $0 }
                    if number == 1 {
                        oldStarted.fulfill()
                        _ = releaseOld.wait(timeout: .now() + 2)
                        do { try check() } catch { oldCancelled.update { $0 = true } }
                        oldReturned.fulfill()
                        if staleFailure { throw ExternalDisplayInputFailure.unsupportedTransport }
                        return old
                    }
                    try check()
                    return newer
                }, explicitController: { _ in DiscoveryStub() }, now: { 1 })
            settings.detectInputSources()
            await fulfillment(of: [oldStarted], timeout: 2)
            settings.cancelInputDetection()
            XCTAssertFalse(settings.detectingInputSources)
            let newCompleted = expectation(description: "new detection completed")
            settings.inputSettingsDidChange = { if !settings.detectingInputSources { newCompleted.fulfill() } }
            settings.detectInputSources()
            await fulfillment(of: [newCompleted], timeout: 2)
            XCTAssertEqual(settings.detectedInputOptions, [0x12])
            let staleCallback = expectation(description: "stale result must not notify")
            staleCallback.isInverted = true
            settings.inputSettingsDidChange = { staleCallback.fulfill() }
            releaseOld.signal()
            await fulfillment(of: [oldReturned, staleCallback], timeout: 0.3)
            XCTAssertTrue(oldCancelled.read())
            XCTAssertEqual(settings.detectedInputOptions, [0x12])
            XCTAssertEqual(calls.read(), 2)
        }
    }

    private func preferences() throws -> (String, UserDefaults) {
        let name = "ExtilumeInputDiscovery.\(UUID().uuidString)"
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }

    private func capabilities(_ values: Set<UInt16>) -> ExternalDisplayInputCapabilities {
        let identity = ExternalDisplayIdentity(uuid: UUID(), registryPath: "IOService:/display/1",
            edidUUID: "test-edid", bootSession: UUID(), registryEntryID: 42)
        return ExternalDisplayInputCapabilities(target: identity, inputValues: values)
    }
}
