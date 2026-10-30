import ExtilumeCore
import XCTest
@testable import ExtilumeNative

final class ExternalAutomaticInputSessionTests: XCTestCase {
    func testCopiedAndRepreparedSessionsShareSelectionAuthorization() throws {
        let identity = ExternalDisplayIdentity(uuid: UUID(), registryPath: "IOService:/display/1",
                                               edidUUID: "1234-5678", bootSession: UUID(), registryEntryID: 42)
        let configuration = ExternalDisplayInputConfiguration(target: identity, pcInput: 0x11, automaticEnabled: true)
        let capabilities = ExternalDisplayInputCapabilities(target: identity, inputValues: [0x11])
        let deadline = try ContinuousClock.nanoseconds() + 2_000_000_000
        let grant = ExternalDisplayInputSelectionAuthorization(configuration: configuration, deadlineNanoseconds: deadline)
        var writes = 0
        let controller = ExternalDisplayInputController(explicitSelectionAuthorization: grant,
            bootSessionReader: { identity.bootSession }, probe: { request in
            switch request.operation {
            case .capabilities: return .capabilities(capabilities)
            case .selectInput(let input):
                writes += 1
                return .confirmed(target: identity, input: input)
            }
        })
        var first = ExternalAutomaticInputSession(configuration: configuration, capabilities: capabilities,
                                                   controller: controller, deadlineNanoseconds: deadline)
        XCTAssertTrue(first.prepare(for: identity))
        var copy = first
        let state = ExternalDisplayState(id: 42, identity: identity, isOnline: true, isActive: false)
        guard case .confirmed = first.sendOnce(to: identity, checkAccess: {}, authorizeWrite: { state }) else {
            return XCTFail("first selection should be confirmed")
        }
        guard case .unconfirmed = copy.sendOnce(to: identity, checkAccess: {}, authorizeWrite: { state }) else {
            return XCTFail("copy must not reuse authorization")
        }
        XCTAssertFalse(first.prepare(for: identity))
        XCTAssertEqual(writes, 1)
    }
}
