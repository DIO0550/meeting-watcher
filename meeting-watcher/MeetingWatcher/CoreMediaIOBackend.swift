import CoreMediaIO
import Dispatch
import Foundation

nonisolated struct CameraDeviceID: RawRepresentable, Hashable, Comparable, Sendable {
    let rawValue: CMIODeviceID

    init(rawValue: CMIODeviceID) {
        self.rawValue = rawValue
    }

    static func < (lhs: CameraDeviceID, rhs: CameraDeviceID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated enum CoreMediaIOTypedConstants {
    // CoreMediaIO imports these legacy C constants as Int. Convert once at the API boundary.
    static let systemObjectID: CMIOObjectID = CMIOObjectID(kCMIOObjectSystemObject)
    static let deviceListSelector: CMIOObjectPropertySelector = CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)
    static let cameraStreamsSelector: CMIOObjectPropertySelector = CMIOObjectPropertySelector(kCMIODevicePropertyStreams)
    static let runningSelector: CMIOObjectPropertySelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
    static let globalScope: CMIOObjectPropertyScope = CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal)
    static let inputScope: CMIOObjectPropertyScope = CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput)
    static let mainElement: CMIOObjectPropertyElement = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
}

nonisolated struct CoreMediaIOPropertyAddress: Equatable, Hashable, Sendable {
    let selector: CMIOObjectPropertySelector
    let scope: CMIOObjectPropertyScope
    let element: CMIOObjectPropertyElement
}

nonisolated enum CoreMediaIOOperation: String, Equatable, Sendable {
    case enumerateDevices
    case inspectCameraStreams
    case readRunningState
    case observeDeviceList
    case observeRunningState
    case removeListener
}

nonisolated enum CoreMediaIOError: Error, Equatable, Sendable, CustomStringConvertible {
    case osStatus(operation: CoreMediaIOOperation, status: Int32)
    case invalidPropertyData(operation: CoreMediaIOOperation)

    var description: String {
        switch self {
        case let .osStatus(operation, status):
            return "CoreMediaIO \(operation.rawValue) failed with OSStatus \(status)"
        case let .invalidPropertyData(operation):
            return "CoreMediaIO \(operation.rawValue) returned invalid property data"
        }
    }
}

nonisolated enum CoreMediaIOStatus {
    static func check(_ status: OSStatus, operation: CoreMediaIOOperation) throws {
        guard status == noErr else {
            throw CoreMediaIOError.osStatus(operation: operation, status: status)
        }
    }
}

nonisolated protocol CoreMediaIOListenerRegistration: AnyObject, Sendable {
    func invalidate()
    func cancel() throws
}

nonisolated protocol CoreMediaIOCallbackScheduling: Sendable {
    func schedule(_ work: @escaping @MainActor @Sendable () -> Void)
}

nonisolated final class TaskCoreMediaIOCallbackScheduler: CoreMediaIOCallbackScheduling, @unchecked Sendable {
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

nonisolated protocol CoreMediaIOBackend: AnyObject, Sendable {
    typealias ChangeHandler = @MainActor @Sendable () -> Void

    func cameraDeviceIDs() throws -> [CameraDeviceID]
    func isRunningSomewhere(deviceID: CameraDeviceID) throws -> Bool

    func observeDeviceListChanges(
        _ handler: @escaping ChangeHandler
    ) throws -> any CoreMediaIOListenerRegistration

    func observeRunningStateChanges(
        deviceID: CameraDeviceID,
        _ handler: @escaping ChangeHandler
    ) throws -> any CoreMediaIOListenerRegistration
}

nonisolated final class CoreMediaIOPropertyListener: @unchecked Sendable {
    let block: CMIOObjectPropertyListenerBlock

    init(block: @escaping CMIOObjectPropertyListenerBlock) {
        self.block = block
    }
}

nonisolated protocol CoreMediaIOHAL: AnyObject, Sendable {
    func hasProperty(objectID: CMIOObjectID, address: CoreMediaIOPropertyAddress) -> Bool

    func propertyDataSize(
        objectID: CMIOObjectID,
        address: CoreMediaIOPropertyAddress,
        dataSize: inout UInt32
    ) -> OSStatus

    func propertyData(
        objectID: CMIOObjectID,
        address: CoreMediaIOPropertyAddress,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus

    func addPropertyListener(
        objectID: CMIOObjectID,
        address: CoreMediaIOPropertyAddress,
        queue: DispatchQueue,
        listener: CoreMediaIOPropertyListener
    ) -> OSStatus

    func removePropertyListener(
        objectID: CMIOObjectID,
        address: CoreMediaIOPropertyAddress,
        queue: DispatchQueue,
        listener: CoreMediaIOPropertyListener
    ) -> OSStatus
}

typealias CoreMediaIOGetPropertyData = @Sendable (
    CMIOObjectID,
    UnsafePointer<CMIOObjectPropertyAddress>,
    UInt32,
    UnsafeRawPointer?,
    UInt32,
    UnsafeMutablePointer<UInt32>,
    UnsafeMutableRawPointer
) -> OSStatus

nonisolated final class SystemCoreMediaIOHAL: CoreMediaIOHAL, @unchecked Sendable {
    private let getPropertyData: CoreMediaIOGetPropertyData

    init(
        getPropertyData: @escaping CoreMediaIOGetPropertyData = {
            objectID, address, qualifierDataSize, qualifierData, dataSize, dataUsed, data in
            CMIOObjectGetPropertyData(
                objectID,
                address,
                qualifierDataSize,
                qualifierData,
                dataSize,
                dataUsed,
                data
            )
        }
    ) {
        self.getPropertyData = getPropertyData
    }

    func hasProperty(objectID: CMIOObjectID, address: CoreMediaIOPropertyAddress) -> Bool {
        var rawAddress = address.rawValue
        return CMIOObjectHasProperty(objectID, &rawAddress)
    }

    func propertyDataSize(
        objectID: CMIOObjectID,
        address: CoreMediaIOPropertyAddress,
        dataSize: inout UInt32
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return CMIOObjectGetPropertyDataSize(objectID, &rawAddress, 0, nil, &dataSize)
    }

    func propertyData(
        objectID: CMIOObjectID,
        address: CoreMediaIOPropertyAddress,
        dataSize: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        var rawAddress = address.rawValue
        let availableDataSize = dataSize
        return getPropertyData(
            objectID,
            &rawAddress,
            0,
            nil,
            availableDataSize,
            &dataSize,
            data
        )
    }

    func addPropertyListener(
        objectID: CMIOObjectID,
        address: CoreMediaIOPropertyAddress,
        queue: DispatchQueue,
        listener: CoreMediaIOPropertyListener
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return CMIOObjectAddPropertyListenerBlock(objectID, &rawAddress, queue, listener.block)
    }

    func removePropertyListener(
        objectID: CMIOObjectID,
        address: CoreMediaIOPropertyAddress,
        queue: DispatchQueue,
        listener: CoreMediaIOPropertyListener
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return CMIOObjectRemovePropertyListenerBlock(objectID, &rawAddress, queue, listener.block)
    }
}

nonisolated private final class CoreMediaIOHALResultBox<Value>: @unchecked Sendable {
    var value: Value?
}

nonisolated private final class CoreMediaIOHALExecutionContext: @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()

    // This private serial HAL context runs same-context reentry inline. Production calls this blocking
    // bridge off MainActor: monitoring enters from SerialCoreMediaIOAsyncExecutor, while residual
    // registration.cancel cleanup enters from DispatchCoreMediaIOCleanupRetryScheduler.

    init() {
        queue = DispatchQueue(label: "MeetingWatcher.CoreMediaIOHAL")
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        queue.setSpecific(key: queueKey, value: nil)
    }

    func execute<Value: Sendable>(_ work: @escaping @Sendable () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: queueKey) == true { return work() }
        let box = CoreMediaIOHALResultBox<Value>()
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
        let box = CoreMediaIOHALResultBox<Result<Value, any Error>>()
        let completed = DispatchSemaphore(value: 0)
        queue.async {
            box.value = Result { try work() }
            completed.signal()
        }
        completed.wait()
        return try box.value!.get()
    }
}

nonisolated final class SystemCoreMediaIOBackend: CoreMediaIOBackend, @unchecked Sendable {
    private let hal: any CoreMediaIOHAL
    // Do not depend on a generic actor executor choosing a non-main OS thread for HAL calls.
    private let halExecutionContext: CoreMediaIOHALExecutionContext
    private let listenerQueue: DispatchQueue
    private let callbackScheduler: any CoreMediaIOCallbackScheduling

    init(
        hal: any CoreMediaIOHAL = SystemCoreMediaIOHAL(),
        listenerQueue: DispatchQueue = .main,
        callbackScheduler: any CoreMediaIOCallbackScheduling = TaskCoreMediaIOCallbackScheduler()
    ) {
        self.hal = hal
        halExecutionContext = CoreMediaIOHALExecutionContext()
        self.listenerQueue = listenerQueue
        self.callbackScheduler = callbackScheduler
    }

    func cameraDeviceIDs() throws -> [CameraDeviceID] {
        try halExecutionContext.executeThrowing {
            try allDeviceIDs().filter(hasCameraInputStreams).map { CameraDeviceID(rawValue: $0) }
        }
    }

    func isRunningSomewhere(deviceID: CameraDeviceID) throws -> Bool {
        try halExecutionContext.executeThrowing {
            let address = CoreMediaIOPropertyAddress.runningState
            var running: UInt32 = 0
            var dataSize = UInt32(MemoryLayout<UInt32>.size)
            let status = withUnsafeMutablePointer(to: &running) { pointer in
                hal.propertyData(
                    objectID: deviceID.rawValue,
                    address: address,
                    dataSize: &dataSize,
                    data: UnsafeMutableRawPointer(pointer)
                )
            }
            try CoreMediaIOStatus.check(status, operation: .readRunningState)
            guard dataSize == UInt32(MemoryLayout<UInt32>.size) else {
                throw CoreMediaIOError.invalidPropertyData(operation: .readRunningState)
            }
            return running != 0
        }
    }

    func observeDeviceListChanges(
        _ handler: @escaping ChangeHandler
    ) throws -> any CoreMediaIOListenerRegistration {
        try halExecutionContext.executeThrowing {
            try addListener(
                objectID: CoreMediaIOTypedConstants.systemObjectID,
                address: .deviceList,
                operation: .observeDeviceList,
                handler: handler
            )
        }
    }

    func observeRunningStateChanges(
        deviceID: CameraDeviceID,
        _ handler: @escaping ChangeHandler
    ) throws -> any CoreMediaIOListenerRegistration {
        try halExecutionContext.executeThrowing {
            try addListener(
                objectID: deviceID.rawValue,
                address: .runningState,
                operation: .observeRunningState,
                handler: handler
            )
        }
    }

    private func allDeviceIDs() throws -> [CMIODeviceID] {
        let address = CoreMediaIOPropertyAddress.deviceList
        var dataSize: UInt32 = 0
        let sizeStatus = hal.propertyDataSize(
            objectID: CoreMediaIOTypedConstants.systemObjectID,
            address: address,
            dataSize: &dataSize
        )
        try CoreMediaIOStatus.check(sizeStatus, operation: .enumerateDevices)
        guard dataSize % UInt32(MemoryLayout<CMIODeviceID>.size) == 0 else {
            throw CoreMediaIOError.invalidPropertyData(operation: .enumerateDevices)
        }

        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        guard count > 0 else {
            return []
        }

        var deviceIDs = [CMIODeviceID](repeating: 0, count: count)
        var returnedSize = dataSize
        let dataStatus = deviceIDs.withUnsafeMutableBytes { buffer in
            hal.propertyData(
                objectID: CoreMediaIOTypedConstants.systemObjectID,
                address: address,
                dataSize: &returnedSize,
                data: buffer.baseAddress!
            )
        }
        try CoreMediaIOStatus.check(dataStatus, operation: .enumerateDevices)
        guard returnedSize <= dataSize,
              returnedSize % UInt32(MemoryLayout<CMIODeviceID>.size) == 0 else {
            throw CoreMediaIOError.invalidPropertyData(operation: .enumerateDevices)
        }
        return Array(deviceIDs.prefix(Int(returnedSize) / MemoryLayout<CMIODeviceID>.size))
    }

    private func hasCameraInputStreams(deviceID: CMIODeviceID) throws -> Bool {
        let address = CoreMediaIOPropertyAddress.cameraInputStreams
        guard hal.hasProperty(objectID: deviceID, address: address) else {
            return false
        }

        var dataSize: UInt32 = 0
        let status = hal.propertyDataSize(objectID: deviceID, address: address, dataSize: &dataSize)
        try CoreMediaIOStatus.check(status, operation: .inspectCameraStreams)
        guard dataSize % UInt32(MemoryLayout<CMIOStreamID>.size) == 0 else {
            throw CoreMediaIOError.invalidPropertyData(operation: .inspectCameraStreams)
        }
        return dataSize > 0
    }

    private func addListener(
        objectID: CMIOObjectID,
        address: CoreMediaIOPropertyAddress,
        operation: CoreMediaIOOperation,
        handler: @escaping ChangeHandler
    ) throws -> any CoreMediaIOListenerRegistration {
        let gate = CoreMediaIOCallbackGate(scheduler: callbackScheduler, handler: handler)
        let block: CMIOObjectPropertyListenerBlock = { _, _ in
            gate.invoke()
        }
        let listener = CoreMediaIOPropertyListener(block: block)
        let status = hal.addPropertyListener(
            objectID: objectID,
            address: address,
            queue: listenerQueue,
            listener: listener
        )
        do {
            try CoreMediaIOStatus.check(status, operation: operation)
        } catch {
            gate.invalidate()
            throw error
        }
        return SystemCoreMediaIOListenerRegistration(
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

nonisolated private extension CoreMediaIOPropertyAddress {
    static let deviceList = CoreMediaIOPropertyAddress(
        selector: CoreMediaIOTypedConstants.deviceListSelector,
        scope: CoreMediaIOTypedConstants.globalScope,
        element: CoreMediaIOTypedConstants.mainElement
    )

    static let cameraInputStreams = CoreMediaIOPropertyAddress(
        selector: CoreMediaIOTypedConstants.cameraStreamsSelector,
        scope: CoreMediaIOTypedConstants.inputScope,
        element: CoreMediaIOTypedConstants.mainElement
    )

    static let runningState = CoreMediaIOPropertyAddress(
        selector: CoreMediaIOTypedConstants.runningSelector,
        scope: CoreMediaIOTypedConstants.globalScope,
        element: CoreMediaIOTypedConstants.mainElement
    )

    var rawValue: CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}

nonisolated private final class CoreMediaIOCallbackGate: @unchecked Sendable {
    private let scheduler: any CoreMediaIOCallbackScheduling
    private let lock = NSLock()
    private var handler: (@MainActor @Sendable () -> Void)?
    private var isScheduled = false

    init(
        scheduler: any CoreMediaIOCallbackScheduling,
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

nonisolated private final class SystemCoreMediaIOListenerRegistration: CoreMediaIOListenerRegistration, @unchecked Sendable {
    private let hal: any CoreMediaIOHAL
    private let halExecutionContext: CoreMediaIOHALExecutionContext
    private let objectID: CMIOObjectID
    private let address: CoreMediaIOPropertyAddress
    private let queue: DispatchQueue
    private let listener: CoreMediaIOPropertyListener
    private let callbackGate: CoreMediaIOCallbackGate
    // Accessed only while executing on halExecutionContext.
    private var isCancelled = false
    private var isRemoving = false

    init(
        hal: any CoreMediaIOHAL,
        halExecutionContext: CoreMediaIOHALExecutionContext,
        objectID: CMIOObjectID,
        address: CoreMediaIOPropertyAddress,
        queue: DispatchQueue,
        listener: CoreMediaIOPropertyListener,
        callbackGate: CoreMediaIOCallbackGate
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
            try CoreMediaIOStatus.check(status, operation: .removeListener)
            isCancelled = true
        }
    }

    deinit {
        invalidate()
        try? cancel()
    }
}
