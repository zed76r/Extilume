import CoreGraphics
import Darwin
import ExtilumeCore
import Foundation
import IOKit

private enum ConnectionObserverError: Error {
    case invalidTarget
    case setupFailed
    case alreadyStarted
    case invalidReconfiguration
}

private enum MatchingKind: Equatable {
    case matched
    case terminated
}

// Swift 不导入复合宏；按 IOMessage.h/IOReturn.h 的 sys_iokit | sub_iokit_common | message 构造。
private let servicePropertyChange: UInt32 = (0x38 << 26) | 0x130
private let serviceTerminated: UInt32 = (0x38 << 26) | 0x010

func connectionChangeInvalidationReason(
    display: UInt32,
    flags: CGDisplayChangeSummaryFlags,
    expectedDisabledInternal: UInt32?
) -> String? {
    let expected = display != 0 && display == expectedDisabledInternal
    if flags.contains(.removeFlag) {
        let allowed: CGDisplayChangeSummaryFlags = [.removeFlag, .disabledFlag, .desktopShapeChangedFlag]
        if expected && flags.contains(.disabledFlag) && flags.subtracting(allowed).isEmpty { return nil }
        return "cg-remove"
    }
    guard flags.contains(.disabledFlag) else { return nil }
    return expected && flags == .disabledFlag ? nil : "cg-disabled"
}

func connectionDisplayScope(display: UInt32, expectedDisabledInternal: UInt32?) -> ConnectionDisplayScope {
    guard display != 0 else { return .unknown }
    guard let expectedDisabledInternal, expectedDisabledInternal != 0,
          display == expectedDisabledInternal else { return .other }
    return .expectedInternal
}

final class ConnectionObserver: @unchecked Sendable {
    private let service: io_service_t
    private let targetEntryID: UInt64
    private let targetEDIDUUID: UUID
    private let onInvalidation: @Sendable (String, UInt64?) -> Void
    private let onReconfiguration: @Sendable () -> Void
    private let reportsEvents: Bool
    private let expectedDisabledInternal: UInt32?
    private let expectedInternalRegistryID: UInt64?
    private let diagnosticRole: InternalLifecycleRole
    private let queue = DispatchQueue(label: "Extilume.connection-observer")
    private let queueKey = DispatchSpecificKey<Bool>()

    private var startedAt: UInt64?
    private var notificationPort: IONotificationPortRef?
    private var callbackContext: UnsafeMutableRawPointer?
    private var interestNotification: io_object_t = IO_OBJECT_NULL
    private var matchingIterators: [io_iterator_t: String] = [:]
    private var candidates = ConnectionCandidateState()
    private var candidateServices: [UInt64: (service: io_service_t, interest: io_object_t)] = [:]
    private var candidateOrdinals: [UInt64: UInt64] = [:]
    private var candidateSetupFailed = false
    private var cgRegistered = false
    private var started = false
    private var resourcesReleased = false
    private let reconfiguration: InternalLinkReconfigurationGate

    private var filtersEmbeddedTerminations: Bool {
        (expectedDisabledInternal ?? 0) != 0 && (expectedInternalRegistryID ?? 0) != 0
            && expectedInternalRegistryID != targetEntryID
    }

    init(service: io_service_t, reportsEvents: Bool = true,
         expectedDisabledInternal: UInt32? = nil,
         expectedInternalRegistryID: UInt64? = nil,
         diagnosticRole: InternalLifecycleRole = .observer,
         onReconfiguration: @escaping @Sendable () -> Void = {},
         onInvalidation: @escaping @Sendable (String, UInt64?) -> Void = { _, _ in }) throws {
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
        self.reportsEvents = reportsEvents
        self.expectedDisabledInternal = expectedDisabledInternal
        self.expectedInternalRegistryID = expectedInternalRegistryID
        self.diagnosticRole = diagnosticRole
        self.onInvalidation = onInvalidation
        self.onReconfiguration = onReconfiguration
        self.reconfiguration = InternalLinkReconfigurationGate { first in
            onInvalidation("controlled-link-budget-expired", first)
        }
        ownsService = false
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        stopObserving()
    }

    func performInternalDisableCommit(
        validateBeforeCommit: () throws -> Void,
        _ call: () -> CGError
    ) throws -> CGError {
        do {
            try queue.sync {
                guard started, !resourcesReleased, filtersEmbeddedTerminations,
                      let fixed = candidates.reconfigurationCandidates(
                        registered: Set(candidateServices.keys), internalDisplayID: expectedDisabledInternal
                      ), reconfiguration.prepare(candidates: fixed) else {
                    throw ConnectionObserverError.invalidReconfiguration
                }
            }
            try validateBeforeCommit()
            let completion = try reconfiguration.performNative(call)
            // 只在已关闭原生窗口后输出，实际边界使用调用内时间戳。
            traceInternalLifecycle(.linkReconfigurationStarted, role: diagnosticRole, observedAt: completion.startedAt)
            traceInternalLifecycle(.linkReconfigurationCollected, role: diagnosticRole, observedAt: completion.returnedAt)
            guard queue.sync(execute: {
                !resourcesReleased && candidates.reconfigurationCandidates(
                    registered: Set(candidateServices.keys), internalDisplayID: expectedDisabledInternal
                ) != nil && reconfiguration.phase == .verifying
            }) else { throw ConnectionObserverError.invalidReconfiguration }
            return completion.result
        } catch {
            abortInternalReconfiguration()
            throw error
        }
    }

    // 调用方须先完成独立效果读回及责任／保护／电源复核。
    func verifyInternalReconfiguration() throws {
        let verified = queue.sync {
            guard !resourcesReleased,
                  candidates.reconfigurationCandidates(registered: Set(candidateServices.keys),
                                                      internalDisplayID: expectedDisabledInternal) != nil,
                  let now = try? ContinuousClock.nanoseconds() else { return false }
            return reconfiguration.verify(at: now)
        }
        guard verified else {
            abortInternalReconfiguration()
            throw ConnectionObserverError.invalidReconfiguration
        }
        traceInternalLifecycle(.linkReconfigurationVerified, role: diagnosticRole)
    }

    func abortInternalReconfiguration() {
        let pending = reconfiguration.fail()
        if let pending {
            onInvalidation("controlled-link-reconfiguration-failed", pending)
            traceInternalLifecycle(.linkReconfigurationFailed, role: diagnosticRole, observedAt: pending)
        }
    }

    private func signalInvalidation(_ reason: String, observedAt: UInt64?) {
        onInvalidation(reason, reconfiguration.invalidate(observedAt: observedAt))
    }

    func stopObserving() {
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
                for candidate in ExternalConnectionService.allCases {
                    try registerMatchingNotification(.matched, className: candidate.rawValue)
                    try registerMatchingNotification(.terminated, className: candidate.rawValue)
                }
                guard !candidateSetupFailed, candidates.hasCandidates else {
                    throw ConnectionObserverError.setupFailed
                }
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

    private func registerMatchingNotification(_ kind: MatchingKind, className: String = "IOMobileFramebufferShim") throws {
        guard let notificationPort,
              let callbackContext,
              let matching = IOServiceMatching(className) else {
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

        matchingIterators[iterator] = className
        drain(iterator, kind: kind, initial: true)
    }

    fileprivate func drain(_ iterator: io_iterator_t, kind: MatchingKind, initial: Bool = false) {
        guard !resourcesReleased else { return }
        while true {
            let candidate = IOIteratorNext(iterator)
            if candidate == IO_OBJECT_NULL { return }
            defer { _ = IOObjectRelease(candidate) }
            let observedAt = try? ContinuousClock.nanoseconds()
            var entryID: UInt64 = 0
            let identified = IORegistryEntryGetRegistryEntryID(candidate, &entryID) == KERN_SUCCESS
            var terminationLocation: ConnectionObservedLocation?
            if kind == .terminated, identified, entryID != targetEntryID, filtersEmbeddedTerminations,
               candidates.isKnownEmbedded(entryID: entryID),
               let sourceClass = matchingIterators[iterator].flatMap(ExternalConnectionService.init(rawValue:)) {
                let location = property("Location", from: candidate) as? String
                terminationLocation = ConnectionObservedLocation(location)
                let registered = candidates.diagnosticCandidate(entryID: entryID)
                if candidates.consumeEmbeddedTermination(entryID: entryID, service: sourceClass, location: location) {
                    observe(.terminated, entryID: entryID, candidate: registered,
                            observedAt: observedAt, location: terminationLocation,
                            disposition: .controlledEmbeddedTermination)
                    continue
                }
            }
            if kind == .terminated,
               invalidateCandidate(identified ? entryID : 0, terminated: true,
                   event: "\(initial ? "initial-not-physical termination" : "termination") sourceClass=\(matchingIterators[iterator] ?? "unclassified")",
                   observedAt: observedAt, eventKind: .terminated, location: terminationLocation) {
                releaseCandidate(entryID)
                continue
            }
            if identified {
                if kind == .matched,
                   let candidateClass = ExternalConnectionService.allCases.first(where: {
                       IOObjectConformsTo(candidate, $0.rawValue) != 0
                   }) {
                    let location = property("Location", from: candidate) as? String
                    let wasInvalidated = candidates.invalidated
                    let accepted = candidates.matched(entryID: entryID, service: candidateClass, location: location)
                    if !wasInvalidated && candidates.invalidated {
                        signalInvalidation("io-role-conflict class=\(candidateClass.rawValue)", observedAt: observedAt)
                    }
                    if accepted, location == "External", [.prepared, .collecting, .verifying].contains(reconfiguration.phase) {
                        signalInvalidation("io-candidate-changed", observedAt: observedAt)
                    }
                    if accepted, candidateOrdinals[entryID] == nil {
                        candidateOrdinals[entryID] = UInt64(candidateOrdinals.count) + 1
                    }
                    if accepted {
                        if location == "External" { watchCandidate(candidate, entryID: entryID) }
                        log("candidate \(initial ? "initial-not-physical" : "matched") class=\(candidateClass.rawValue) location=\(location == "Embedded" ? "Embedded" : "External") invalidated=\(candidates.invalidated)（不证明目标身份或可用）", observedAt: observedAt)
                    }
                    observe(.matched, entryID: entryID, observedAt: observedAt,
                            location: ConnectionObservedLocation(location), initial: initial,
                            disposition: !wasInvalidated && candidates.invalidated ? .revoked : (accepted ? .registered : .unchanged))
                    continue
                }
            }
            guard isTarget(candidate) else { continue }
            let event = kind == .matched ? "matched" : "termination"
            log(initial ? "initial-not-physical \(event)" : event, observedAt: observedAt)
        }
    }

    private func watchCandidate(_ candidate: io_service_t, entryID: UInt64) {
        guard IOObjectRetain(candidate) == KERN_SUCCESS else {
            candidateSetupFailed = true
            _ = invalidateCandidate(entryID, terminated: true, event: "watch-failed", observedAt: nil, eventKind: .watchFailed)
            return
        }
        var interest: io_object_t = IO_OBJECT_NULL
        guard let notificationPort, let callbackContext,
              IOServiceAddInterestNotification(notificationPort, candidate, kIOGeneralInterest,
                  connectionInterestCallback, callbackContext, &interest) == KERN_SUCCESS else {
            if interest != IO_OBJECT_NULL { _ = IOObjectRelease(interest) }
            _ = IOObjectRelease(candidate)
            candidateSetupFailed = true
            _ = invalidateCandidate(entryID, terminated: true, event: "watch-failed", observedAt: nil, eventKind: .watchFailed)
            return
        }
        candidateServices[entryID] = (candidate, interest)
    }

    private func invalidateCandidate(
        _ entryID: UInt64, terminated: Bool, event: String, observedAt: UInt64?,
        eventKind: ConnectionObservationEvent = .interest, messageType: UInt32? = nil,
        messageArgument: ConnectionObservedArgument? = nil,
        location: ConnectionObservedLocation? = nil
    ) -> Bool {
        let registered = candidates.diagnosticCandidate(entryID: entryID)
        let candidateClass = candidates.invalidate(entryID: entryID, terminated: terminated)
        let scope = connectionRegistryScope(entryID: entryID, target: targetEntryID, internalProof: expectedInternalRegistryID)
        signalInvalidation("io-negative scope=\(scope.rawValue) class=\(candidateClass?.rawValue ?? "unclassified") event=\(event)", observedAt: observedAt)
        // Formatting and output happen only after authorization has been revoked.
        observe(eventKind, entryID: entryID, candidate: registered, observedAt: observedAt,
                messageType: messageType, messageArgument: messageArgument, location: location, disposition: .revoked)
        guard let candidateClass else { return false }
        log("candidate \(event) class=\(candidateClass.rawValue) invalidated=true（仅安全条件失效，非已确认拔线）", observedAt: observedAt)
        return true
    }

    private func releaseCandidate(_ entryID: UInt64) {
        guard let candidate = candidateServices.removeValue(forKey: entryID) else { return }
        _ = IOObjectRelease(candidate.interest)
        _ = IOObjectRelease(candidate.service)
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

    fileprivate func handleInterest(
        _ service: io_service_t, _ messageType: UInt32, _ messageArgument: ConnectionObservedArgument
    ) {
        guard !resourcesReleased else { return }
        let observedAt = try? ContinuousClock.nanoseconds()
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else {
            _ = invalidateCandidate(0, terminated: false, event: "unclassified interest", observedAt: observedAt,
                                    messageType: messageType, messageArgument: messageArgument)
            return
        }
        // 保护协商信息不证明链路健康；只使用本轮有效登记，不能依赖诊断分类。
        if candidates.permitsProtectionInformation(
            entryID: entryID, messageType: messageType, messageArgument: messageArgument,
            interestRegistered: candidateServices[entryID] != nil,
            internalDisplayID: expectedDisabledInternal
        ) {
            observe(.interest, entryID: entryID, observedAt: observedAt,
                    messageType: messageType, messageArgument: messageArgument,
                    disposition: .informational)
            return
        }
        if let observedAt, candidates.reconfigurationCandidates(
            registered: Set(candidateServices.keys), internalDisplayID: expectedDisabledInternal
        ) != nil, reconfiguration.consume(entryID: entryID, messageType: messageType,
                                           argument: messageArgument, at: observedAt) {
            observe(.interest, entryID: entryID, observedAt: observedAt,
                    messageType: messageType, messageArgument: messageArgument,
                    disposition: .pendingReconfiguration)
            return
        }
        if invalidateCandidate(entryID, terminated: false, event: "interest type=\(messageType)", observedAt: observedAt,
                               messageType: messageType, messageArgument: messageArgument) {
            return
        }
        guard entryID == targetEntryID else { return }
        switch messageType {
        case servicePropertyChange:
            log("property-change", observedAt: observedAt)
        case serviceTerminated:
            log("termination", observedAt: observedAt)
        default:
            log("interest", observedAt: observedAt)
        }
    }

    fileprivate func enqueueDisplayChange(_ display: UInt32, _ flags: CGDisplayChangeSummaryFlags) {
        let observedAt = try? ContinuousClock.nanoseconds()
        let reason = connectionChangeInvalidationReason(
            display: display,
            flags: flags,
            expectedDisabledInternal: expectedDisabledInternal
        )
        // 撤权不能等在可能阻塞的显示快照之后。
        if let reason {
            let scope = display == 0 ? "unknown" : (display == expectedDisabledInternal ? "expected-internal" : "other")
            signalInvalidation("\(reason) scope=\(scope) flags=\(flags.rawValue)", observedAt: observedAt)
        }
        if (reportsEvents || expectedDisabledInternal != nil), let observedAt {
            traceConnectionObservation(ConnectionDisplayObservation(
                role: diagnosticRole, observerStartedAtNanoseconds: startedAt,
                continuousNs: observedAt, flags: flags.rawValue,
                scope: connectionDisplayScope(display: display, expectedDisabledInternal: expectedDisabledInternal),
                invalidationReason: reason
            ))
        }
        queue.async { [weak self] in
            guard let self, !self.resourcesReleased else { return }
            if reason != nil { _ = self.candidates.invalidate(entryID: 0, terminated: false) }
            self.onReconfiguration()
            guard self.reportsEvents else { return }
            let activeCount = (try? readSnapshot().displays.filter(\.isActive).count)
                .map(String.init) ?? "不可读"
            self.log("display-change flags=\(flags.rawValue) 活动数=\(activeCount) candidate-invalidated=\(self.candidates.invalidated)（仅作观测，不证明可用）", observedAt: observedAt)
        }
    }

    private func log(_ event: String, observedAt: UInt64? = nil) {
        guard reportsEvents, let startedAt,
              let now = observedAt ?? (try? ContinuousClock.nanoseconds()),
              now >= startedAt else { return }
        print("[\((now - startedAt) / 1_000_000)ms] \(event) continuousNs=\(now)")
    }

    private func observe(
        _ event: ConnectionObservationEvent, entryID: UInt64,
        candidate: ConnectionCandidateDiagnostic? = nil, observedAt: UInt64?,
        messageType: UInt32? = nil, messageArgument: ConnectionObservedArgument? = nil,
        location: ConnectionObservedLocation? = nil, initial: Bool? = nil,
        disposition: ConnectionObservationDisposition
    ) {
        guard reportsEvents || expectedDisabledInternal != nil else { return }
        guard let timestamp = observedAt ?? (try? ContinuousClock.nanoseconds()) else { return }
        let diagnosticCandidate = candidate ?? candidates.diagnosticCandidate(entryID: entryID)
        let messageClassification = connectionMessageClassification(
            event: event,
            candidate: diagnosticCandidate,
            messageType: messageType,
            messageArgument: messageArgument
        )
        traceConnectionObservation(ConnectionObservation(
            role: diagnosticRole, observerStartedAtNanoseconds: startedAt, continuousNs: timestamp,
            event: event, candidateOrdinal: candidateOrdinals[entryID],
            candidate: diagnosticCandidate,
            registryScope: connectionRegistryScope(entryID: entryID, target: targetEntryID, internalProof: expectedInternalRegistryID),
            messageType: messageType, messageArgument: messageArgument,
            messageClassification: messageClassification, observedLocation: location, initial: initial,
            disposition: disposition, invalidated: candidates.invalidated
        ))
    }

    private func releaseResourcesOnQueue() {
        guard !resourcesReleased else { return }
        abortInternalReconfiguration()
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
        for entryID in Array(candidateServices.keys) { releaseCandidate(entryID) }
        candidateOrdinals.removeAll()
        for iterator in matchingIterators.keys {
            _ = IOObjectRelease(iterator)
        }
        matchingIterators.removeAll()
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
    observer.handleInterest(service, messageType, ConnectionObservedArgument(messageArgument))
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
    observer.enqueueDisplayChange(display, flags)
}
