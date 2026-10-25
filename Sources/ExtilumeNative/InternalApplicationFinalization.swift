import Foundation

struct InternalApplicationFinalization: Sendable {
    private(set) var request: UUID?
    private(set) var faulted = false
    private(set) var stoppedNormally = false

    init(request: UUID? = nil) { self.request = request }

    mutating func beginQuit() -> UUID {
        let request = UUID()
        self.request = request
        return request
    }
    mutating func cancelQuit() { request = nil }
    mutating func noteFault() { faulted = true }
    mutating func noteStopped(faulted: Bool) {
        if faulted { noteFault() }
        else if !self.faulted { stoppedNormally = true }
    }
    func permitsClear(request: UUID?, recoveryOnly: Bool, workerSucceeded: Bool, transportFailed: Bool) -> Bool {
        request != nil && request == self.request && !faulted && workerSucceeded && !transportFailed
            && (recoveryOnly || stoppedNormally)
    }
}
