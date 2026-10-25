import CoreFoundation
import ExtilumeCore
import Foundation

enum RecoverySessionSignal: String, CaseIterable, Encodable, Sendable {
    case screenLockedNotificationReceived, screenUnlockedNotificationReceived

    var name: Notification.Name {
        Notification.Name(self == .screenLockedNotificationReceived
            ? "com.apple.screenIsLocked" : "com.apple.screenIsUnlocked")
    }
}

func recoverySessionNotificationMarker(_ signal: RecoverySessionSignal, receivedAt: UInt64) throws -> String {
    struct Marker: Encodable {
        let type = "session-notification-observation"
        let source = "unverified-distributed-notification"
        let clock = "mach_continuous_time/ns"
        let signal: RecoverySessionSignal
        let receivedAtNanoseconds: UInt64
    }
    return String(decoding: try JSONEncoder().encode(Marker(signal: signal, receivedAtNanoseconds: receivedAt)),
                  as: UTF8.self)
}

final class RecoverySessionNotifications: NSObject {
    private let center: NotificationCenter
    private let observe: @Sendable (RecoverySessionSignal) -> Void

    // These names have no public contract; observations never authorize a display operation.
    init(center: NotificationCenter = DistributedNotificationCenter.default(),
         observe: @escaping @Sendable (RecoverySessionSignal) -> Void = { signal in
             do { print(try recoverySessionNotificationMarker(signal, receivedAt: ContinuousClock.nanoseconds())) }
             catch { print("会话通知接收计时不可用；不能推断解锁时刻。") }
         }) {
        self.center = center
        self.observe = observe
        super.init()
        for signal in RecoverySessionSignal.allCases {
            center.addObserver(self, selector: #selector(receive(_:)), name: signal.name, object: nil)
        }
    }

    @objc private func receive(_ notification: Notification) {
        guard let signal = RecoverySessionSignal.allCases.first(where: { $0.name == notification.name }) else { return }
        observe(signal)
    }

    func stop() {
        center.removeObserver(self)
    }

    deinit { stop() }
}

enum RecoveryRecorderLoopError: Error { case mainThreadRequired, sourceUnavailable }

func waitForRecoveryRecorderStop(readCommand: @escaping @Sendable () -> String? = { readLine() }) throws {
    guard Thread.isMainThread else { throw RecoveryRecorderLoopError.mainThreadRequired }
    let loop = CFRunLoopGetMain()
    var context = CFRunLoopSourceContext(version: 0, info: nil, retain: nil, release: nil,
        copyDescription: nil, equal: nil, hash: nil, schedule: nil, cancel: nil, perform: { _ in })
    guard let source = CFRunLoopSourceCreate(nil, 0, &context) else { throw RecoveryRecorderLoopError.sourceUnavailable }
    CFRunLoopAddSource(loop, source, .defaultMode)
    defer { CFRunLoopRemoveSource(loop, source, .defaultMode) }
    DispatchQueue.global().async {
        while let line = readCommand() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "stop" { break }
        }
        // Queue the stop so EOF arriving before Run() cannot be lost.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    CFRunLoopRun()
}
