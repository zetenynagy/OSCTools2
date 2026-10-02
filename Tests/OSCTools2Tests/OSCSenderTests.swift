import Foundation
import OSCKit
import Testing
import os
@testable import OSCTools2

@Suite("Independent senders")
struct OSCSenderTests {
    let endpoint = OSCEndpoint(host: "127.0.0.1", port: 9001)

    @Test func explicitLifecycleAndIdempotentStart() throws {
        let probe = SenderProbe()
        let sender = OSCSender(destination: endpoint, transport: probe)
        #expect(!sender.isRunning)
        #expect(throws: OSCTransportError.notRunning) { try sender.send(.message("/test")) }
        try sender.start()
        try sender.start()
        try sender.send(.message("/test"))
        sender.stop()
        sender.stop()
        #expect(throws: OSCTransportError.notRunning) { try sender.send(.message("/test")) }
        #expect(probe.state.withLock { $0.starts } == 1)
        #expect(probe.state.withLock { $0.messages.count } == 1)
    }

    @Test func preservesMixedValuesAndEmptyMessage() throws {
        let probe = SenderProbe()
        let sender = OSCSender(destination: endpoint, transport: probe)
        try sender.start()
        let mixed = OSCMessage.message("/mixed", values: [Int32(-1), Float(0.5), Double.pi, "hello", true, Data([0, 255])])
        try sender.send(mixed)
        try sender.send(values: [], address: "/empty")
        let messages = probe.state.withLock { $0.messages.map(\.0) }
        let actualData = try messages[0].rawData()
        let expectedData = try mixed.rawData()
        #expect(actualData == expectedData)
        #expect(messages[0].values[2] is Double)
        #expect(messages[1].values.isEmpty)
    }

    @Test func overridesDoNotChangeConfiguredDestination() throws {
        let probe = SenderProbe()
        let sender = OSCSender(destination: endpoint, transport: probe)
        try sender.start()
        try sender.send(.message("/override"), to: "127.0.0.2", port: 9002)
        try sender.send(.message("/configured"))
        #expect(probe.state.withLock { $0.messages.map(\.1.port) } == [9002, 9001])
        sender.configure(destination: OSCEndpoint(host: "127.0.0.3", port: 9003))
        try sender.send(.message("/new"))
        #expect(probe.state.withLock { $0.messages.last?.1.port } == 9003)
    }

    @Test func errorsArePropagatedAndDestinationsValidated() throws {
        let probe = SenderProbe()
        let sender = OSCSender(transport: probe)
        try sender.start()
        #expect(throws: OSCTransportError.missingDestination) { try sender.send(.message("/test")) }
        #expect(throws: OSCTransportError.invalidDestination) { try sender.send(.message("/test"), to: "", port: 9001) }
        #expect(throws: OSCTransportError.invalidDestination) { try sender.send(.message("/test"), to: "localhost", port: 0) }
        probe.state.withLock { $0.fail = true }
        #expect(throws: ProbeError.self) { try sender.send(.message("/test"), to: endpoint.host, port: endpoint.port) }
    }

    @Test func independentSendersAndConcurrentCalls() throws {
        let probes = (0..<4).map { _ in SenderProbe() }
        let senders = probes.enumerated().map { OSCSender(destination: OSCEndpoint(host: "localhost", port: UInt16(9000 + $0.offset)), transport: $0.element) }
        for sender in senders { try sender.start() }
        let failures = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            do { try senders[index % 4].send(.message("/burst", values: [Int32(index)])) }
            catch { failures.withLock { $0 += 1 } }
        }
        #expect(failures.withLock { $0 } == 0)
        #expect(probes.map { $0.state.withLock { $0.messages.count } } == [250, 250, 250, 250])
        senders[0].stop()
        let stillRunning = senders.dropFirst().allSatisfy { $0.isRunning }
        #expect(stillRunning)
    }
    @Test func queuedSendsAreInvalidatedByPauseAndReconfiguration() throws {
        let probe = SenderProbe()
        let sender = OSCSender(destination: endpoint, transport: probe)
        try sender.start()
        let original = try #require(sender.activeGeneration)
        sender.stop()
        try sender.start()
        #expect(throws: OSCTransportError.notRunning) {
            try sender.send(values: [], address: "/old-session", generation: original)
        }
        let restarted = try #require(sender.activeGeneration)
        sender.configure(destination: OSCEndpoint(host: "localhost", port: 9002))
        #expect(throws: OSCTransportError.notRunning) {
            try sender.send(values: [], address: "/old-destination", generation: restarted)
        }
        try sender.send(.message("/current"))
        #expect(probe.state.withLock { $0.messages.count } == 1)
    }

}
