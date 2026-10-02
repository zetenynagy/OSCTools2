import Darwin
import Foundation
import OSCKit
import Testing
@testable import OSCTools2

private struct ReceiveTimeout: Error {}

private func receive(_ stream: AsyncStream<OSCMessage>, count: Int = 1) async throws -> [OSCMessage] {
    try await withThrowingTaskGroup(of: [OSCMessage].self) { group in
        group.addTask {
            var result: [OSCMessage] = []
            for await message in stream {
                result.append(message)
                if result.count == count { return result }
            }
            throw ReceiveTimeout()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw ReceiveTimeout()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private func freePorts(_ count: Int) throws -> [UInt16] {
    var descriptors: [Int32] = []
    defer { for descriptor in descriptors { Darwin.close(descriptor) } }
    return try (0..<count).map { _ in
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw ProbeError() }
        descriptors.append(descriptor)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let port = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard Darwin.bind(descriptor, $0, size) == 0, getsockname(descriptor, $0, &size) == 0 else { return UInt16(0) }
                return $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            }
        }
        guard port > 0 else { throw ProbeError() }
        return port
    }
}

@Suite("Real UDP loopback", .serialized)
struct OSCLoopbackTests {
    @Test func twoSendersAndTwoReceiversPreserveTypesAndIsolation() async throws {
        let ports = try freePorts(2)
        let first = OSCReceiver(port: ports[0]), second = OSCReceiver(port: ports[1])
        let senderA = OSCSender(), senderB = OSCSender()
        let streamA = AsyncStream<OSCMessage>.makeStream(), streamB = AsyncStream<OSCMessage>.makeStream()
        defer {
            senderA.stop(); senderB.stop(); first.stop(); second.stop()
            streamA.continuation.finish(); streamB.continuation.finish()
        }
        first.backgroundListenToMessages { message, _, _, _ in streamA.continuation.yield(message) }
        second.backgroundListenToMessages { message, _, _, _ in streamB.continuation.yield(message) }
        try first.start(); try second.start(); try senderA.start(); try senderB.start()
        let mixed = OSCMessage.message("/mixed", values: [Int32(-17), Float(0.25), Double.pi, "hello", true, Data([0, 255])])
        try senderA.send(mixed, to: "127.0.0.1", port: ports[0])
        try senderB.send(.message("/empty"), to: "127.0.0.1", port: ports[1])
        async let messagesA = receive(streamA.stream)
        async let messagesB = receive(streamB.stream)
        let (a, b) = try await (messagesA, messagesB)
        let actualData = try a[0].rawData()
        let expectedData = try mixed.rawData()
        #expect(actualData == expectedData)
        #expect(b[0].values.isEmpty)
        first.stop(); senderA.stop()
        try senderB.send(.message("/still-active"), to: "127.0.0.1", port: ports[1])
        let remaining = try await receive(streamB.stream)
        #expect(remaining[0].addressPattern.stringValue == "/still-active")
        #expect(second.isRunning)
    }

    @Test func bindingConflictsAreReportedAndStoppingReleasesPort() async throws {
        let port = try freePorts(1)[0]
        let first = OSCReceiver(port: port), second = OSCReceiver(port: port)
        defer { first.stop(); second.stop() }
        try first.start()
        #expect(!OSC.isPortOpen(Int(port)))
        #expect(throws: (any Error).self) { try second.start() }
        #expect(!second.isRunning)
        first.stop()
        // CocoaAsyncSocket closes descriptors in dispatch-source cancellation handlers.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !OSC.isPortOpen(Int(port)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try second.start()
        #expect(second.isRunning)
    }

    @Test @MainActor func legacySendStillCoercesDoubleAndPortChangesKeepSender() async throws {
        let ports = try freePorts(3)
        let target = OSCReceiver(port: ports[0])
        let stream = AsyncStream<OSCMessage>.makeStream()
        target.backgroundListenToMessages { message, _, _, _ in stream.continuation.yield(message) }
        try target.start()
        let settings = OSCSettings(clientAddress: "127.0.0.1", clientPort: Int(ports[0]), serverPort: Int(ports[1]), persistence: .none)
        let osc = OSC(settings: settings, queue: DispatchQueue(label: "legacy-send"), manageLifecycle: false)
        defer { osc.tearDown(); target.stop(); stream.continuation.finish() }
        let sender = osc.sender
        osc.send(values: [Double.pi], address: "/legacy")
        let received = try await receive(stream.stream)
        #expect(received[0].values[0] is Float)
        try osc.relay(.message("/relay", values: [Double.pi]), to: "127.0.0.1", port: ports[0])
        let relayed = try await receive(stream.stream)
        #expect(relayed[0].values[0] is Double)
        settings.serverPort = Int(ports[2])
        #expect(osc.sender === sender)
        #expect(osc.sender.isRunning)
        #expect(osc.receiver.port == ports[2])
        #expect(osc.lastError == nil)
    }

    @Test @MainActor func changingBusyPortRecoversFacadeWithoutRevivingPause() throws {
        let ports = try freePorts(2)
        let blocker = OSCReceiver(port: ports[0])
        try blocker.start()
        let settings = OSCSettings(serverPort: Int(ports[0]), persistence: .none)
        let osc = OSC(settings: settings, manageLifecycle: false)
        defer { osc.tearDown(); blocker.stop() }
        #expect(osc.lastError != nil)
        #expect(!osc.receiver.isRunning)
        #expect(!osc.sender.isRunning)
        settings.serverPort = Int(ports[1])
        #expect(osc.receiver.isRunning)
        #expect(osc.sender.isRunning)
        #expect(osc.isServerPortOpen)
        #expect(osc.lastError == nil)
        osc.active = false
        settings.serverPort = Int(ports[0])
        #expect(!osc.receiver.isRunning)
        #expect(!osc.sender.isRunning)
        #expect(osc.lastError == nil)
    }
}
