import Darwin
import ExtilumeCore
import Foundation

// Only the isolated batch launcher supplies this environment; normal sessions have no batch quota.
final class InternalDisableBatchBudget {
    static let environmentKey = "EXTILUME_RECOVERY_BATCH_DIRECTORY"
    struct Policy: Codable {
        let bootSession: UUID
        let started: UInt64
        let deadline: UInt64
    }
    enum Failure: Error { case rejected }
    struct RestorationReceipt: Codable {
        let version: Int
        let app: ApplicationAutomationTarget
        let verifiedAtNanoseconds: UInt64
        let expectation: InternalApplicationExpectation
        let record: RecoveryRecord
    }
    private let directory: LayoutCloseoutDirectory
    private let policyBytes: Data
    private let policy: Policy
    private let now: () throws -> UInt64
    private var firstAttempt: UInt64?
    private var lastTime: UInt64
    private var stopped = false

    static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> InternalDisableBatchBudget? {
        guard let path = environment[environmentKey] else { return nil }
        return try Self(path: path)
    }

    init(path: String, now: @escaping () throws -> UInt64 = ContinuousClock.nanoseconds,
         boot: () throws -> UUID = currentBootSession) throws {
        directory = try LayoutCloseoutDirectory(path)
        policyBytes = try directory.read("policy.json")
        policy = try JSONDecoder().decode(Policy.self, from: policyBytes)
        guard policy.bootSession == (try boot()), policy.deadline > policy.started,
              policy.deadline - policy.started <= 180_000_000_000 else { throw Failure.rejected }
        self.now = now
        lastTime = policy.started
    }

    func registerProcess(role: String, pid: Int32,
                         read: (Int32) throws -> ApplicationAutomationTarget = ApplicationAutomationTarget.read) throws {
        guard ["app", "owner", "helper"].contains(role) else { throw Failure.rejected }
        try directory.requireAbsent("stopped")
        let identity = try read(pid)
        let staged = "." + role + "-process.pending"
        try directory.write(staged, value: identity)
        guard try read(pid) == identity else { throw Failure.rejected }
        try directory.verify()
        // Publish complete bytes without replacing another registration; retain the consumed staging file.
        guard linkat(directory.descriptor, staged, directory.descriptor, role + "-process.json", 0) == 0 else {
            throw Failure.rejected
        }
        while fsync(directory.descriptor) != 0 {
            guard errno == EINTR else { throw Failure.rejected }
        }
        try directory.verify()
    }

    // Called only after the App's independent verifier, worker/helper exit, channel drain and record clear.
    func recordRestoration(_ record: RecoveryRecord, expectation: InternalApplicationExpectation) throws {
        try expectation.validate()
        guard expectation.matchesRestoredRecord(record), record.independentGuardVerified == true,
              try directory.read("policy.json") == policyBytes else { throw Failure.rejected }
        let app = try ApplicationAutomationTarget.read(pid: getpid())
        guard try JSONDecoder().decode(ApplicationAutomationTarget.self,
                                        from: directory.read("app-process.json")) == app else { throw Failure.rejected }
        let receipt = RestorationReceipt(version: 1, app: app, verifiedAtNanoseconds: try now(),
                                         expectation: expectation, record: record)
        guard receipt.verifiedAtNanoseconds >= policy.started else { throw Failure.rejected }
        try directory.write(".restoration.pending", value: receipt)
        try directory.verify()
        guard linkat(directory.descriptor, ".restoration.pending", directory.descriptor, "restoration.json", 0) == 0 else {
            throw Failure.rejected
        }
        while fsync(directory.descriptor) != 0 {
            guard errno == EINTR else { throw Failure.rejected }
        }
        try directory.verify()
    }

    // O_EXCL plus fsync consumes before any display write; a failed attempt never gets its slot back.
    func consume(wakeAt: UInt64?) throws {
        do {
            guard !stopped, try directory.read("policy.json") == policyBytes else { throw Failure.rejected }
            try directory.requireAbsent("stopped")
            let at = try now()
            guard at >= lastTime, at < policy.deadline else { throw Failure.rejected }
            lastTime = at
            let name: String
            if let firstAttempt {
                guard let wakeAt, wakeAt > firstAttempt, wakeAt <= at,
                      at - wakeAt < 10_000_000_000 else { throw Failure.rejected }
                name = "wake-consumed.json"
            } else {
                guard wakeAt == nil else { throw Failure.rejected }
                name = "initial-consumed.json"
            }
            let permitName = firstAttempt == nil ? "initial-authorized.json" : "wake-authorized.json"
            let authorizedAt = try JSONDecoder().decode(UInt64.self, from: directory.read(permitName))
            guard authorizedAt >= policy.started, authorizedAt <= at,
                  wakeAt.map({ $0 >= authorizedAt }) ?? true else { throw Failure.rejected }
            try directory.write(name, value: at)
            // A slow durable write cannot extend the original window.
            let after = try now()
            guard after >= at, after < policy.deadline,
                  wakeAt.map({ after - $0 < 10_000_000_000 }) ?? true else { throw Failure.rejected }
            try directory.requireAbsent("stopped")
            guard try directory.read("policy.json") == policyBytes else { throw Failure.rejected }
            lastTime = after
            if firstAttempt == nil { firstAttempt = at }
        } catch {
            stopped = true
            try? directory.write("stopped", data: Data())
            throw error
        }
    }
}
