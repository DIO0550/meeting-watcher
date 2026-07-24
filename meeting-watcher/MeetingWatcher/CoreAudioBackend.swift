import CoreAudio
import Dispatch
import Foundation

nonisolated struct AudioInputDeviceID: RawRepresentable, Hashable, Comparable, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static func < (lhs: AudioInputDeviceID, rhs: AudioInputDeviceID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct CoreAudioPropertyAddress: Equatable, Hashable, Sendable {
    let selector: UInt32
    let scope: UInt32
    let element: UInt32
}

nonisolated enum CoreAudioOperation: String, Equatable, Sendable {
    case enumerateDevices
    case inspectInputStreams
    case readRunningState
    case observeDeviceList
    case observeRunningState
    case removeListener
}

nonisolated enum CoreAudioError: Error, Equatable, Sendable, CustomStringConvertible {
    case osStatus(operation: CoreAudioOperation, status: Int32)
    case invalidPropertyData(operation: CoreAudioOperation)

    var description: String {
        switch self {
        case let .osStatus(operation, status):
            return "CoreAudio \(operation.rawValue) failed with OSStatus \(status)"
        case let .invalidPropertyData(operation):
            return "CoreAudio \(operation.rawValue) returned invalid property data"
        }
    }
}

nonisolated enum CoreAudioStatus {
    static func check(_ status: OSStatus, operation: CoreAudioOperation) throws {
        guard status == noErr else {
            throw CoreAudioError.osStatus(operation: operation, status: status)
        }
    }
}

nonisolated protocol CoreAudioListenerRegistration: AnyObject, Sendable {
    func invalidate()
    func cancel() throws
}

nonisolated protocol CoreAudioCallbackScheduling: Sendable {
    func schedule(_ work: @escaping @MainActor @Sendable () -> Void)
}

nonisolated final class TaskCoreAudioCallbackScheduler: CoreAudioCallbackScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingWorkCount = 0

    var retainedTaskCount: Int { pendingCount() }

    func schedule(_ work: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        pendingWorkCount += 1
        lock.unlock()

        // The scheduler tracks activity only; completed Task closures are never retained.
        _ = Task { @MainActor [self] in
            work()
            markCompleted()
        }
    }

    func drain() async {
        var observedIdle = false
        while true {
            let isIdle = pendingCount() == 0
            if isIdle, observedIdle { return }
            observedIdle = isIdle
            await Task.yield()
        }
    }

    private func markCompleted() {
        lock.lock()
        precondition(pendingWorkCount > 0)
        pendingWorkCount -= 1
        lock.unlock()
    }

    private func pendingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingWorkCount
    }
}

nonisolated protocol CoreAudioBackend: AnyObject, Sendable {
    typealias ChangeHandler = @MainActor @Sendable () -> Void

    func inputDeviceIDs() throws -> [AudioInputDeviceID]
    func isRunningSomewhere(deviceID: AudioInputDeviceID) throws -> Bool

    func observeDeviceListChanges(
        _ handler: @escaping ChangeHandler
    ) throws -> any CoreAudioListenerRegistration

    func observeRunningStateChanges(
        deviceID: AudioInputDeviceID,
        _ handler: @escaping ChangeHandler
    ) throws -> any CoreAudioListenerRegistration
}

nonisolated final class CoreAudioPropertyListener: @unchecked Sendable {
    let block: AudioObjectPropertyListenerBlock

    init(block: @escaping AudioObjectPropertyListenerBlock) {
        self.block = block
    }
}

nonisolated protocol CoreAudioHAL: AnyObject, Sendable {
    func hasProperty(objectID: AudioObjectID, address: CoreAudioPropertyAddress) -> Bool

    func propertyDataSize(
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress,
        dataSize: inout UInt32
    ) -> OSStatus

    func propertyData(
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus

    func addPropertyListener(
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListener
    ) -> OSStatus

    func removePropertyListener(
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListener
    ) -> OSStatus
}

nonisolated final class SystemCoreAudioHAL: CoreAudioHAL, @unchecked Sendable {
    func hasProperty(objectID: AudioObjectID, address: CoreAudioPropertyAddress) -> Bool {
        var rawAddress = address.rawValue
        return AudioObjectHasProperty(objectID, &rawAddress)
    }

    func propertyDataSize(
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress,
        dataSize: inout UInt32
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectGetPropertyDataSize(objectID, &rawAddress, 0, nil, &dataSize)
    }

    func propertyData(
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectGetPropertyData(objectID, &rawAddress, 0, nil, &dataSize, data)
    }

    func addPropertyListener(
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListener
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectAddPropertyListenerBlock(objectID, &rawAddress, queue, listener.block)
    }

    func removePropertyListener(
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListener
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectRemovePropertyListenerBlock(objectID, &rawAddress, queue, listener.block)
    }
}

nonisolated private final class CoreAudioHALResultBox<Value>: @unchecked Sendable {
    var value: Value?
}

nonisolated private final class CoreAudioHALExecutionContext: @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()

    // This private serial HAL context runs same-context reentry inline. Production calls this blocking
    // bridge off MainActor: monitoring enters from SerialCoreAudioAsyncExecutor, while residual
    // registration.cancel cleanup enters from DispatchCoreAudioCleanupRetryScheduler.

    init() {
        queue = DispatchQueue(label: "MeetingWatcher.CoreAudioHAL")
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        queue.setSpecific(key: queueKey, value: nil)
    }

    func execute<Value: Sendable>(_ work: @escaping @Sendable () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: queueKey) == true { return work() }
        let box = CoreAudioHALResultBox<Value>()
        let completed = DispatchSemaphore(value: 0)
        queue.async {
            box.value = work()
            completed.signal()
        }
        completed.wait()
        return box.value!
    }

    func executeThrowing<Value: Sendable>(
        _ work: @escaping @Sendable () throws -> Value
    ) throws -> Value {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try work() }
        let box = CoreAudioHALResultBox<Result<Value, any Error>>()
        let completed = DispatchSemaphore(value: 0)
        queue.async {
            box.value = Result { try work() }
            completed.signal()
        }
        completed.wait()
        return try box.value!.get()
    }
}

nonisolated final class SystemCoreAudioBackend: CoreAudioBackend, @unchecked Sendable {
    private let hal: any CoreAudioHAL
    // Do not depend on a generic actor executor choosing a non-main OS thread for HAL calls.
    private let halExecutionContext: CoreAudioHALExecutionContext
    private let listenerQueue: DispatchQueue
    private let callbackScheduler: any CoreAudioCallbackScheduling

    init(
        hal: any CoreAudioHAL = SystemCoreAudioHAL(),
        listenerQueue: DispatchQueue = .main,
        callbackScheduler: any CoreAudioCallbackScheduling = TaskCoreAudioCallbackScheduler()
    ) {
        self.hal = hal
        halExecutionContext = CoreAudioHALExecutionContext()
        self.listenerQueue = listenerQueue
        self.callbackScheduler = callbackScheduler
    }

    func inputDeviceIDs() throws -> [AudioInputDeviceID] {
        try halExecutionContext.executeThrowing {
            try allDeviceIDs().filter(hasInputStreams).map { AudioInputDeviceID(rawValue: $0) }
        }
    }

    func isRunningSomewhere(deviceID: AudioInputDeviceID) throws -> Bool {
        try halExecutionContext.executeThrowing {
            let address = CoreAudioPropertyAddress.runningState
            var running: UInt32 = 0
            var dataSize = UInt32(MemoryLayout<UInt32>.size)
            let status = withUnsafeMutablePointer(to: &running) { pointer in
                hal.propertyData(
                    objectID: AudioDeviceID(deviceID.rawValue),
                    address: address,
                    dataSize: &dataSize,
                    data: UnsafeMutableRawPointer(pointer)
                )
            }
            try CoreAudioStatus.check(status, operation: .readRunningState)
            guard dataSize == UInt32(MemoryLayout<UInt32>.size) else {
                throw CoreAudioError.invalidPropertyData(operation: .readRunningState)
            }
            return running != 0
        }
    }

    func observeDeviceListChanges(
        _ handler: @escaping ChangeHandler
    ) throws -> any CoreAudioListenerRegistration {
        try halExecutionContext.executeThrowing {
            try addListener(
                objectID: kAudioObjectSystemObject,
                address: .deviceList,
                operation: .observeDeviceList,
                handler: handler
            )
        }
    }

    func observeRunningStateChanges(
        deviceID: AudioInputDeviceID,
        _ handler: @escaping ChangeHandler
    ) throws -> any CoreAudioListenerRegistration {
        try halExecutionContext.executeThrowing {
            try addListener(
                objectID: AudioDeviceID(deviceID.rawValue),
                address: .runningState,
                operation: .observeRunningState,
                handler: handler
            )
        }
    }

    private func allDeviceIDs() throws -> [AudioDeviceID] {
        let address = CoreAudioPropertyAddress.deviceList
        var dataSize: UInt32 = 0
        let sizeStatus = hal.propertyDataSize(
            objectID: kAudioObjectSystemObject,
            address: address,
            dataSize: &dataSize
        )
        try CoreAudioStatus.check(sizeStatus, operation: .enumerateDevices)
        guard dataSize % UInt32(MemoryLayout<AudioDeviceID>.size) == 0 else {
            throw CoreAudioError.invalidPropertyData(operation: .enumerateDevices)
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else {
            return []
        }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        var returnedSize = dataSize
        let dataStatus = deviceIDs.withUnsafeMutableBytes { buffer in
            hal.propertyData(
                objectID: kAudioObjectSystemObject,
                address: address,
                dataSize: &returnedSize,
                data: buffer.baseAddress!
            )
        }
        try CoreAudioStatus.check(dataStatus, operation: .enumerateDevices)
        guard returnedSize <= dataSize,
              returnedSize % UInt32(MemoryLayout<AudioDeviceID>.size) == 0 else {
            throw CoreAudioError.invalidPropertyData(operation: .enumerateDevices)
        }
        return Array(deviceIDs.prefix(Int(returnedSize) / MemoryLayout<AudioDeviceID>.size))
    }

    private func hasInputStreams(deviceID: AudioDeviceID) throws -> Bool {
        let address = CoreAudioPropertyAddress.inputStreams
        guard hal.hasProperty(objectID: deviceID, address: address) else {
            return false
        }

        var dataSize: UInt32 = 0
        let status = hal.propertyDataSize(objectID: deviceID, address: address, dataSize: &dataSize)
        try CoreAudioStatus.check(status, operation: .inspectInputStreams)
        guard dataSize % UInt32(MemoryLayout<AudioStreamID>.size) == 0 else {
            throw CoreAudioError.invalidPropertyData(operation: .inspectInputStreams)
        }
        return dataSize > 0
    }

    private func addListener(
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress,
        operation: CoreAudioOperation,
        handler: @escaping ChangeHandler
    ) throws -> any CoreAudioListenerRegistration {
        let gate = CoreAudioCallbackGate(scheduler: callbackScheduler, handler: handler)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            gate.invoke()
        }
        let listener = CoreAudioPropertyListener(block: block)
        let status = hal.addPropertyListener(
            objectID: objectID,
            address: address,
            queue: listenerQueue,
            listener: listener
        )
        do {
            try CoreAudioStatus.check(status, operation: operation)
        } catch {
            gate.invalidate()
            throw error
        }
        return SystemCoreAudioListenerRegistration(
            hal: hal,
            halExecutionContext: halExecutionContext,
            objectID: objectID,
            address: address,
            queue: listenerQueue,
            listener: listener,
            callbackGate: gate
        )
    }
}

nonisolated private extension CoreAudioPropertyAddress {
    static let deviceList = CoreAudioPropertyAddress(
        selector: kAudioHardwarePropertyDevices,
        scope: kAudioObjectPropertyScopeGlobal,
        element: kAudioObjectPropertyElementMain
    )

    static let inputStreams = CoreAudioPropertyAddress(
        selector: kAudioDevicePropertyStreams,
        scope: kAudioDevicePropertyScopeInput,
        element: kAudioObjectPropertyElementMain
    )

    static let runningState = CoreAudioPropertyAddress(
        selector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        scope: kAudioObjectPropertyScopeGlobal,
        element: kAudioObjectPropertyElementMain
    )

    var rawValue: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}

nonisolated private final class CoreAudioCallbackGate: @unchecked Sendable {
    private let scheduler: any CoreAudioCallbackScheduling
    private let lock = NSLock()
    private var handler: (@MainActor @Sendable () -> Void)?
    private var isScheduled = false

    init(
        scheduler: any CoreAudioCallbackScheduling,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        self.scheduler = scheduler
        self.handler = handler
    }

    func invoke() {
        lock.lock()
        guard handler != nil, !isScheduled else {
            lock.unlock()
            return
        }
        isScheduled = true
        lock.unlock()

        scheduler.schedule { [weak self] in
            self?.deliver()
        }
    }

    func invalidate() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    @MainActor
    private func deliver() {
        lock.lock()
        let currentHandler = handler
        isScheduled = false
        lock.unlock()
        currentHandler?()
    }
}

nonisolated private final class SystemCoreAudioListenerRegistration: CoreAudioListenerRegistration, @unchecked Sendable {
    private let hal: any CoreAudioHAL
    private let halExecutionContext: CoreAudioHALExecutionContext
    private let objectID: AudioObjectID
    private let address: CoreAudioPropertyAddress
    private let queue: DispatchQueue
    private let listener: CoreAudioPropertyListener
    private let callbackGate: CoreAudioCallbackGate
    // Accessed only while executing on halExecutionContext.
    private var isCancelled = false
    private var isRemoving = false

    init(
        hal: any CoreAudioHAL,
        halExecutionContext: CoreAudioHALExecutionContext,
        objectID: AudioObjectID,
        address: CoreAudioPropertyAddress,
        queue: DispatchQueue,
        listener: CoreAudioPropertyListener,
        callbackGate: CoreAudioCallbackGate
    ) {
        self.hal = hal
        self.halExecutionContext = halExecutionContext
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.listener = listener
        self.callbackGate = callbackGate
    }

    func invalidate() {
        callbackGate.invalidate()
    }

    func cancel() throws {
        callbackGate.invalidate()
        try halExecutionContext.executeThrowing {
            if isCancelled || isRemoving { return }
            isRemoving = true
            defer { isRemoving = false }
            let status = hal.removePropertyListener(
                objectID: objectID,
                address: address,
                queue: queue,
                listener: listener
            )
            try CoreAudioStatus.check(status, operation: .removeListener)
            isCancelled = true
        }
    }

    deinit {
        invalidate()
        try? cancel()
    }
}
