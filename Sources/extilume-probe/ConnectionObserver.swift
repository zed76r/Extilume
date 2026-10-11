import CoreGraphics
import Darwin
import ExtilumeCore
import Foundation
import IOKit

private enum ConnectionObserverError: Error {
    case invalidTarget
    case setupFailed
    case alreadyStarted
}

private enum MatchingKind: Equatable {
    case matched
    case terminated
}

// Swift 不导入复合宏；按 IOMessage.h/IOReturn.h 的 sys_iokit | sub_iokit_common | message 构造。
private let servicePropertyChange: UInt32 = (0x38 << 26) | 0x130
private let serviceTerminated: UInt32 = (0x38 << 26) | 0x010

final class ConnectionObserver: @unchecked Sendable {
    private let service: io_service_t
    private let targetEntryID: UInt64
    private let targetEDIDUUID: UUID
    private let queue = DispatchQueue(label: "Extilume.connection-observer")
    private let queueKey = DispatchSpecificKey<Bool>()

    private var startedAt: UInt64?
    private var notificationPort: IONotificationPortRef?
    private var callbackContext: UnsafeMutableRawPointer?
    private var interestNotification: io_object_t = IO_OBJECT_NULL
    private var matchedIterator: io_iterator_t = IO_OBJECT_NULL
    private var terminatedIterator: io_iterator_t = IO_OBJECT_NULL
    private var cgRegistered = false
    private var started = false
    private var resourcesReleased = false

    init(service: io_service_t) throws {
        var ownsService = true
        defer { if ownsService { _ = IOObjectRelease(service) } }

        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
              entryID != 0,
              let rawUUID = property("EDID UUID", from: service) as? String,
              let edidUUID = UUID(uuidString: rawUUID) else {
            throw ConnectionObserverError.invalidTarget
        }

        self.service = service
        targetEntryID = entryID
        targetEDIDUUID = edidUUID
        ownsService = false
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            releaseResourcesOnQueue()
        } else {
            queue.sync { releaseResourcesOnQueue() }
        }
    }

    func start() throws {
        try queue.sync {
            guard !resourcesReleased, !started else {
                throw ConnectionObserverError.alreadyStarted
            }

            do {
                startedAt = try ContinuousClock.nanoseconds()
                guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
                    throw ConnectionObserverError.setupFailed
                }
                notificationPort = port
                IONotificationPortSetDispatchQueue(port, queue)

                let context = Unmanaged.passRetained(self).toOpaque()
                callbackContext = context
                var interest: io_object_t = IO_OBJECT_NULL
                guard IOServiceAddInterestNotification(
                    port,
                    service,
                    kIOGeneralInterest,
                    connectionInterestCallback,
                    context,
                    &interest
                ) == KERN_SUCCESS else {
                    throw ConnectionObserverError.setupFailed
                }
                interestNotification = interest

                guard CGDisplayRegisterReconfigurationCallback(
                    connectionDisplayCallback,
                    context
                ) == .success else {
                    throw ConnectionObserverError.setupFailed
                }
                cgRegistered = true

                try registerMatchingNotification(.matched)
                try registerMatchingNotification(.terminated)
                started = true
            } catch {
                releaseResourcesOnQueue()
                throw ConnectionObserverError.setupFailed
            }
        }
    }

    func command(_ text: String) {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mark":
            queue.async { [weak self] in
                guard let self, !self.resourcesReleased else { return }
                self.log("mark（人工标记，不代表实际拔线）")
            }
        case "stop":
            queue.async { [self] in
                releaseResourcesOnQueue()
                exit(EXIT_SUCCESS)
            }
        default:
            break
        }
    }

    private func registerMatchingNotification(_ kind: MatchingKind) throws {
        guard let notificationPort,
              let callbackContext,
              let matching = IOServiceMatching("IOMobileFramebufferShim") else {
            throw ConnectionObserverError.setupFailed
        }

        let notificationType: String
        let callback: IOServiceMatchingCallback
        switch kind {
        case .matched:
            notificationType = kIOMatchedNotification
            callback = connectionMatchedCallback
        case .terminated:
            notificationType = kIOTerminatedNotification
            callback = connectionTerminatedCallback
        }

        var iterator: io_iterator_t = IO_OBJECT_NULL
        let result = IOServiceAddMatchingNotification(
            notificationPort,
            notificationType,
            matching,
            callback,
            callbackContext,
            &iterator
        )
        guard result == KERN_SUCCESS else {
            if iterator != IO_OBJECT_NULL { _ = IOObjectRelease(iterator) }
            throw ConnectionObserverError.setupFailed
        }

        switch kind {
        case .matched: matchedIterator = iterator
        case .terminated: terminatedIterator = iterator
        }
        drain(iterator, kind: kind)
    }

    fileprivate func drain(_ iterator: io_iterator_t, kind: MatchingKind) {
        while true {
            let candidate = IOIteratorNext(iterator)
            if candidate == IO_OBJECT_NULL { return }
            defer { _ = IOObjectRelease(candidate) }
            guard isTarget(candidate) else { continue }
            log(kind == .matched ? "matched" : "termination")
        }
    }

    private func isTarget(_ candidate: io_service_t) -> Bool {
        var entryID: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(candidate, &entryID) == KERN_SUCCESS,
           entryID == targetEntryID {
            return true
        }

        guard let rawUUID = property("EDID UUID", from: candidate) as? String,
              UUID(uuidString: rawUUID) == targetEDIDUUID,
              let transport = property("Transport", from: candidate) as? [String: Any] else {
            return false
        }
        return transport["Downstream"] as? String == "HDMI"
    }

    fileprivate func handleInterest(_ messageType: UInt32) {
        guard !resourcesReleased else { return }
        switch messageType {
        case servicePropertyChange:
            log("property-change")
        case serviceTerminated:
            log("termination")
        default:
            log("interest")
        }
    }

    fileprivate func enqueueDisplayChange(_ flags: CGDisplayChangeSummaryFlags) {
        queue.async { [weak self] in
            guard let self, !self.resourcesReleased else { return }
            let activeCount = (try? readSnapshot().displays.filter(\.isActive).count)
                .map(String.init) ?? "不可读"
            self.log("display-change flags=\(flags.rawValue) 活动数=\(activeCount)（仅作观测，不证明可用）")
        }
    }

    private func log(_ event: String) {
        guard let startedAt,
              let now = try? ContinuousClock.nanoseconds(),
              now >= startedAt else { return }
        print("[\((now - startedAt) / 1_000_000)ms] \(event)")
    }

    private func releaseResourcesOnQueue() {
        guard !resourcesReleased else { return }
        resourcesReleased = true

        if cgRegistered {
            CGDisplayRemoveReconfigurationCallback(
                connectionDisplayCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
            cgRegistered = false
        }

        if interestNotification != IO_OBJECT_NULL {
            _ = IOObjectRelease(interestNotification)
            interestNotification = IO_OBJECT_NULL
        }
        if matchedIterator != IO_OBJECT_NULL {
            _ = IOObjectRelease(matchedIterator)
            matchedIterator = IO_OBJECT_NULL
        }
        if terminatedIterator != IO_OBJECT_NULL {
            _ = IOObjectRelease(terminatedIterator)
            terminatedIterator = IO_OBJECT_NULL
        }
        if let notificationPort {
            self.notificationPort = nil
            IONotificationPortDestroy(notificationPort)
        }
        _ = IOObjectRelease(service)

        if let callbackContext {
            self.callbackContext = nil
            Unmanaged<ConnectionObserver>.fromOpaque(callbackContext).release()
        }
    }
}

private func property(_ name: String, from entry: io_registry_entry_t) -> Any? {
    IORegistryEntryCreateCFProperty(
        entry,
        name as CFString,
        kCFAllocatorDefault,
        0
    )?.takeRetainedValue()
}

private func connectionInterestCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ service: io_service_t,
    _ messageType: UInt32,
    _ messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let observer = Unmanaged<ConnectionObserver>.fromOpaque(refcon).takeUnretainedValue()
    observer.handleInterest(messageType)
}

private func connectionMatchedCallback(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let refcon else { return }
    let observer = Unmanaged<ConnectionObserver>.fromOpaque(refcon).takeUnretainedValue()
    observer.drain(iterator, kind: .matched)
}

private func connectionTerminatedCallback(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let refcon else { return }
    let observer = Unmanaged<ConnectionObserver>.fromOpaque(refcon).takeUnretainedValue()
    observer.drain(iterator, kind: .terminated)
}

private func connectionDisplayCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let observer = Unmanaged<ConnectionObserver>.fromOpaque(context).takeUnretainedValue()
    observer.enqueueDisplayChange(flags)
}
