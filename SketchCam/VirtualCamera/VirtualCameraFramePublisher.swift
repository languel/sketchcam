import CoreMedia
import CoreMediaIO
import Foundation
import SketchCamShared

final class VirtualCameraFramePublisher {
    enum Status: Equatable {
        case disconnected
        case notFound
        case ready
        case publishing
        case failed(String)

        var displayText: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .notFound: return "SketchCam sink not found"
            case .ready: return "Ready"
            case .publishing: return "Publishing"
            case let .failed(message): return "Failed: \(message)"
            }
        }
    }

    private var deviceID: CMIODeviceID = 0
    private var streamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private(set) var status: Status = .disconnected

    deinit {
        disconnect()
    }

    func publish(_ sampleBuffer: CMSampleBuffer) {
        if queue == nil {
            connect()
        }
        guard let queue else { return }
        while CMSimpleQueueGetCount(queue) >= CMSimpleQueueGetCapacity(queue), CMSimpleQueueGetCapacity(queue) > 0 {
            _ = CMSimpleQueueDequeue(queue)
        }

        let retained = Unmanaged.passRetained(sampleBuffer)
        let enqueueStatus = CMSimpleQueueEnqueue(queue, element: retained.toOpaque())
        if enqueueStatus == noErr {
            status = .publishing
        } else {
            retained.release()
            status = .failed("enqueue \(enqueueStatus)")
            disconnect()
        }
    }

    func connect() {
        do {
            let device = try Self.findDevice(named: "SketchCam")
            let sink = try Self.findSinkStream(on: device)
            var unmanagedQueue: Unmanaged<CMSimpleQueue>?
            // CMIOStreamCopyBufferQueue hands back a NULL queue (with noErr)
            // when no queue-altered callback is supplied.
            let queueAlteredProc: CMIODeviceStreamQueueAlteredProc = { _, _, _ in }
            let copyStatus = CMIOStreamCopyBufferQueue(sink, queueAlteredProc, nil, &unmanagedQueue)
            guard copyStatus == noErr, let unmanagedQueue else {
                status = .failed("queue \(copyStatus)")
                return
            }
            let copiedQueue = unmanagedQueue.takeRetainedValue()
            let startStatus = CMIODeviceStartStream(device, sink)
            guard startStatus == noErr else {
                status = .failed("start \(startStatus)")
                return
            }
            self.deviceID = device
            self.streamID = sink
            self.queue = copiedQueue
            status = .ready
        } catch PublisherError.deviceNotFound {
            status = .notFound
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        if deviceID != 0, streamID != 0 {
            _ = CMIODeviceStopStream(deviceID, streamID)
        }
        queue = nil
        deviceID = 0
        streamID = 0
        status = .disconnected
    }

    private static func findDevice(named targetName: String) throws -> CMIODeviceID {
            let devices: [CMIODeviceID] = try readObjectArray(
            objectID: CMIOObjectID(kCMIOObjectSystemObject),
            selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)
        )
        for device in devices {
            if let name = try? readCFString(objectID: device, selector: CMIOObjectPropertySelector(kCMIOObjectPropertyName)),
               name == targetName {
                return device
            }
        }
        throw PublisherError.deviceNotFound
    }

    private static func findSinkStream(on device: CMIODeviceID) throws -> CMIOStreamID {
        let streams: [CMIOStreamID] = try readObjectArray(objectID: device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
        for stream in streams {
            let direction: UInt32 = try readScalar(objectID: stream, selector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection))
            if direction == 0 {
                return stream
            }
        }
        throw PublisherError.sinkStreamNotFound
    }

    private static func propertyAddress(selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private static func readObjectArray<T>(objectID: CMIOObjectID, selector: CMIOObjectPropertySelector) throws -> [T] {
        var address = propertyAddress(selector: selector)
        var dataSize: UInt32 = 0
        var status = CMIOObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
        guard status == noErr else { throw PublisherError.property(status) }
        let count = Int(dataSize) / MemoryLayout<T>.stride
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        var dataUsed: UInt32 = 0
        status = CMIOObjectGetPropertyData(objectID, &address, 0, nil, dataSize, &dataUsed, pointer)
        guard status == noErr else { throw PublisherError.property(status) }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private static func readScalar<T>(objectID: CMIOObjectID, selector: CMIOObjectPropertySelector) throws -> T {
        var address = propertyAddress(selector: selector)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        let dataSize = UInt32(MemoryLayout<T>.stride)
        var dataUsed: UInt32 = 0
        let status = CMIOObjectGetPropertyData(objectID, &address, 0, nil, dataSize, &dataUsed, pointer)
        guard status == noErr else { throw PublisherError.property(status) }
        return pointer.pointee
    }

    private static func readCFString(objectID: CMIOObjectID, selector: CMIOObjectPropertySelector) throws -> String {
        var address = propertyAddress(selector: selector)
        var value: CFString?
        let dataSize = UInt32(MemoryLayout<CFString?>.stride)
        var dataUsed: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(objectID, &address, 0, nil, dataSize, &dataUsed, $0)
        }
        guard status == noErr, let value else { throw PublisherError.property(status) }
        return value as String
    }
}

private enum PublisherError: Error, LocalizedError {
    case deviceNotFound
    case sinkStreamNotFound
    case property(OSStatus)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "SketchCam virtual camera is not installed or active."
        case .sinkStreamNotFound:
            return "SketchCam virtual camera did not expose a sink stream."
        case let .property(status):
            return "CoreMediaIO property read failed: \(status)"
        }
    }
}
