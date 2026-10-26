import CoreFoundation
import Darwin
import ExtilumeCore
import Foundation
import IOKit

struct ExternalDisplayInputConfiguration: Codable, Equatable, Sendable {
    let target: ExternalDisplayIdentity
    let pcInput: UInt16
    let automaticEnabled: Bool

    init(target: ExternalDisplayIdentity, pcInput: UInt16, automaticEnabled: Bool = false) {
        self.target = target
        self.pcInput = pcInput
        self.automaticEnabled = automaticEnabled
    }

    func validate(capabilities: ExternalDisplayInputCapabilities) throws {
        do { try target.validate() }
        catch { throw ExternalDisplayInputFailure.identityMismatch }
        guard capabilities.target == target else {
            throw ExternalDisplayInputFailure.identityMismatch
        }
        guard pcInput <= UInt16(UInt8.max) else { throw ExternalDisplayInputFailure.invalidInput }
        guard capabilities.inputValues.contains(pcInput) else {
            throw ExternalDisplayInputFailure.unsupportedInput
        }
    }
}

struct ExternalDisplayInputCapabilities: Codable, Equatable, Sendable {
    let target: ExternalDisplayIdentity
    let inputValues: Set<UInt16>

    func validate(for expectedTarget: ExternalDisplayIdentity) throws {
        do { try target.validate(); try expectedTarget.validate() }
        catch { throw ExternalDisplayInputFailure.identityMismatch }
        guard target == expectedTarget, !inputValues.isEmpty,
              inputValues.allSatisfy({ $0 <= UInt16(UInt8.max) }) else {
            throw ExternalDisplayInputFailure.invalidCapabilities
        }
    }

    static func parse(_ value: String, target: ExternalDisplayIdentity) throws -> Self {
        do { try target.validate() }
        catch { throw ExternalDisplayInputFailure.identityMismatch }
        return Self(target: target, inputValues: try ExternalDisplayInputDDC.parseInputValues(value))
    }
}

enum ExternalDisplayInputFailure: String, Codable, Error, Equatable, Sendable {
    case hardwareAcceptanceRequired
    case identityMismatch
    case invalidInput
    case unsupportedInput
    case invalidCapabilities
    case unsupportedTransport
    case readbackUnavailable
    case readbackMismatch
    case timedOut
}

enum ExternalDisplayInputAvailability: Equatable {
    case unavailable(ExternalDisplayInputFailure)
    case available
}

protocol ExternalDisplayInputControlling {
    func availability(for target: ExternalDisplayIdentity) -> ExternalDisplayInputAvailability
    func readCapabilities(
        for target: ExternalDisplayIdentity,
        deadlineNanoseconds: UInt64
    ) throws -> ExternalDisplayInputCapabilities
    func sendOnce(
        _ configuration: ExternalDisplayInputConfiguration,
        capabilities: ExternalDisplayInputCapabilities,
        deadlineNanoseconds: UInt64
    ) throws
}

enum ExternalDisplayInputProbeOperation: Codable, Equatable {
    case capabilities
    case selectInput(UInt16)
}

struct ExternalDisplayInputProbeRequest: Codable, Equatable {
    let target: ExternalDisplayIdentity
    let operation: ExternalDisplayInputProbeOperation
    let deadlineNanoseconds: UInt64
}

enum ExternalDisplayInputProbeReply: Codable, Equatable {
    case capabilities(ExternalDisplayInputCapabilities)
    case confirmed(target: ExternalDisplayIdentity, input: UInt16)
    case failed(ExternalDisplayInputFailure)
}

protocol ExternalDisplayInputTransport {
    func readCapabilities(for target: ExternalDisplayIdentity, deadlineNanoseconds: UInt64) throws -> Set<UInt16>
    func writeInput(_ input: UInt16, to target: ExternalDisplayIdentity, deadlineNanoseconds: UInt64) throws
    func readInput(for target: ExternalDisplayIdentity, deadlineNanoseconds: UInt64) throws -> UInt16
}

final class ExternalDisplayInputController: ExternalDisplayInputControlling {
    typealias Probe = (ExternalDisplayInputProbeRequest) throws -> ExternalDisplayInputProbeReply

    private let hardwareVerifiedTarget: ExternalDisplayIdentity?
    private let bootSessionReader: () -> UUID?
    private let probe: Probe

    init(
        hardwareVerifiedTarget: ExternalDisplayIdentity? = nil,
        bootSessionReader: @escaping () -> UUID? = { try? currentBootSession() },
        probe: @escaping Probe = runExternalDisplayInputProbe
    ) {
        self.hardwareVerifiedTarget = hardwareVerifiedTarget
        self.bootSessionReader = bootSessionReader
        self.probe = probe
    }

    func availability(for target: ExternalDisplayIdentity) -> ExternalDisplayInputAvailability {
        do { try target.validate() }
        catch { return .unavailable(.identityMismatch) }
        guard let hardwareVerifiedTarget else { return .unavailable(.hardwareAcceptanceRequired) }
        guard hardwareVerifiedTarget == target,
              bootSessionReader() == target.bootSession else {
            return .unavailable(.identityMismatch)
        }
        return .available
    }

    func readCapabilities(
        for target: ExternalDisplayIdentity,
        deadlineNanoseconds: UInt64
    ) throws -> ExternalDisplayInputCapabilities {
        do { try target.validate() }
        catch { throw ExternalDisplayInputFailure.identityMismatch }
        guard try ContinuousClock.nanoseconds() < deadlineNanoseconds else {
            throw ExternalDisplayInputFailure.timedOut
        }
        let reply = try run(ExternalDisplayInputProbeRequest(
            target: target,
            operation: .capabilities,
            deadlineNanoseconds: deadlineNanoseconds
        ))
        guard case .capabilities(let capabilities) = reply else {
            try throwFailure(reply)
            throw ExternalDisplayInputFailure.invalidCapabilities
        }
        try capabilities.validate(for: target)
        return capabilities
    }

    func sendOnce(
        _ configuration: ExternalDisplayInputConfiguration,
        capabilities: ExternalDisplayInputCapabilities,
        deadlineNanoseconds: UInt64
    ) throws {
        try configuration.validate(capabilities: capabilities)
        if case .unavailable(let failure) = availability(for: configuration.target) { throw failure }
        guard try ContinuousClock.nanoseconds() < deadlineNanoseconds else {
            throw ExternalDisplayInputFailure.timedOut
        }
        let reply = try run(ExternalDisplayInputProbeRequest(
            target: configuration.target,
            operation: .selectInput(configuration.pcInput),
            deadlineNanoseconds: deadlineNanoseconds
        ))
        guard case .confirmed(let target, let input) = reply else {
            try throwFailure(reply)
            throw ExternalDisplayInputFailure.readbackMismatch
        }
        guard target == configuration.target, input == configuration.pcInput else {
            throw ExternalDisplayInputFailure.readbackMismatch
        }
    }

    private func throwFailure(_ reply: ExternalDisplayInputProbeReply) throws {
        if case .failed(let failure) = reply { throw failure }
    }

    private func run(_ request: ExternalDisplayInputProbeRequest) throws -> ExternalDisplayInputProbeReply {
        do { return try probe(request) }
        catch { throw ExternalDisplayInputFailure.from(error) }
    }
}

private extension ExternalDisplayInputFailure {
    static func from(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if error as? SnapshotWitnessError == .timedOut || error as? GuardChannelError == .timedOut {
            return .timedOut
        }
        return .unsupportedTransport
    }
}

func runExternalDisplayInputProbe(
    _ request: ExternalDisplayInputProbeRequest
) throws -> ExternalDisplayInputProbeReply {
    try freshWitness(
        ExternalDisplayInputProbeReply.self,
        arguments: ["--external-display-input"],
        deadlineNanoseconds: request.deadlineNanoseconds,
        prepare: { channel, check in
            try channel.send(request, deadlineNanoseconds: request.deadlineNanoseconds, checkAccess: check)
        },
        validate: { reply in
            switch (request.operation, reply) {
            case (.capabilities, .capabilities(let capabilities)):
                return capabilities.target == request.target && !capabilities.inputValues.isEmpty
            case (.selectInput(let input), .confirmed(let target, let actual)):
                return target == request.target && input == actual
            case (_, .failed):
                return true
            default:
                return false
            }
        }
    )
}

public func runExternalDisplayInputProbeIfRequested(
    arguments: [String] = Array(CommandLine.arguments.dropFirst())
) throws -> Bool {
    try runExternalDisplayInputProbeIfRequested(
        arguments: arguments,
        transport: AppleSiliconExternalDisplayInputTransport()
    )
}

func runExternalDisplayInputProbeIfRequested(
    arguments: [String],
    transport: ExternalDisplayInputTransport
) throws -> Bool {
    guard arguments.first == "--external-display-input" else { return false }
    guard arguments.count == 2, let descriptor = Int32(arguments[1]), descriptor >= 3 else {
        throw ExternalDisplayInputFailure.identityMismatch
    }
    let channel: GuardChannel
    do { channel = try GuardChannel(descriptor: descriptor) }
    catch {
        Darwin.close(descriptor)
        throw error
    }
    let request = try channel.receive(ExternalDisplayInputProbeRequest.self)
    let reply = executeExternalDisplayInputProbe(request, transport: transport)
    try channel.send(reply, deadlineNanoseconds: request.deadlineNanoseconds)
    return true
}

func executeExternalDisplayInputProbe(
    _ request: ExternalDisplayInputProbeRequest,
    transport: ExternalDisplayInputTransport,
    now: () throws -> UInt64 = { try ContinuousClock.nanoseconds() },
    sleep: (UInt64) -> Void = { Thread.sleep(forTimeInterval: Double($0) / 1_000_000_000) }
) -> ExternalDisplayInputProbeReply {
    do {
        do { try request.target.validate() }
        catch { throw ExternalDisplayInputFailure.identityMismatch }

        func checkDeadline() throws {
            guard try now() < request.deadlineNanoseconds else { throw ExternalDisplayInputFailure.timedOut }
        }

        try checkDeadline()
        switch request.operation {
        case .capabilities:
            let values = try transport.readCapabilities(
                for: request.target,
                deadlineNanoseconds: request.deadlineNanoseconds
            )
            try checkDeadline()
            let capabilities = ExternalDisplayInputCapabilities(target: request.target, inputValues: values)
            try capabilities.validate(for: request.target)
            return .capabilities(capabilities)

        case .selectInput(let input):
            guard input <= UInt16(UInt8.max) else { throw ExternalDisplayInputFailure.invalidInput }
            let values = try transport.readCapabilities(
                for: request.target,
                deadlineNanoseconds: request.deadlineNanoseconds
            )
            try checkDeadline()
            guard values.contains(input) else { throw ExternalDisplayInputFailure.unsupportedInput }
            try transport.writeInput(input, to: request.target, deadlineNanoseconds: request.deadlineNanoseconds)
            try checkDeadline()

            let waitNanoseconds: UInt64 = 50_000_000
            let beforeWait = try now()
            guard beforeWait < request.deadlineNanoseconds,
                  request.deadlineNanoseconds - beforeWait >= waitNanoseconds else {
                throw ExternalDisplayInputFailure.timedOut
            }
            sleep(waitNanoseconds)
            try checkDeadline()

            let actual = try transport.readInput(
                for: request.target,
                deadlineNanoseconds: request.deadlineNanoseconds
            )
            try checkDeadline()
            guard actual == input else { throw ExternalDisplayInputFailure.readbackMismatch }
            return .confirmed(target: request.target, input: actual)
        }
    } catch {
        return .failed(ExternalDisplayInputFailure.from(error))
    }
}

enum ExternalDisplayInputDDC {
    static func getVCP(_ code: UInt8) -> [UInt8] {
        checksumFrame([0x82, 0x01, code])
    }

    static func setInput(_ input: UInt16) -> [UInt8]? {
        guard input <= UInt16(UInt8.max) else { return nil }
        return checksumFrame([0x84, 0x03, 0x60, 0, UInt8(input)])
    }

    static func getCapabilities(offset: UInt16) -> [UInt8] {
        checksumFrame([0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)])
    }

    static func parseVCPReply(_ reply: [UInt8], code: UInt8) throws -> UInt16 {
        guard reply.count >= 11, reply[0] == 0x6E, reply[1] & 0x80 != 0,
              reply[1] & 0x7F == 8 else { throw ExternalDisplayInputFailure.readbackUnavailable }
        let frame = Array(reply.prefix(11))
        guard xor(frame) == 0x50, frame[2] == 0x02, frame[3] == 0,
              frame[4] == code, frame[5] == 0 else {
            throw ExternalDisplayInputFailure.readbackUnavailable
        }
        return (UInt16(frame[8]) << 8) | UInt16(frame[9])
    }

    static func parseCapabilitiesReply(_ reply: [UInt8], offset: UInt16) throws -> [UInt8] {
        guard reply.count >= 6, reply[0] == 0x6E, reply[1] & 0x80 != 0,
              reply[2] == 0xE3 else { throw ExternalDisplayInputFailure.invalidCapabilities }
        let bodyLength = Int(reply[1] & 0x7F)
        let frameLength = bodyLength + 3
        guard (3...35).contains(bodyLength), reply.count >= frameLength else {
            throw ExternalDisplayInputFailure.invalidCapabilities
        }
        let frame = Array(reply.prefix(frameLength))
        guard xor(frame) == 0x50,
              frame[3] == UInt8(offset >> 8), frame[4] == UInt8(offset & 0xFF) else {
            throw ExternalDisplayInputFailure.invalidCapabilities
        }
        return Array(frame[5..<(frameLength - 1)])
    }

    static func parseInputValues(_ capabilities: String) throws -> Set<UInt16> {
        let original = Array(capabilities.utf8)
        guard !original.isEmpty, original.count <= 4_096,
              original.allSatisfy({ $0 == 0x09 || $0 == 0x0A || (0x20...0x7E).contains($0) }) else {
            throw ExternalDisplayInputFailure.invalidCapabilities
        }
        let bytes = Array(capabilities.uppercased().utf8)

        guard let start = vcpStart(in: bytes) else { throw ExternalDisplayInputFailure.unsupportedInput }
        var index = start + 4
        var inputValues: Set<UInt16>?
        var closed = false
        while index < bytes.count {
            skipWhitespace(bytes, index: &index)
            guard index < bytes.count else { break }
            if bytes[index] == 0x29 { closed = true; break }

            let tokenStart = index
            while index < bytes.count, isHex(bytes[index]) { index += 1 }
            guard tokenStart < index, index - tokenStart == 2,
                  let feature = UInt8(String(decoding: bytes[tokenStart..<index], as: UTF8.self), radix: 16) else {
                throw ExternalDisplayInputFailure.invalidCapabilities
            }
            skipWhitespace(bytes, index: &index)
            guard index < bytes.count else { continue }
            guard bytes[index] == 0x28 else { continue }
            index += 1
            if feature == 0x60 {
                guard inputValues == nil else { throw ExternalDisplayInputFailure.invalidCapabilities }
                inputValues = try parseHexByteList(bytes, index: &index)
            } else {
                try skipParenthesized(bytes, index: &index)
            }
        }
        guard closed else { throw ExternalDisplayInputFailure.invalidCapabilities }
        guard let inputValues, !inputValues.isEmpty else { throw ExternalDisplayInputFailure.unsupportedInput }
        return inputValues
    }

    private static func checksumFrame(_ payload: [UInt8]) -> [UInt8] {
        payload + [xor([0x6E, 0x51] + payload)]
    }

    private static func xor(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(UInt8(0)) { $0 ^ $1 }
    }

    private static func vcpStart(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) where Array(bytes[index..<(index + 4)]) == [0x56, 0x43, 0x50, 0x28] {
            if index == 0 || !isASCIIAlphaNumeric(bytes[index - 1]) { return index }
        }
        return nil
    }

    private static func parseHexByteList(_ bytes: [UInt8], index: inout Int) throws -> Set<UInt16> {
        var values: Set<UInt16> = []
        while index < bytes.count {
            skipWhitespace(bytes, index: &index)
            guard index < bytes.count else { break }
            if bytes[index] == 0x29 {
                index += 1
                return values
            }
            let start = index
            while index < bytes.count, isHex(bytes[index]) { index += 1 }
            guard index - start == 2,
                  let value = UInt8(String(decoding: bytes[start..<index], as: UTF8.self), radix: 16) else {
                throw ExternalDisplayInputFailure.invalidCapabilities
            }
            guard values.insert(UInt16(value)).inserted else {
                throw ExternalDisplayInputFailure.invalidCapabilities
            }
            skipWhitespace(bytes, index: &index)
            guard index < bytes.count, bytes[index] == 0x29 || isHex(bytes[index]) else {
                throw ExternalDisplayInputFailure.invalidCapabilities
            }
        }
        throw ExternalDisplayInputFailure.invalidCapabilities
    }

    private static func skipParenthesized(_ bytes: [UInt8], index: inout Int) throws {
        var depth = 1
        while index < bytes.count, depth > 0 {
            if bytes[index] == 0x28 { depth += 1 }
            if bytes[index] == 0x29 { depth -= 1 }
            index += 1
        }
        guard depth == 0 else { throw ExternalDisplayInputFailure.invalidCapabilities }
    }

    private static func skipWhitespace(_ bytes: [UInt8], index: inout Int) {
        while index < bytes.count,
              (bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A) {
            index += 1
        }
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte)
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
    }
}

private struct AppleSiliconExternalDisplayInputTransport: ExternalDisplayInputTransport {
    func readCapabilities(for target: ExternalDisplayIdentity, deadlineNanoseconds: UInt64) throws -> Set<UInt16> {
        try withAVService(for: target) { service, api in
            var capabilities: [UInt8] = []
            var offset: UInt16 = 0
            while capabilities.count < 4_096 {
                try checkDeadline(deadlineNanoseconds)
                try api.write(service, payload: ExternalDisplayInputDDC.getCapabilities(offset: offset))
                try waitForDDC(deadlineNanoseconds)
                var response = [UInt8](repeating: 0, count: 39)
                try api.read(service, into: &response)
                let fragment = try ExternalDisplayInputDDC.parseCapabilitiesReply(response, offset: offset)
                var ended = false
                for byte in fragment {
                    if byte == 0 { ended = true; break }
                    guard (0x20...0x7E).contains(byte) else { throw ExternalDisplayInputFailure.invalidCapabilities }
                    capabilities.append(byte)
                }
                guard capabilities.count <= 4_096 else { throw ExternalDisplayInputFailure.invalidCapabilities }
                if ended || fragment.count < 32 { break }
                guard let nextOffset = UInt16(exactly: capabilities.count) else {
                    throw ExternalDisplayInputFailure.invalidCapabilities
                }
                offset = nextOffset
            }
            guard let text = String(bytes: capabilities, encoding: .ascii) else {
                throw ExternalDisplayInputFailure.invalidCapabilities
            }
            return try ExternalDisplayInputDDC.parseInputValues(text)
        }
    }

    func writeInput(_ input: UInt16, to target: ExternalDisplayIdentity, deadlineNanoseconds: UInt64) throws {
        guard let packet = ExternalDisplayInputDDC.setInput(input) else {
            throw ExternalDisplayInputFailure.invalidInput
        }
        try checkDeadline(deadlineNanoseconds)
        try withAVService(for: target) { service, api in
            try api.write(service, payload: packet)
            try checkDeadline(deadlineNanoseconds)
        }
    }

    func readInput(for target: ExternalDisplayIdentity, deadlineNanoseconds: UInt64) throws -> UInt16 {
        try checkDeadline(deadlineNanoseconds)
        return try withAVService(for: target) { service, api in
            try api.write(service, payload: ExternalDisplayInputDDC.getVCP(0x60))
            try waitForDDC(deadlineNanoseconds)
            var response = [UInt8](repeating: 0, count: 12)
            try api.read(service, into: &response)
            return try ExternalDisplayInputDDC.parseVCPReply(response, code: 0x60)
        }
    }
}

private func withAVService<Value>(
    for target: ExternalDisplayIdentity,
    _ body: (CFTypeRef, IOAVServiceFunctions) throws -> Value
) throws -> Value {
    #if !arch(arm64)
    throw ExternalDisplayInputFailure.unsupportedTransport
    #else
    do { try target.validate() }
    catch { throw ExternalDisplayInputFailure.identityMismatch }
    guard try currentBootSession() == target.bootSession else { throw ExternalDisplayInputFailure.identityMismatch }

    let framebuffer = target.registryPath.withCString {
        IORegistryEntryFromPath(kIOMainPortDefault, $0)
    }
    guard framebuffer != IO_OBJECT_NULL else { throw ExternalDisplayInputFailure.identityMismatch }
    defer { IOObjectRelease(framebuffer) }
    var entryID: UInt64 = 0
    guard IOObjectConformsTo(framebuffer, "IOMobileFramebufferShim") != 0,
          IORegistryEntryGetRegistryEntryID(framebuffer, &entryID) == KERN_SUCCESS,
          entryID == target.registryEntryID,
          registryStringProperty("EDID UUID", of: framebuffer) == target.edidUUID,
          registryPath(of: framebuffer) == target.registryPath else {
        throw ExternalDisplayInputFailure.identityMismatch
    }

    let proxy = try matchingExternalAVProxy(for: target)
    defer { IOObjectRelease(proxy) }
    let api = try IOAVServiceFunctions()
    guard let service = api.createService(for: proxy) else {
        throw ExternalDisplayInputFailure.unsupportedTransport
    }
    defer { service.release() }
    return try body(service.takeUnretainedValue(), api)
    #endif
}

private func matchingExternalAVProxy(for target: ExternalDisplayIdentity) throws -> io_service_t {
    var iterator: io_iterator_t = IO_OBJECT_NULL
    let result = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("DCPAVServiceProxy"),
        &iterator
    )
    guard result == KERN_SUCCESS, iterator != IO_OBJECT_NULL else {
        throw ExternalDisplayInputFailure.unsupportedTransport
    }
    defer { IOObjectRelease(iterator) }

    var matches: [io_service_t] = []
    while true {
        let candidate = IOIteratorNext(iterator)
        if candidate == IO_OBJECT_NULL { break }
        guard registryStringProperty("Location", of: candidate) == "External",
              isDescendant(candidate, ofRegistryEntryID: target.registryEntryID) else {
            IOObjectRelease(candidate)
            continue
        }
        matches.append(candidate)
    }
    guard matches.count == 1, let match = matches.first else {
        matches.forEach { _ = IOObjectRelease($0) }
        throw ExternalDisplayInputFailure.unsupportedTransport
    }
    return match
}

private func isDescendant(_ entry: io_registry_entry_t, ofRegistryEntryID expected: UInt64) -> Bool {
    var current = entry
    var ownsCurrent = false
    defer { if ownsCurrent { IOObjectRelease(current) } }
    for _ in 0..<32 {
        var entryID: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(current, &entryID) == KERN_SUCCESS, entryID == expected {
            return true
        }
        var parent: io_registry_entry_t = IO_OBJECT_NULL
        guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
              parent != IO_OBJECT_NULL else { return false }
        if ownsCurrent { IOObjectRelease(current) }
        current = parent
        ownsCurrent = true
    }
    return false
}

private func registryStringProperty(_ key: String, of service: io_registry_entry_t) -> String? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String
}

private func registryPath(of service: io_registry_entry_t) -> String? {
    var path = [CChar](repeating: 0, count: 512)
    guard path.withUnsafeMutableBufferPointer({
        IORegistryEntryGetPath(service, kIOServicePlane, $0.baseAddress!)
    }) == KERN_SUCCESS else { return nil }
    return path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}

private func checkDeadline(_ deadlineNanoseconds: UInt64) throws {
    guard try ContinuousClock.nanoseconds() < deadlineNanoseconds else {
        throw ExternalDisplayInputFailure.timedOut
    }
}

private func waitForDDC(_ deadlineNanoseconds: UInt64) throws {
    let interval: UInt64 = 50_000_000
    let now = try ContinuousClock.nanoseconds()
    guard deadlineNanoseconds > now, deadlineNanoseconds - now >= interval else {
        throw ExternalDisplayInputFailure.timedOut
    }
    Thread.sleep(forTimeInterval: 0.05)
    try checkDeadline(deadlineNanoseconds)
}

private struct IOAVServiceFunctions {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Read = @convention(c) (UnsafeRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    private typealias Write = @convention(c) (UnsafeRawPointer, UInt32, UInt32, UnsafeRawPointer, UInt32) -> Int32

    private let readFunction: Read
    private let writeFunction: Write
    private let create: Create

    init() throws {
        #if !arch(arm64)
        throw ExternalDisplayInputFailure.unsupportedTransport
        #else
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL),
              let createSymbol = dlsym(handle, "IOAVServiceCreateWithService"),
              let readSymbol = dlsym(handle, "IOAVServiceReadI2C"),
              let writeSymbol = dlsym(handle, "IOAVServiceWriteI2C") else {
            throw ExternalDisplayInputFailure.unsupportedTransport
        }
        create = unsafeBitCast(createSymbol, to: Create.self)
        readFunction = unsafeBitCast(readSymbol, to: Read.self)
        writeFunction = unsafeBitCast(writeSymbol, to: Write.self)
        #endif
    }

    func createService(for proxy: io_service_t) -> Unmanaged<CFTypeRef>? {
        create(kCFAllocatorDefault, proxy)
    }

    func write(_ service: CFTypeRef, payload: [UInt8]) throws {
        let pointer = Unmanaged.passUnretained(service).toOpaque()
        let result = payload.withUnsafeBufferPointer {
            writeFunction(UnsafeRawPointer(pointer), 0x37, 0x51, $0.baseAddress!, UInt32($0.count))
        }
        guard result == 0 else { throw ExternalDisplayInputFailure.unsupportedTransport }
    }

    func read(_ service: CFTypeRef, into bytes: inout [UInt8]) throws {
        let pointer = Unmanaged.passUnretained(service).toOpaque()
        let result = bytes.withUnsafeMutableBytes { buffer in
            readFunction(UnsafeRawPointer(pointer), 0x37, 0x51, buffer.baseAddress!, UInt32(buffer.count))
        }
        guard result == 0 else { throw ExternalDisplayInputFailure.readbackUnavailable }
    }
}
