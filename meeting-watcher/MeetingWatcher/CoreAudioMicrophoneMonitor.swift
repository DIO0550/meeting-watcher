import Dispatch
import Foundation

nonisolated fileprivate final class SerialCoreAudioExecutionContext: @unchecked Sendable {
    typealias Work = @Sendable () -> Void

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()

    init() {
        queue = DispatchQueue(label: "MeetingWatcher.CoreAudioWork")
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        queue.setSpecific(key: queueKey, value: nil)
    }

    func enqueue(_ work: @escaping Work) {
        queue.async(execute: work)
    }

    func run(_ work: @escaping Work) async {
        await withCheckedContinuation { continuation in
            queue.async {
                work()
                continuation.resume()
            }
        }
    }

    func preconditionIsolated(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(
            DispatchQueue.getSpecific(key: queueKey) == true,
            "CoreAudio worker escaped its owned serial executor",
            file: file,
            line: line
        )
    }
}

nonisolated final class SerialCoreAudioAsyncExecutor: @unchecked Sendable {
    typealias Work = @Sendable () -> Void

    // The worker shares only this context and never points back to the executor.
    fileprivate let executionContext: SerialCoreAudioExecutionContext
    private let lock = NSLock()
    private let manualExecution: Bool
    private var manualWorkItems: [Work] = []
    private var maximumPending = 0
    private var generation: UInt64 = 0

    init(manualExecution: Bool = false) {
        executionContext = SerialCoreAudioExecutionContext()
        self.manualExecution = manualExecution
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return manualWorkItems.count
    }

    var maximumPendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumPending
    }

    func execute(_ work: @escaping Work) {
        lock.lock()
        generation &+= 1
        if manualExecution {
            manualWorkItems.append(work)
            maximumPending = max(maximumPending, manualWorkItems.count)
            lock.unlock()
        } else {
            lock.unlock()
            executionContext.enqueue(work)
        }
    }

    func drain() async {
        if manualExecution {
            while let work = takeManualWork() { await executionContext.run(work) }
            return
        }
        while true {
            let target = currentGeneration()
            await executionContext.run {}
            if currentGeneration() == target { return }
        }
    }

    private func takeManualWork() -> Work? {
        lock.lock()
        defer { lock.unlock() }
        return manualWorkItems.isEmpty ? nil : manualWorkItems.removeFirst()
    }

    private func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }
}

nonisolated private final class CoreAudioMainActorResultBox<Value>: @unchecked Sendable {
    var value: Value?
}

nonisolated private func coreAudioMainActorSync<Value: Sendable>(
    _ work: @escaping @MainActor @Sendable () -> Value
) -> Value {
    precondition(!Thread.isMainThread)
    let box = CoreAudioMainActorResultBox<Value>()
    let completed = DispatchSemaphore(value: 0)
    Task { @MainActor in
        box.value = work()
        completed.signal()
    }
    completed.wait()
    return box.value!
}

nonisolated protocol CoreAudioRefreshRetryScheduling: Sendable {
    func schedule(
        after delay: TimeInterval,
        _ work: @escaping @MainActor @Sendable () -> Void
    )
}

nonisolated final class DispatchCoreAudioRefreshRetryScheduler: CoreAudioRefreshRetryScheduling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "MeetingWatcher.CoreAudioRefreshRetry")

    func schedule(
        after delay: TimeInterval,
        _ work: @escaping @MainActor @Sendable () -> Void
    ) {
        queue.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in work() }
        }
    }
}

nonisolated protocol CoreAudioCleanupRetryScheduling: Sendable {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void)
}

nonisolated final class DispatchCoreAudioCleanupRetryScheduler: CoreAudioCleanupRetryScheduling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "MeetingWatcher.CoreAudioCleanup")

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

nonisolated final class CoreAudioCleanupCoordinator: @unchecked Sendable {
    static let shared = CoreAudioCleanupCoordinator(
        scheduler: DispatchCoreAudioCleanupRetryScheduler()
    )

    private let scheduler: any CoreAudioCleanupRetryScheduling
    private let lock = NSLock()
    private var registrations: [ObjectIdentifier: any CoreAudioListenerRegistration] = [:]
    private var retryScheduled = false
    private var nextDelay: TimeInterval
    private let initialDelay: TimeInterval
    private let maximumDelay: TimeInterval

    init(
        scheduler: any CoreAudioCleanupRetryScheduling,
        initialDelay: TimeInterval = 0.25,
        maximumDelay: TimeInterval = 8
    ) {
        self.scheduler = scheduler
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        nextDelay = initialDelay
    }

    var retainedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registrations.count
    }

    func retainUntilRemoved(_ newRegistrations: [any CoreAudioListenerRegistration]) {
        newRegistrations.forEach { $0.invalidate() }
        lock.lock()
        for registration in newRegistrations {
            registrations[ObjectIdentifier(registration)] = registration
        }
        lock.unlock()
        scheduleRetryIfNeeded()
    }

    private func scheduleRetryIfNeeded() {
        lock.lock()
        guard !registrations.isEmpty, !retryScheduled else {
            lock.unlock()
            return
        }
        retryScheduled = true
        let delay = nextDelay
        lock.unlock()

        // Each delayed closure owns the coordinator until this cleanup chain is empty.
        scheduler.schedule(after: delay) { [self] in
            retry()
        }
    }

    private func retry() {
        lock.lock()
        retryScheduled = false
        let snapshot = registrations
        lock.unlock()

        var removed: [ObjectIdentifier] = []
        for (identifier, registration) in snapshot {
            registration.invalidate()
            do {
                try registration.cancel()
                removed.append(identifier)
            } catch {
                continue
            }
        }

        lock.lock()
        for identifier in removed {
            if let current = registrations[identifier],
               let attempted = snapshot[identifier],
               current === attempted {
                registrations[identifier] = nil
            }
        }
        if registrations.isEmpty {
            nextDelay = initialDelay
        } else {
            nextDelay = min(maximumDelay, max(initialDelay, nextDelay * 2))
        }
        lock.unlock()
        scheduleRetryIfNeeded()
    }
}

nonisolated enum CoreAudioListenerKey: Hashable, Sendable {
    case system
    case device(AudioInputDeviceID)
}

nonisolated enum CoreAudioRefreshRequest: Equatable, Sendable {
    case topology
    case devices(Set<AudioInputDeviceID>)

    func merging(_ other: CoreAudioRefreshRequest) -> CoreAudioRefreshRequest {
        switch (self, other) {
        case (.topology, _), (_, .topology):
            return .topology
        case let (.devices(lhs), .devices(rhs)):
            return .devices(lhs.union(rhs))
        }
    }

    func subtracting(_ reconciled: CoreAudioRefreshRequest) -> CoreAudioRefreshRequest? {
        switch (self, reconciled) {
        case (_, .topology):
            return nil
        case (.topology, .devices):
            return .topology
        case let (.devices(pending), .devices(succeeded)):
            let remaining = pending.subtracting(succeeded)
            return remaining.isEmpty ? nil : .devices(remaining)
        }
    }
}

nonisolated private enum CoreAudioWorkerStatus: Sendable {
    case active
    case inactive
    case unknown
}

nonisolated private struct CoreAudioWorkerObservation: Sendable {
    let status: CoreAudioWorkerStatus
    let reason: String
    let monitoringReady: Bool
    let retryRequest: CoreAudioRefreshRequest?
    let reconciledRequest: CoreAudioRefreshRequest?
}

nonisolated private final class CoreAudioMonitorWorker: @unchecked Sendable {
    // Mutable worker state is confined to executionContext; every entry asserts that ownership.
    private let backend: any CoreAudioBackend
    private let cleanupCoordinator: CoreAudioCleanupCoordinator
    private let executionContext: SerialCoreAudioExecutionContext
    private var activeListeners: [CoreAudioListenerKey: any CoreAudioListenerRegistration] = [:]
    private var pendingCancellations: [CoreAudioListenerKey: any CoreAudioListenerRegistration] = [:]
    private var currentEventSink: CoreAudioSessionEventSink?
    // Sticky across cleanup, enumeration, listener, and topology read failures; only stop or a
    // complete full reconciliation clears the topology intent. Device-only read failures are
    // reported separately as a retry request for exactly the unresolved device IDs.
    private var topologyRefreshRequired = false
    private var currentDeviceIDs: Set<AudioInputDeviceID> = []
    private var runningCache: [AudioInputDeviceID: Bool] = [:]

    init(
        backend: any CoreAudioBackend,
        cleanupCoordinator: CoreAudioCleanupCoordinator,
        executionContext: SerialCoreAudioExecutionContext
    ) {
        self.backend = backend
        self.cleanupCoordinator = cleanupCoordinator
        self.executionContext = executionContext
    }

    func start(eventSink: CoreAudioSessionEventSink) -> CoreAudioWorkerObservation {
        executionContext.preconditionIsolated()
        topologyRefreshRequired = true
        var cleanupErrors = retryPendingCancellations()
        if currentEventSink !== eventSink {
            currentEventSink?.invalidate()
            for key in ordered(Array(activeListeners.keys)) {
                cleanupErrors.append(contentsOf: cancelActiveListener(for: key))
            }
            currentDeviceIDs.removeAll()
            runningCache.removeAll()
            currentEventSink = eventSink
        }
        guard cleanupErrors.isEmpty else {
            return unknown(errors: cleanupErrors, retryRequest: .topology)
        }
        if activeListeners[.system] == nil {
            do {
                activeListeners[.system] = try backend.observeDeviceListChanges {
                    eventSink.emit(.topology)
                }
            } catch {
                return unknown(errors: [error], retryRequest: .topology)
            }
        }
        return refreshTopology(eventSink: eventSink)
    }

    func refresh(
        request: CoreAudioRefreshRequest,
        eventSink: CoreAudioSessionEventSink
    ) -> CoreAudioWorkerObservation {
        executionContext.preconditionIsolated()
        if request == .topology { topologyRefreshRequired = true }
        let cleanupErrors = retryPendingCancellations()
        guard cleanupErrors.isEmpty else {
            return unknown(
                errors: cleanupErrors,
                retryRequest: topologyRefreshRequired ? .topology : request
            )
        }
        if activeListeners[.system] == nil {
            topologyRefreshRequired = true
            do {
                activeListeners[.system] = try backend.observeDeviceListChanges {
                    eventSink.emit(.topology)
                }
            } catch {
                return unknown(errors: [error], retryRequest: .topology)
            }
        }
        if topologyRefreshRequired {
            return refreshTopology(eventSink: eventSink)
        }
        guard case let .devices(deviceIDs) = request else {
            return refreshTopology(eventSink: eventSink)
        }
        return refreshDevices(deviceIDs)
    }

    func stop() -> [String] {
        executionContext.preconditionIsolated()
        var errors = retryPendingCancellations()
        for key in ordered(Array(activeListeners.keys)) {
            errors.append(contentsOf: cancelActiveListener(for: key))
        }
        currentEventSink?.invalidate()
        currentEventSink = nil
        topologyRefreshRequired = false
        currentDeviceIDs.removeAll()
        runningCache.removeAll()
        return errors.map(describe)
    }

    func shutdown(maximumAttempts: Int) {
        executionContext.preconditionIsolated()
        for _ in 0..<maximumAttempts {
            _ = stop()
            if activeListeners.isEmpty, pendingCancellations.isEmpty { return }
        }
        let remaining = Array(activeListeners.values) + Array(pendingCancellations.values)
        remaining.forEach { $0.invalidate() }
        activeListeners.removeAll()
        pendingCancellations.removeAll()
        cleanupCoordinator.retainUntilRemoved(remaining)
    }

    private func refreshTopology(
        eventSink: CoreAudioSessionEventSink
    ) -> CoreAudioWorkerObservation {
        let deviceIDs: Set<AudioInputDeviceID>
        do {
            deviceIDs = Set(try backend.inputDeviceIDs())
        } catch {
            return unknown(errors: [error], retryRequest: .topology)
        }

        var errors: [any Error] = []
        for deviceID in currentDeviceIDs.subtracting(deviceIDs).sorted() {
            errors.append(contentsOf: cancelActiveListener(for: .device(deviceID)))
            runningCache[deviceID] = nil
        }
        currentDeviceIDs = deviceIDs

        for deviceID in deviceIDs.sorted() {
            let key = CoreAudioListenerKey.device(deviceID)
            if activeListeners[key] == nil, pendingCancellations[key] == nil {
                do {
                    activeListeners[key] = try backend.observeRunningStateChanges(deviceID: deviceID) {
                        eventSink.emit(.devices([deviceID]))
                    }
                } catch {
                    errors.append(error)
                }
            }
            do {
                runningCache[deviceID] = try backend.isRunningSomewhere(deviceID: deviceID)
            } catch {
                runningCache[deviceID] = nil
                errors.append(error)
            }
        }
        guard errors.isEmpty, hasCompleteDeviceState else {
            return unknown(errors: errors, retryRequest: .topology)
        }
        topologyRefreshRequired = false
        return known(reconciledRequest: .topology)
    }

    private func refreshDevices(
        _ requestedDeviceIDs: Set<AudioInputDeviceID>
    ) -> CoreAudioWorkerObservation {
        let unavailableDeviceIDs = requestedDeviceIDs.subtracting(currentDeviceIDs)
        guard unavailableDeviceIDs.isEmpty else {
            topologyRefreshRequired = true
            return unknown(
                errors: [CoreAudioError.invalidPropertyData(operation: .enumerateDevices)],
                retryRequest: .topology
            )
        }

        var errors: [any Error] = []
        var succeeded: Set<AudioInputDeviceID> = []
        var failed: Set<AudioInputDeviceID> = []
        for deviceID in requestedDeviceIDs.sorted() {
            do {
                runningCache[deviceID] = try backend.isRunningSomewhere(deviceID: deviceID)
                succeeded.insert(deviceID)
            } catch {
                runningCache[deviceID] = nil
                failed.insert(deviceID)
                errors.append(error)
            }
        }

        let reconciledRequest: CoreAudioRefreshRequest? = succeeded.isEmpty
            ? nil
            : .devices(succeeded)
        let retryRequest: CoreAudioRefreshRequest? = failed.isEmpty
            ? missingStateRetryRequest
            : .devices(failed)
        guard errors.isEmpty, hasCompleteDeviceState else {
            return unknown(
                errors: errors,
                retryRequest: retryRequest,
                reconciledRequest: reconciledRequest
            )
        }
        return known(reconciledRequest: reconciledRequest ?? .devices([]))
    }

    private func known(
        reconciledRequest: CoreAudioRefreshRequest
    ) -> CoreAudioWorkerObservation {
        let anyRunning = currentDeviceIDs.contains { runningCache[$0] == true }
        // Known macOS limitation: some Bluetooth input routes keep
        // DeviceIsRunningSomewhere false while the microphone is in use, producing a
        // false inactive result. The camera signal complements this weak microphone
        // signal. Duplex devices can also report active for output-only use.
        return CoreAudioWorkerObservation(
            status: anyRunning ? .active : .inactive,
            reason: anyRunning
                ? "At least one CoreAudio input device is running"
                : "No CoreAudio input device is running",
            monitoringReady: true,
            retryRequest: nil,
            reconciledRequest: reconciledRequest
        )
    }

    private var hasCompleteDeviceState: Bool {
        currentDeviceIDs.allSatisfy { deviceID in
            runningCache[deviceID] != nil
                && activeListeners[.device(deviceID)] != nil
                && pendingCancellations[.device(deviceID)] == nil
        }
    }

    private var missingStateRetryRequest: CoreAudioRefreshRequest? {
        if activeListeners[.system] == nil || currentDeviceIDs.contains(where: {
            activeListeners[.device($0)] == nil || pendingCancellations[.device($0)] != nil
        }) {
            return .topology
        }
        let missingReadDeviceIDs = Set(currentDeviceIDs.filter { runningCache[$0] == nil })
        return missingReadDeviceIDs.isEmpty ? nil : .devices(missingReadDeviceIDs)
    }

    private func retryPendingCancellations() -> [any Error] {
        var errors: [any Error] = []
        for key in ordered(Array(pendingCancellations.keys)) {
            guard let registration = pendingCancellations[key] else { continue }
            registration.invalidate()
            do {
                try registration.cancel()
                pendingCancellations[key] = nil
            } catch {
                errors.append(error)
            }
        }
        return errors
    }

    private func cancelActiveListener(for key: CoreAudioListenerKey) -> [any Error] {
        guard let registration = activeListeners.removeValue(forKey: key) else { return [] }
        registration.invalidate()
        do {
            try registration.cancel()
            return []
        } catch {
            pendingCancellations[key] = registration
            return [error]
        }
    }

    private func ordered(_ keys: [CoreAudioListenerKey]) -> [CoreAudioListenerKey] {
        keys.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case (.system, .system): return false
            case (.system, .device(_)): return true
            case (.device(_), .system): return false
            case let (.device(lhsID), .device(rhsID)): return lhsID < rhsID
            }
        }
    }

    private func unknown(
        errors: [any Error],
        retryRequest: CoreAudioRefreshRequest?,
        reconciledRequest: CoreAudioRefreshRequest? = nil
    ) -> CoreAudioWorkerObservation {
        let details = errors.isEmpty ? "incomplete device cache" : errors.map(describe).joined(separator: "; ")
        return CoreAudioWorkerObservation(
            status: .unknown,
            reason: "CoreAudio microphone state unavailable: \(details)",
            monitoringReady: true,
            retryRequest: retryRequest,
            reconciledRequest: reconciledRequest
        )
    }

    private func describe(_ error: any Error) -> String {
        (error as? CoreAudioError)?.description ?? String(describing: error)
    }
}

nonisolated final class CoreAudioSessionEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@MainActor @Sendable (CoreAudioRefreshRequest) -> Void)?

    init(handler: @escaping @MainActor @Sendable (CoreAudioRefreshRequest) -> Void) {
        self.handler = handler
    }

    @MainActor
    func emit(_ request: CoreAudioRefreshRequest) {
        lock.lock()
        let currentHandler = handler
        lock.unlock()
        currentHandler?(request)
    }

    func invalidate() {
        lock.lock()
        handler = nil
        lock.unlock()
    }
}

nonisolated private enum CoreAudioLifecycleAction: Sendable {
    case start(session: UInt64, eventSink: CoreAudioSessionEventSink)
    case stop(session: UInt64)
}

nonisolated private struct CoreAudioLifecycleCommand: Sendable {
    let id: UInt64
    let action: CoreAudioLifecycleAction
}

nonisolated private struct CoreAudioRefreshFlight: Sendable {
    let id: UInt64
    let session: UInt64
    let request: CoreAudioRefreshRequest
    let eventSink: CoreAudioSessionEventSink
}

nonisolated private final class CoreAudioRefreshRetryToken: @unchecked Sendable {}

@MainActor
final class CoreAudioMicrophoneMonitor {
    typealias StateHandler = @MainActor @Sendable (RawSignalState) -> Void
    typealias Clock = @MainActor @Sendable () -> Date
    typealias ResultScheduler = @MainActor @Sendable (
        @escaping @MainActor @Sendable () -> Void
    ) -> Void

    private struct PublishedState: Equatable {
        let status: RawSignalState.Status
        let reason: String
    }

    private let worker: CoreAudioMonitorWorker
    private let executor: SerialCoreAudioAsyncExecutor
    private let refreshRetryScheduler: any CoreAudioRefreshRetryScheduling
    private let refreshRetryInitialDelay: TimeInterval
    private let refreshRetryMaximumDelay: TimeInterval
    private let resultScheduler: ResultScheduler
    private let now: Clock
    private let stateHandler: StateHandler
    private var isStarted = false
    private var session: UInt64 = 0
    private var nextCommandID: UInt64 = 0
    private var currentEventSink: CoreAudioSessionEventSink?
    private var lifecycleInFlight: CoreAudioLifecycleCommand?
    private var lifecycleDirty: CoreAudioLifecycleCommand?
    private var refreshInFlight: CoreAudioRefreshFlight?
    private var refreshDirty: CoreAudioRefreshRequest?
    private var refreshRetryToken: CoreAudioRefreshRetryToken?
    private var pendingRetryRequest: CoreAudioRefreshRequest?
    private var refreshRetryNextDelay: TimeInterval
    private var lastPublishedState: PublishedState?

    init(
        backend: any CoreAudioBackend,
        executor: SerialCoreAudioAsyncExecutor = SerialCoreAudioAsyncExecutor(),
        cleanupCoordinator: CoreAudioCleanupCoordinator = .shared,
        refreshRetryScheduler: any CoreAudioRefreshRetryScheduling = DispatchCoreAudioRefreshRetryScheduler(),
        refreshRetryInitialDelay: TimeInterval = 0.25,
        refreshRetryMaximumDelay: TimeInterval = 8,
        resultScheduler: @escaping ResultScheduler = { $0() },
        now: @escaping Clock = { Date() },
        stateHandler: @escaping StateHandler
    ) {
        worker = CoreAudioMonitorWorker(
            backend: backend,
            cleanupCoordinator: cleanupCoordinator,
            executionContext: executor.executionContext
        )
        self.executor = executor
        self.refreshRetryScheduler = refreshRetryScheduler
        self.refreshRetryInitialDelay = refreshRetryInitialDelay
        self.refreshRetryMaximumDelay = refreshRetryMaximumDelay
        refreshRetryNextDelay = refreshRetryInitialDelay
        self.resultScheduler = resultScheduler
        self.now = now
        self.stateHandler = stateHandler
    }

    func start() {
        if isStarted {
            enqueueRefresh(.topology)
            return
        }
        invalidateRefreshRetry(resetBackoff: true)
        session &+= 1
        let startedSession = session
        refreshDirty = nil
        isStarted = true
        let eventSink = CoreAudioSessionEventSink { [weak self] request in
            guard self?.session == startedSession else { return }
            self?.enqueueRefresh(request)
        }
        currentEventSink = eventSink
        enqueueLifecycle(.start(session: startedSession, eventSink: eventSink))
    }

    func stop() {
        let wasStarted = isStarted
        isStarted = false
        invalidateRefreshRetry(resetBackoff: true)
        session &+= 1
        let stoppedSession = session
        currentEventSink?.invalidate()
        currentEventSink = nil
        refreshDirty = nil
        enqueueLifecycle(.stop(session: stoppedSession))
        guard wasStarted else { return }
        publish(status: .unknown, reason: "CoreAudio microphone monitoring stopped")
    }

    func invalidatePublishedSemanticState() {
        lastPublishedState = nil
    }

    private func enqueueLifecycle(_ action: CoreAudioLifecycleAction) {
        let command = CoreAudioLifecycleCommand(id: makeCommandID(), action: action)
        guard lifecycleInFlight == nil, refreshInFlight == nil else {
            lifecycleDirty = command
            return
        }
        launchLifecycle(command)
    }

    private func launchLifecycle(_ command: CoreAudioLifecycleCommand) {
        lifecycleInFlight = command
        let worker = worker
        executor.execute { [weak self] in
            let shouldExecute = coreAudioMainActorSync { [weak self] in
                self?.shouldExecute(command) == true
            }
            guard shouldExecute else {
                coreAudioMainActorSync { [weak self] in
                    self?.stageLifecycleResult(command: command, observation: nil, stopErrors: [])
                }
                return
            }
            let observation: CoreAudioWorkerObservation?
            let stopErrors: [String]
            switch command.action {
            case let .start(_, eventSink):
                observation = worker.start(eventSink: eventSink)
                stopErrors = []
            case .stop:
                observation = nil
                stopErrors = worker.stop()
            }
            coreAudioMainActorSync { [weak self] in
                self?.stageLifecycleResult(
                    command: command,
                    observation: observation,
                    stopErrors: stopErrors
                )
            }
        }
    }

    private func shouldExecute(_ command: CoreAudioLifecycleCommand) -> Bool {
        switch command.action {
        case let .start(commandSession, eventSink):
            return isStarted && session == commandSession && currentEventSink === eventSink
        case let .stop(commandSession):
            return !isStarted && session == commandSession
        }
    }

    private func stageLifecycleResult(
        command: CoreAudioLifecycleCommand,
        observation: CoreAudioWorkerObservation?,
        stopErrors: [String]
    ) {
        resultScheduler { [weak self] in
            self?.finishLifecycle(
                command: command,
                observation: observation,
                stopErrors: stopErrors
            )
        }
    }

    private func finishLifecycle(
        command: CoreAudioLifecycleCommand,
        observation: CoreAudioWorkerObservation?,
        stopErrors: [String]
    ) {
        guard lifecycleInFlight?.id == command.id else { return }
        lifecycleInFlight = nil
        switch command.action {
        case let .start(commandSession, eventSink):
            if isStarted, session == commandSession, currentEventSink === eventSink,
               let observation {
                updateRefreshRetry(observation, session: commandSession)
                if !observation.monitoringReady {
                    isStarted = false
                    invalidateRefreshRetry(resetBackoff: true)
                    refreshDirty = nil
                    eventSink.invalidate()
                    currentEventSink = nil
                }
                publish(status: rawSignalStatus(observation.status), reason: observation.reason)
            }
        case let .stop(commandSession):
            if !isStarted, session == commandSession, !stopErrors.isEmpty {
                publish(
                    status: .unknown,
                    reason: "CoreAudio microphone state unavailable: \(stopErrors.joined(separator: "; "))"
                )
            }
        }
        if let dirty = lifecycleDirty {
            lifecycleDirty = nil
            launchLifecycle(dirty)
        } else if isStarted, lifecycleInFlight == nil, let dirty = refreshDirty {
            refreshDirty = nil
            launchRefresh(dirty)
        }
    }

    private func enqueueRefresh(_ request: CoreAudioRefreshRequest) {
        guard isStarted, currentEventSink != nil else { return }
        if lifecycleInFlight != nil || refreshInFlight != nil {
            refreshDirty = refreshDirty?.merging(request) ?? request
            return
        }
        launchRefresh(request)
    }

    private func launchRefresh(_ request: CoreAudioRefreshRequest) {
        guard let eventSink = currentEventSink else { return }
        let flight = CoreAudioRefreshFlight(
            id: makeCommandID(),
            session: session,
            request: request,
            eventSink: eventSink
        )
        refreshInFlight = flight
        let worker = worker
        executor.execute { [weak self] in
            let shouldExecute = coreAudioMainActorSync { [weak self] in
                self?.shouldExecute(flight) == true
            }
            guard shouldExecute else {
                coreAudioMainActorSync { [weak self] in
                    self?.stageRefreshResult(flight: flight, observation: nil)
                }
                return
            }
            let observation = worker.refresh(request: flight.request, eventSink: eventSink)
            coreAudioMainActorSync { [weak self] in
                self?.stageRefreshResult(flight: flight, observation: observation)
            }
        }
    }

    private func shouldExecute(_ flight: CoreAudioRefreshFlight) -> Bool {
        isStarted
            && lifecycleInFlight == nil
            && session == flight.session
            && currentEventSink === flight.eventSink
    }

    private func stageRefreshResult(
        flight: CoreAudioRefreshFlight,
        observation: CoreAudioWorkerObservation?
    ) {
        resultScheduler { [weak self] in
            self?.finishRefresh(flight: flight, observation: observation)
        }
    }

    private func finishRefresh(
        flight: CoreAudioRefreshFlight,
        observation: CoreAudioWorkerObservation?
    ) {
        guard refreshInFlight?.id == flight.id else { return }
        refreshInFlight = nil
        if isStarted, session == flight.session, currentEventSink === flight.eventSink,
           let observation {
            updateRefreshRetry(observation, session: flight.session)
            if !observation.monitoringReady {
                isStarted = false
                invalidateRefreshRetry(resetBackoff: true)
                refreshDirty = nil
                currentEventSink?.invalidate()
                currentEventSink = nil
            }
            publish(status: rawSignalStatus(observation.status), reason: observation.reason)
        }
        if let lifecycle = lifecycleDirty {
            lifecycleDirty = nil
            launchLifecycle(lifecycle)
        } else if isStarted, session == flight.session, let dirty = refreshDirty {
            refreshDirty = nil
            launchRefresh(dirty)
        }
    }

    private func updateRefreshRetry(
        _ observation: CoreAudioWorkerObservation,
        session observationSession: UInt64
    ) {
        guard observation.monitoringReady else {
            invalidateRefreshRetry(resetBackoff: true)
            return
        }

        if let reconciledRequest = observation.reconciledRequest {
            pendingRetryRequest = pendingRetryRequest?.subtracting(reconciledRequest)
        }
        if let retryRequest = observation.retryRequest {
            pendingRetryRequest = pendingRetryRequest?.merging(retryRequest) ?? retryRequest
        }

        guard pendingRetryRequest != nil else {
            invalidateRefreshRetry(resetBackoff: true)
            return
        }
        scheduleRefreshRetry(session: observationSession)
    }

    private func scheduleRefreshRetry(session retrySession: UInt64) {
        guard refreshRetryToken == nil, pendingRetryRequest != nil else { return }
        let token = CoreAudioRefreshRetryToken()
        refreshRetryToken = token
        let delay = refreshRetryNextDelay
        refreshRetryNextDelay = min(
            refreshRetryMaximumDelay,
            max(refreshRetryInitialDelay, refreshRetryNextDelay * 2)
        )
        refreshRetryScheduler.schedule(after: delay) { [weak self] in
            guard let self, self.refreshRetryToken === token,
                  self.isStarted, self.session == retrySession,
                  let request = self.pendingRetryRequest else { return }
            self.refreshRetryToken = nil
            self.enqueueRefresh(request)
        }
    }

    private func invalidateRefreshRetry(resetBackoff: Bool) {
        refreshRetryToken = nil
        pendingRetryRequest = nil
        if resetBackoff { refreshRetryNextDelay = refreshRetryInitialDelay }
    }

    private func rawSignalStatus(_ status: CoreAudioWorkerStatus) -> RawSignalState.Status {
        switch status {
        case .active: return .active
        case .inactive: return .inactive
        case .unknown: return .unknown
        }
    }

    private func makeCommandID() -> UInt64 {
        nextCommandID &+= 1
        return nextCommandID
    }

    private func publish(status: RawSignalState.Status, reason: String) {
        let semantic = PublishedState(status: status, reason: reason)
        guard lastPublishedState != semantic else { return }
        lastPublishedState = semantic
        stateHandler(RawSignalState(
            status: status,
            metadata: .init(
                reason: reason,
                observedAt: now(),
                // A stable provenance lets downstream fusion identify this weak CoreAudio signal.
                source: "CoreAudio.DeviceIsRunningSomewhere"
            )
        ))
    }

    deinit {
        refreshRetryToken = nil
        pendingRetryRequest = nil
        currentEventSink?.invalidate()
        let worker = worker
        executor.execute {
            worker.shutdown(maximumAttempts: 3)
        }
    }
}
