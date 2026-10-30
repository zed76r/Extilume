import ExtilumeCore
import XCTest
@testable import ExtilumeNative

final class ExternalDisplayInputTests: XCTestCase {
    func testCapabilitiesParserReturnsOnlyStandardInputValues() throws {
        let identity = target()
        let capabilities = try ExternalDisplayInputCapabilities.parse(
            "(prot(monitor)type(LCD)cmds(01 02 03 E3 F3)vcp(10 60(01 0F 11 12) D6(01 04)))",
            target: identity
        )

        XCTAssertEqual(capabilities.target, identity)
        XCTAssertEqual(capabilities.inputValues, [0x01, 0x0F, 0x11, 0x12])
    }

    func testCapabilitiesParserFailsClosedWithoutEnumeratedInputValues() {
        XCTAssertThrowsError(try ExternalDisplayInputDDC.parseInputValues("(vcp(10 12))")) {
            XCTAssertEqual($0 as? ExternalDisplayInputFailure, .unsupportedInput)
        }
        XCTAssertThrowsError(try ExternalDisplayInputDDC.parseInputValues("(vcp(60(11) 60(12)))")) {
            XCTAssertEqual($0 as? ExternalDisplayInputFailure, .invalidCapabilities)
        }
    }

    func testStandardPacketsAndReadbackReplyUseVCP60() throws {
        let read = ExternalDisplayInputDDC.getVCP(0x60)
        let write = try XCTUnwrap(ExternalDisplayInputDDC.setInput(0x11))
        XCTAssertEqual(Array(read.prefix(3)), [0x82, 0x01, 0x60])
        XCTAssertEqual(Array(write.prefix(5)), [0x84, 0x03, 0x60, 0x00, 0x11])
        XCTAssertEqual(xor([0x6E, 0x51] + read), 0)
        XCTAssertEqual(xor([0x6E, 0x51] + write), 0)
        XCTAssertNil(ExternalDisplayInputDDC.setInput(0x100))

        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x60, 0x00, 0x00, 0x14, 0x00, 0x11]
        reply.append(0x50 ^ xor(reply))
        XCTAssertEqual(try ExternalDisplayInputDDC.parseVCPReply(reply, code: 0x60), 0x11)
        XCTAssertThrowsError(try ExternalDisplayInputDDC.parseVCPReply(reply, code: 0x10))
    }

    func testVCPReplyUsesHostReplyChecksumSeed() throws {
        // DDC/CI reply checksum includes the implicit 0x50 host address.
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x43, 0x83]
        XCTAssertEqual(try ExternalDisplayInputDDC.parseVCPReply(reply, code: 0x10), 0x43)
        var invalid = reply
        invalid[10] ^= 0x50
        XCTAssertThrowsError(try ExternalDisplayInputDDC.parseVCPReply(invalid, code: 0x10))
    }

    func testCapabilitiesReplyChecksOffsetAndChecksum() throws {
        var reply: [UInt8] = [0x6E, 0xA3, 0xE3, 0x00, 0x20] + Array(repeating: 0x41, count: 32)
        reply.append(0x50 ^ xor(reply))
        XCTAssertEqual(try ExternalDisplayInputDDC.parseCapabilitiesReply(reply, offset: 0x20), Array(repeating: 0x41, count: 32))
        XCTAssertThrowsError(try ExternalDisplayInputDDC.parseCapabilitiesReply(reply, offset: 0x00))

        reply[10] ^= 0x01
        XCTAssertThrowsError(try ExternalDisplayInputDDC.parseCapabilitiesReply(reply, offset: 0x20))
    }

    func testDefaultGateIsUnavailableAndAutomaticSelectionDefaultsOff() throws {
        let identity = target()
        let controller = ExternalDisplayInputController(probe: { _ in XCTFail("probe should not run"); return .failed(.unsupportedTransport) })
        XCTAssertEqual(controller.availability(for: identity), .unavailable(.hardwareAcceptanceRequired))
        let configuration = ExternalDisplayInputConfiguration(target: identity, pcInput: 0x11)
        XCTAssertFalse(configuration.automaticEnabled)
        XCTAssertThrowsError(try controller.sendOnce(
            configuration,
            capabilities: ExternalDisplayInputCapabilities(target: identity, inputValues: [0x11]),
            deadlineNanoseconds: try ContinuousClock.nanoseconds() + 1_000_000_000
        )) {
            XCTAssertEqual($0 as? ExternalDisplayInputFailure, .hardwareAcceptanceRequired)
        }
    }

    func testWrongTargetAndUnsupportedInputDoNotWrite() throws {
        let identity = target()
        let other = target()
        let transport = FakeTransport(inputValues: [0x11], readback: 0x11)
        let controller = ExternalDisplayInputController(
            hardwareVerifiedTarget: identity,
            bootSessionReader: { identity.bootSession }
        ) { request in
            executeExternalDisplayInputProbe(request, transport: transport, now: { 1 }, sleep: { _ in }, authorizeWrite: {})
        }
        let capabilities = ExternalDisplayInputCapabilities(target: identity, inputValues: [0x11])

        XCTAssertThrowsError(try controller.sendOnce(
            ExternalDisplayInputConfiguration(target: other, pcInput: 0x11),
            capabilities: capabilities,
            deadlineNanoseconds: UInt64.max
        )) {
            XCTAssertEqual($0 as? ExternalDisplayInputFailure, .identityMismatch)
        }
        XCTAssertThrowsError(try controller.sendOnce(
            ExternalDisplayInputConfiguration(target: identity, pcInput: 0x12),
            capabilities: capabilities,
            deadlineNanoseconds: UInt64.max
        )) {
            XCTAssertEqual($0 as? ExternalDisplayInputFailure, .unsupportedInput)
        }
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testDeadlineExpiryDoesNotWrite() {
        let identity = target()
        let transport = FakeTransport(inputValues: [0x11], readback: 0x11)
        let reply = executeExternalDisplayInputProbe(
            ExternalDisplayInputProbeRequest(
                target: identity,
                operation: .selectInput(0x11),
                deadlineNanoseconds: 10
            ),
            transport: transport,
            now: { 10 },
            sleep: { _ in }, authorizeWrite: {}
        )
        XCTAssertEqual(reply, .failed(.timedOut))
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testControllerReportsIsolatedProbeTimeout() throws {
        let identity = target()
        let controller = ExternalDisplayInputController(
            hardwareVerifiedTarget: identity,
            bootSessionReader: { identity.bootSession },
            probe: { _ in throw SnapshotWitnessError.timedOut }
        )
        XCTAssertThrowsError(try controller.sendOnce(
            ExternalDisplayInputConfiguration(target: identity, pcInput: 0x11),
            capabilities: ExternalDisplayInputCapabilities(target: identity, inputValues: [0x11]),
            deadlineNanoseconds: try ContinuousClock.nanoseconds() + 1_000_000_000
        )) {
            XCTAssertEqual($0 as? ExternalDisplayInputFailure, .timedOut)
        }
    }

    func testReadbackMismatchAndLossNeverRetryTheSingleInputWrite() {
        let identity = target()
        let deadline = UInt64.max

        let mismatch = FakeTransport(inputValues: [0x11], readback: 0x0F)
        XCTAssertEqual(executeExternalDisplayInputProbe(
            ExternalDisplayInputProbeRequest(target: identity, operation: .selectInput(0x11), deadlineNanoseconds: deadline),
            transport: mismatch,
            now: { 1 },
            sleep: { _ in }, authorizeWrite: {}
        ), .failed(.readbackMismatch))
        XCTAssertEqual(mismatch.writes, [0x11])

        let unavailable = FakeTransport(inputValues: [0x11], readback: nil)
        XCTAssertEqual(executeExternalDisplayInputProbe(
            ExternalDisplayInputProbeRequest(target: identity, operation: .selectInput(0x11), deadlineNanoseconds: deadline),
            transport: unavailable,
            now: { 1 },
            sleep: { _ in }, authorizeWrite: {}
        ), .failed(.readbackUnavailable))
        XCTAssertEqual(unavailable.writes, [0x11])
    }

    func testCapabilityProbeDoesNotAuthorizeOrWrite() {
        let identity = target()
        let transport = FakeTransport(inputValues: [0x11], readback: 0x11)
        let reply = executeExternalDisplayInputProbe(
            ExternalDisplayInputProbeRequest(target: identity, operation: .capabilities, deadlineNanoseconds: 10),
            transport: transport, now: { 1 }, sleep: { _ in }, authorizeWrite: { XCTFail("unexpected authorization") }
        )
        XCTAssertEqual(reply, .capabilities(ExternalDisplayInputCapabilities(target: identity, inputValues: [0x11])))
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testAuthorizationFailureAfterCapabilitiesPreventsWrite() {
        let identity = target()
        let transport = FakeTransport(inputValues: [0x11], readback: 0x11)
        let reply = executeExternalDisplayInputProbe(
            ExternalDisplayInputProbeRequest(target: identity, operation: .selectInput(0x11), deadlineNanoseconds: 10),
            transport: transport, now: { 1 }, sleep: { _ in },
            authorizeWrite: { throw ExternalDisplayInputFailure.hardwareAcceptanceRequired }
        )
        XCTAssertEqual(reply, .failed(.hardwareAcceptanceRequired))
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testWriteApprovalChecksReadyAndFreshState() throws {
        let identity = target()
        let deadline = try ContinuousClock.nanoseconds() + 2_000_000_000
        let request = ExternalDisplayInputProbeRequest(target: identity, operation: .selectInput(0x11), deadlineNanoseconds: deadline)
        let (parent, child) = try GuardChannel.pair()
        let state = ExternalDisplayState(id: 42, identity: identity, isOnline: true, isActive: false)
        try child.send(ExternalDisplayInputWriteReady(target: identity, input: 0x11, deadlineNanoseconds: deadline), deadlineNanoseconds: deadline)
        try approveExternalDisplayInputWrite(request, channel: parent, checkAccess: {}, authorizeWrite: { state })
        XCTAssertEqual(try child.receive(ExternalDisplayState.self, deadlineNanoseconds: deadline), state)

        let (parent2, child2) = try GuardChannel.pair()
        try child2.send(ExternalDisplayInputWriteReady(target: target(), input: 0x11, deadlineNanoseconds: deadline), deadlineNanoseconds: deadline)
        XCTAssertThrowsError(try approveExternalDisplayInputWrite(request, channel: parent2, checkAccess: {}, authorizeWrite: { XCTFail("wrong target"); return state }))

        let (rejectedParent, rejectedChild) = try GuardChannel.pair()
        try rejectedChild.send(ExternalDisplayInputWriteReady(target: identity, input: 0x11, deadlineNanoseconds: deadline), deadlineNanoseconds: deadline)
        XCTAssertThrowsError(try approveExternalDisplayInputWrite(request, channel: rejectedParent, checkAccess: {}, authorizeWrite: nil))
        let (cancelledParent, cancelledChild) = try GuardChannel.pair()
        try cancelledChild.send(ExternalDisplayInputWriteReady(target: identity, input: 0x11, deadlineNanoseconds: deadline), deadlineNanoseconds: deadline)
        XCTAssertThrowsError(try approveExternalDisplayInputWrite(request, channel: cancelledParent, checkAccess: {
            throw ExternalDisplayInputFailure.hardwareAcceptanceRequired
        }, authorizeWrite: { XCTFail("cancelled"); return state }))

        let (parent3, child3) = try GuardChannel.pair()
        try parent3.send(state, deadlineNanoseconds: deadline)
        try requestExternalDisplayInputWriteApproval(request, channel: child3, read: { target, id in
            XCTAssertEqual(target, identity)
            XCTAssertEqual(id, 42)
            return state
        })
        XCTAssertEqual(try parent3.receive(ExternalDisplayInputWriteReady.self, deadlineNanoseconds: deadline),
                       ExternalDisplayInputWriteReady(target: identity, input: 0x11, deadlineNanoseconds: deadline))

        let (parent4, child4) = try GuardChannel.pair()
        try parent4.send(state, deadlineNanoseconds: deadline)
        XCTAssertThrowsError(try requestExternalDisplayInputWriteApproval(request, channel: child4, read: { _, _ in
            ExternalDisplayState(id: 43, identity: identity, isOnline: true, isActive: false)
        }))
    }

    func testGrantIsSingleUseAndExact() {
        let identity = target()
        let config = ExternalDisplayInputConfiguration(target: identity, pcInput: 0x11, automaticEnabled: true)
        let grant = ExternalDisplayInputSelectionAuthorization(configuration: config, deadlineNanoseconds: 10)
        XCTAssertTrue(grant.isAvailable(for: identity, now: 1))
        XCTAssertFalse(grant.consume(configuration: config, deadlineNanoseconds: 11, now: 1))
        XCTAssertFalse(grant.consume(configuration: config, deadlineNanoseconds: 10, now: 1))
        for wrong in [ExternalDisplayInputConfiguration(target: target(), pcInput: 0x11, automaticEnabled: true),
                      ExternalDisplayInputConfiguration(target: identity, pcInput: 0x12, automaticEnabled: true)] {
            let separate = ExternalDisplayInputSelectionAuthorization(configuration: config, deadlineNanoseconds: 10)
            XCTAssertFalse(separate.consume(configuration: wrong, deadlineNanoseconds: 10, now: 1))
            XCTAssertFalse(separate.isAvailable(for: identity, now: 1))
        }
        let expired = ExternalDisplayInputSelectionAuthorization(configuration: config, deadlineNanoseconds: 10)
        XCTAssertFalse(expired.consume(configuration: config, deadlineNanoseconds: 10, now: 10))
    }

    private func target() -> ExternalDisplayIdentity {
        ExternalDisplayIdentity(
            uuid: UUID(),
            registryPath: "IOService:/display/1",
            edidUUID: "1234-5678",
            bootSession: UUID(),
            registryEntryID: 42
        )
    }

    private func xor(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(UInt8(0)) { $0 ^ $1 }
    }
}

private final class FakeTransport: ExternalDisplayInputTransport {
    let inputValues: Set<UInt16>
    let readback: UInt16?
    private(set) var writes: [UInt16] = []

    init(inputValues: Set<UInt16>, readback: UInt16?) {
        self.inputValues = inputValues
        self.readback = readback
    }

    func readCapabilities(for target: ExternalDisplayIdentity, deadlineNanoseconds: UInt64) throws -> Set<UInt16> {
        inputValues
    }

    func writeInput(_ input: UInt16, to target: ExternalDisplayIdentity, deadlineNanoseconds: UInt64) throws {
        writes.append(input)
    }

    func readInput(for target: ExternalDisplayIdentity, deadlineNanoseconds: UInt64) throws -> UInt16 {
        guard let readback else { throw ExternalDisplayInputFailure.readbackUnavailable }
        return readback
    }
}
