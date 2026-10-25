import Dispatch
import IOKit
import IOKit.pwr_mgt
import ExtilumeCore

// IOMessage.h exposes these as C macros; sys_iokit is err_system(0x38) and the common subcode is 0.
enum InternalSystemPowerMessage {
    private static let sysIOKit: UInt32 = UInt32(0x38) << 26

    static let canSystemSleep = sysIOKit | 0x270
    static let systemWillNotSleep = sysIOKit | 0x290
    static let systemWillSleep = sysIOKit | 0x280
    static let systemWillPowerOn = sysIOKit | 0x320
    static let systemHasPoweredOn = sysIOKit | 0x300
}

private final class InternalSystemPowerCallbackContext {
    weak var observer: InternalSystemPowerObserver?
    var rootPort: io_connect_t = IO_OBJECT_NULL

    init(observer: InternalSystemPowerObserver) {
        self.observer = observer
    }
}

final class InternalSystemPowerObserver: @unchecked Sendable {
    private enum ObserverError: Error {
        case registrationFailed
        case alreadyStarted
        case stopped
    }

    private let queue = DispatchQueue(label: "Extilume.system-power-observer")
    private let traceQueue = DispatchQueue(label: "Extilume.system-power-trace")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let prepareForSleep: @Sendable () -> Bool
    private let didPrepareForSleep: @Sendable (Bool, Bool) -> Void
    private let didWake: @Sendable () -> Void
    private let onFailure: @Sendable () -> Void

    private var rootPort: io_connect_t = IO_OBJECT_NULL
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = IO_OBJECT_NULL
    private var callbackContext: InternalSystemPowerCallbackContext?
    private var started = false
    private var stopped = false
    private var active = false

    init(
        prepareForSleep: @escaping @Sendable () -> Bool,
        didPrepareForSleep: @escaping @Sendable (Bool, Bool) -> Void,
        didWake: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable () -> Void
    ) {
        self.prepareForSleep = prepareForSleep
        self.didPrepareForSleep = didPrepareForSleep
        self.didWake = didWake
        self.onFailure = onFailure
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        stop()
    }

    func start() throws {
        try onQueue {
            guard !stopped else { throw ObserverError.stopped }
            guard !started else { throw ObserverError.alreadyStarted }

            let context = InternalSystemPowerCallbackContext(observer: self)
            var port: IONotificationPortRef?
            var notifier: io_object_t = IO_OBJECT_NULL
            let rootPort = IORegisterForSystemPower(
                Unmanaged.passUnretained(context).toOpaque(), &port, internalSystemPowerCallback, &notifier
            )

            guard rootPort != IO_OBJECT_NULL, notifier != IO_OBJECT_NULL, let port else {
                Self.releaseRegistration(rootPort: rootPort, notificationPort: port, notifier: notifier)
                throw ObserverError.registrationFailed
            }

            context.rootPort = rootPort
            self.rootPort = rootPort
            self.notificationPort = port
            self.notifier = notifier
            callbackContext = context
            IONotificationPortSetDispatchQueue(port, queue)
            started = true
            active = true
        }
    }

    func stop() {
        onQueue { stopOnQueue() }
    }

    static func dispatchMessage(
        _ messageType: UInt32,
        notificationID: Int,
        active: Bool,
        prepareForSleep: () -> Bool,
        acknowledge: (Int) -> Bool,
        didPrepareForSleep: (Bool, Bool) -> Void,
        didWake: () -> Void,
        trace: (InternalLifecycleStage, Bool?) -> Void = { _, _ in },
        onFailure: () -> Void
    ) {
        func acknowledgeSleep() -> Bool {
            trace(.powerAcknowledgementStarted, nil)
            let acknowledged = acknowledge(notificationID)
            trace(.powerAcknowledgementFinished, acknowledged)
            return acknowledged
        }
        switch messageType {
        case InternalSystemPowerMessage.canSystemSleep:
            if !acknowledge(notificationID) { onFailure() }
        case InternalSystemPowerMessage.systemWillSleep:
            guard active else {
                if !acknowledgeSleep() { onFailure() }
                return
            }
            // 此闭包只设置门禁和排队；不得等待显示读取或原生提交。
            let accepted = prepareForSleep()
            let acknowledged = acknowledgeSleep()
            didPrepareForSleep(accepted, acknowledged)
            if !acknowledged { onFailure() }
        case InternalSystemPowerMessage.systemHasPoweredOn:
            if active { didWake() }
        default:
            break
        }
    }

    fileprivate func receive(_ messageType: UInt32, notificationID: Int) {
        Self.dispatchMessage(
            messageType,
            notificationID: notificationID,
            active: active,
            prepareForSleep: prepareForSleep,
            acknowledge: { [rootPort] id in
                rootPort != IO_OBJECT_NULL && IOAllowPowerChange(rootPort, id) == kIOReturnSuccess
            },
            didPrepareForSleep: didPrepareForSleep,
            didWake: didWake,
            trace: { [traceQueue] stage, succeeded in
                let timestamp = try? ContinuousClock.nanoseconds()
                traceQueue.async { traceInternalLifecycle(stage, succeeded: succeeded, observedAt: timestamp) }
            },
            onFailure: onFailure
        )
    }

    private func stopOnQueue() {
        guard !stopped else { return }
        active = false
        stopped = true

        var failed = false
        if notifier != IO_OBJECT_NULL {
            if IODeregisterForSystemPower(&notifier) != kIOReturnSuccess { failed = true }
            notifier = IO_OBJECT_NULL
        }
        if rootPort != IO_OBJECT_NULL {
            if IOServiceClose(rootPort) != KERN_SUCCESS { failed = true }
            rootPort = IO_OBJECT_NULL
        }
        if let notificationPort {
            self.notificationPort = nil
            IONotificationPortDestroy(notificationPort)
        }
        callbackContext = nil

        if failed { onFailure() }
    }

    private func onQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try work() }
        return try queue.sync(execute: work)
    }

    private static func releaseRegistration(
        rootPort: io_connect_t,
        notificationPort: IONotificationPortRef?,
        notifier: io_object_t
    ) {
        var notifier = notifier
        if notifier != IO_OBJECT_NULL { _ = IODeregisterForSystemPower(&notifier) }
        if rootPort != IO_OBJECT_NULL { _ = IOServiceClose(rootPort) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }
}

private func internalSystemPowerCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ service: io_service_t,
    _ messageType: UInt32,
    _ messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let context = Unmanaged<InternalSystemPowerCallbackContext>.fromOpaque(refcon).takeUnretainedValue()
    let notificationID = messageArgument.map { Int(bitPattern: $0) } ?? 0
    if let observer = context.observer {
        observer.receive(messageType, notificationID: notificationID)
    } else if messageType == InternalSystemPowerMessage.canSystemSleep ||
        messageType == InternalSystemPowerMessage.systemWillSleep {
        if context.rootPort != IO_OBJECT_NULL { _ = IOAllowPowerChange(context.rootPort, notificationID) }
    }
}
