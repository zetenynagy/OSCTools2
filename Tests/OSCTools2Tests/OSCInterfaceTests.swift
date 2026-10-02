import Darwin
import Foundation
import OSCKit
import Testing
import os
@testable import OSCTools2

@Suite("Sender interface configuration")
struct OSCSenderInterfaceTests {
    @Test func originalInitializerReferenceRemainsAvailable() {
        let create: (OSCEndpoint?) -> OSCSender = OSCSender.init(destination:)
        let destination = OSCEndpoint(host: "localhost", port: 9000)
        let sender = create(destination)
        #expect(sender.destination == destination)
        #expect(sender.interface == nil)
        #expect(!sender.isRunning)
    }

    @Test func unchangedInterfaceAndDestinationChangesReuseTransport() throws {
        let factory = InterfaceTransportFactory()
        let sender = OSCSender(destination: OSCEndpoint(host: "localhost", port: 9000),
                               interface: "127.0.0.1", transportFactory: factory.make)
        defer { sender.stop() }
        try sender.start()
        let transport = factory.latest
        let generation = try #require(sender.activeGeneration)
        try sender.configure(interface: "127.0.0.1")
        #expect(sender.activeGeneration == generation)
        sender.configure(destination: OSCEndpoint(host: "localhost", port: 9001))
        try sender.send(.message("/override"), to: "127.0.0.2", port: 9002)
        #expect(factory.latest === transport)
        #expect(transport.state.withLock { $0.starts } == 1)
        #expect(sender.interface == "127.0.0.1")
        #expect(sender.destination?.port == 9001)
        #expect(transport.state.withLock { $0.messages.last?.1.port } == 9002)
    }

    @Test func rebindRejectsQueuedMessagesAndErrorsFromOldTransport() throws {
        let factory = InterfaceTransportFactory()
        let sender = OSCSender(interface: "127.0.0.1", transportFactory: factory.make)
        defer { sender.stop() }
        let errors = OSAllocatedUnfairLock(initialState: [String]())
        sender.setErrorHandler { description, _ in errors.withLock { $0.append(description) } }
        try sender.start()
        let oldGeneration = try #require(sender.activeGeneration)
        let old = factory.latest
        let oldError = try #require(old.state.withLock { $0.errorHandler })
        try sender.configure(interface: nil)
        #expect(sender.isRunning)
        #expect(sender.interface == nil)
        #expect(factory.latest !== old)
        #expect(old.state.withLock { $0.stops } == 1)
        #expect(throws: OSCTransportError.notRunning) {
            try sender.send(values: [], address: "/stale", generation: oldGeneration)
        }
        oldError(OSCSendingFailure("stale socket failure"))
        let currentError = try #require(factory.latest.state.withLock { $0.errorHandler })
        currentError(OSCSendingFailure("current socket failure"))
        #expect(errors.withLock { $0 } == ["current socket failure"])
        sender.stop()
        currentError(OSCSendingFailure("stopped socket failure"))
        #expect(errors.withLock { $0 } == ["current socket failure"])
    }

    @Test func destinationChangesRejectOldPacketErrorsAndSocketCloseStopsSending() throws {
        let factory = InterfaceTransportFactory()
        let sender = OSCSender(destination: OSCEndpoint(host: "localhost", port: 9000),
                               interface: "127.0.0.1", transportFactory: factory.make)
        defer { sender.stop() }
        let errors = OSAllocatedUnfairLock(initialState: [String]())
        sender.setErrorHandler { description, _ in errors.withLock { $0.append(description) } }
        try sender.start()
        let oldGeneration = try #require(sender.activeGeneration)
        sender.configure(destination: OSCEndpoint(host: "localhost", port: 9001))
        let current = factory.latest
        let callback = try #require(current.state.withLock { $0.errorHandler })
        callback(OSCSendingFailure("old packet", generation: oldGeneration))
        #expect(errors.withLock { $0.isEmpty })
        callback(OSCSendingFailure("closed", socketClosed: true))
        #expect(!sender.isRunning)
        #expect(errors.withLock { $0 } == ["closed"])
        #expect(throws: OSCTransportError.notRunning) { try sender.send(.message("/blocked")) }
        try sender.start()
        #expect(sender.isRunning)
        #expect(sender.interface == "127.0.0.1")
        #expect(factory.latest !== current)
    }

    @Test func failedBindingDoesNotFallBackOrRevivePausedSender() throws {
        let factory = InterfaceTransportFactory()
        let sender = OSCSender(transportFactory: factory.make)
        defer { sender.stop() }
        try sender.start()
        #expect(throws: ProbeError.self) { try sender.configure(interface: "unavailable") }
        #expect(!sender.isRunning)
        #expect(sender.interface == "unavailable")
        try sender.configure(interface: nil)
        #expect(!sender.isRunning)
        try sender.start()
        #expect(sender.isRunning)
    }
}

@Suite("Facade interface selection", .serialized) @MainActor
struct OSCInterfaceTests {
    @Test func savedSelectionAndRelayBurstUseOneSourcePort() async throws {
        let ports = try interfaceTestPorts(2)
        let target = OSCReceiver(port: ports[0])
        let packets = AsyncStream<InterfaceDatagram>.makeStream()
        target.backgroundListenToMessages { message, _, host, port in
            packets.continuation.yield(InterfaceDatagram(message: message, host: host, port: port))
        }
        try target.start()
        let connection = OSCConnection(addressProvider: { ["127.0.0.1"] }, monitorsNetwork: false)
        let settings = OSCSettings(clientAddress: "localhost", clientPort: 9000,
                                   serverPort: Int(ports[1]), preferredServerAddress: "127.0.0.1")
        let osc = OSC(settings: settings, manageLifecycle: false, connection: connection)
        defer { osc.tearDown(); target.stop(); packets.continuation.finish() }
        #expect(osc.connection.currentIpAddress == "127.0.0.1")
        #expect(osc.sender.interface == "127.0.0.1")
        for value in 0..<64 {
            try osc.relay(.message("/relay", values: [Int32(value), Double.pi]), to: "127.0.0.1", port: ports[0])
        }
        let received = try await interfaceDatagrams(packets.stream, count: 64)
        #expect(Set(received.map(\.host)) == ["127.0.0.1"])
        #expect(Set(received.map(\.port)).count == 1)
        #expect(received.map { $0.message.values[0] as? Int32 } == (0..<64).map { Int32($0) })
        #expect(received.allSatisfy { $0.message.values[1] is Double })
        #expect(osc.sender.destination?.port == 9000, "Relay overrides must not change the saved destination")
        let generation = osc.sender.activeGeneration
        osc.connection.check()
        osc.didBecomeActive()
        #expect(osc.sender.activeGeneration == generation)
        #expect(osc.lastError == nil)
    }

    @Test func missingIPPausesOnlySendingAndResumesWhenItReturns() async throws {
        let ports = try interfaceTestPorts(2)
        let snapshot = InterfaceAddresses([])
        let connection = OSCConnection(addressProvider: { snapshot.values }, monitorsNetwork: false)
        let settings = OSCSettings(clientAddress: "127.0.0.1", clientPort: Int(ports[0]),
                                   serverPort: Int(ports[1]), preferredServerAddress: "127.0.0.1")
        let osc = OSC(settings: settings, manageLifecycle: false, connection: connection)
        let packets = AsyncStream<InterfaceDatagram>.makeStream()
        let externalSender = OSCSender()
        defer { osc.tearDown(); externalSender.stop(); packets.continuation.finish() }
        osc.receiver.backgroundListenToMessages { message, _, host, port in
            packets.continuation.yield(InterfaceDatagram(message: message, host: host, port: port))
        }
        #expect(osc.receiver.isRunning)
        #expect(osc.isServerPortOpen)
        #expect(!osc.sender.isRunning)
        #expect(osc.connection.currentIpAddress == nil)
        #expect(osc.lastError?.contains("unavailable") == true)
        #expect(throws: OSCTransportError.notRunning) {
            try osc.relay(.message("/blocked"), to: "127.0.0.1", port: ports[0])
        }
        try externalSender.start()
        try externalSender.send(.message("/still-receiving"), to: "127.0.0.1", port: ports[1])
        let received = try await interfaceDatagrams(packets.stream, count: 1)
        #expect(received[0].message.addressPattern.stringValue == "/still-receiving")
        snapshot.values = ["127.0.0.1"]
        osc.connection.check()
        #expect(osc.sender.isRunning)
        #expect(osc.lastError == nil)
        #expect(osc.connection.currentIpAddress == "127.0.0.1")
        snapshot.values = []
        osc.connection.check()
        #expect(!osc.sender.isRunning)
        #expect(osc.receiver.isRunning)
        snapshot.values = ["127.0.0.1"]
        osc.didBecomeActive()
        #expect(osc.sender.isRunning)
        #expect(osc.lastError == nil)
        osc.resetPreferredIPAddress()
        #expect(osc.sender.interface == nil)
        #expect(osc.sender.isRunning)
        #expect(osc.receiver.isRunning)
    }

    @Test func interfaceChangesDoNotRevivePausedFacade() throws {
        let ports = try interfaceTestPorts(1)
        let snapshot = InterfaceAddresses([])
        let connection = OSCConnection(addressProvider: { snapshot.values }, monitorsNetwork: false)
        let settings = OSCSettings(serverPort: Int(ports[0]), preferredServerAddress: "127.0.0.1")
        let osc = OSC(settings: settings, manageLifecycle: false, connection: connection)
        defer { osc.tearDown() }
        osc.active = false
        snapshot.values = ["127.0.0.1"]
        osc.didBecomeActive()
        osc.resetPreferredIPAddress()
        #expect(!osc.sender.isRunning)
        #expect(!osc.receiver.isRunning)
        #expect(osc.sender.interface == nil)
    }

    @Test func sendBindFailureLeavesReceiverRunningAndDefaultRecovers() throws {
        let ports = try interfaceTestPorts(1)
        let connection = OSCConnection(addressProvider: { ["192.0.2.123"] }, monitorsNetwork: false)
        let osc = OSC(settings: OSCSettings(serverPort: Int(ports[0]), preferredServerAddress: "192.0.2.123"),
                      manageLifecycle: false, connection: connection)
        defer { osc.tearDown() }
        #expect(osc.receiver.isRunning)
        #expect(osc.isServerPortOpen)
        #expect(!osc.sender.isRunning)
        #expect(osc.lastError != nil)
        osc.resetPreferredIPAddress()
        #expect(osc.sender.isRunning)
        #expect(osc.lastError == nil)
    }
}

private final class InterfaceTransportFactory: Sendable {
    private let transports = OSAllocatedUnfairLock(initialState: [SenderProbe]())
    func make(_ interface: String?) -> any OSCSendingTransport {
        let probe = SenderProbe()
        probe.state.withLock { $0.failStart = interface == "unavailable" }
        transports.withLock { $0.append(probe) }
        return probe
    }
    var latest: SenderProbe { transports.withLock { $0.last! } }
}

@MainActor private final class InterfaceAddresses {
    var values: [String]
    init(_ values: [String]) { self.values = values }
}

private struct InterfaceDatagram: Sendable {
    let message: OSCMessage
    let host: String
    let port: UInt16
}
private struct InterfaceReceiveTimeout: Error {}

private func interfaceDatagrams(_ stream: AsyncStream<InterfaceDatagram>, count: Int) async throws -> [InterfaceDatagram] {
    try await withThrowingTaskGroup(of: [InterfaceDatagram].self) { group in
        group.addTask {
            var packets: [InterfaceDatagram] = []
            for await packet in stream {
                packets.append(packet)
                if packets.count == count { return packets }
            }
            throw InterfaceReceiveTimeout()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw InterfaceReceiveTimeout()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

private func interfaceTestPorts(_ count: Int) throws -> [UInt16] {
    var descriptors: [Int32] = []
    defer { descriptors.forEach { Darwin.close($0) } }
    return try (0..<count).map { _ in
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        descriptors.append(fd)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard Darwin.bind(fd, $0, length) == 0, getsockname(fd, $0, &length) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }
}
