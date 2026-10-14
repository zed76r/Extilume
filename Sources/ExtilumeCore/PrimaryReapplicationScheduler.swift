import Dispatch
import Foundation

// Callers provide a serial owner queue; mutable state stays confined there.
public final class PrimaryReapplicationScheduler: @unchecked Sendable {
    private let ownerQueue: DispatchQueue
    private var pendingWorkItem: DispatchWorkItem?
    private var pendingIdentifier: UUID?
    private let cancellationLock = NSLock()
    private var currentIdentifier: UUID?

    public var hasPending: Bool {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        return pendingWorkItem != nil
    }

    public init(ownerQueue: DispatchQueue) {
        self.ownerQueue = ownerQueue
    }

    public func schedule(_ action: @escaping @Sendable (@Sendable () -> Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        pendingWorkItem?.cancel()

        let identifier = UUID()
        cancellationLock.withLock { currentIdentifier = identifier }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.ownerQueue))
            guard self.pendingIdentifier == identifier else { return }

            self.pendingWorkItem = nil
            self.pendingIdentifier = nil
            guard self.isCurrent(identifier) else { return }
            action { [weak self] in self?.isCurrent(identifier) == true }
        }
        pendingIdentifier = identifier
        pendingWorkItem = workItem
        ownerQueue.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    public func cancel() {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingIdentifier = nil
        invalidate()
    }

    // 系统事件可在 owner queue 被独立读回阻塞时立即撤销当前接管意图。
    public func invalidate() {
        cancellationLock.withLock { currentIdentifier = nil }
    }

    private func isCurrent(_ identifier: UUID) -> Bool {
        cancellationLock.withLock { currentIdentifier == identifier }
    }
}
