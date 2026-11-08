import Foundation
import SwiftOSC
import Testing
import os
@testable import OSCTools2

private final class BlockingTransport: OSCSendingTransport {
    let entered = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    func start() throws {}
    func stop() {}
    func send(_ message: OSCMessage, to endpoint: OSCEndpoint) throws {
        entered.signal()
        guard finish.wait(timeout: .now() + 3) == .success else { throw ProbeError() }
    }
}

@Suite("Lifecycle synchronization")
struct OSCLifecycleTests {
    @Test func stopWaitsForSendAndPreventsSubsequentSends() throws {
        let transport = BlockingTransport()
        let sender = OSCSender(destination: OSCEndpoint(host: "localhost", port: 9000), transport: transport)
        try sender.start()
        let sendFinished = DispatchSemaphore(value: 0)
        let stopStarted = DispatchSemaphore(value: 0)
        let stopFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { sendFinished.signal() }
            do { try sender.send(.message("/test")) } catch { Issue.record(error) }
        }
        #expect(transport.entered.wait(timeout: .now() + 3) == .success)
        DispatchQueue.global().async {
            stopStarted.signal()
            sender.stop()
            stopFinished.signal()
        }
        #expect(stopStarted.wait(timeout: .now() + 3) == .success)
        #expect(stopFinished.wait(timeout: .now() + 0.05) == .timedOut)
        transport.finish.signal()
        #expect(sendFinished.wait(timeout: .now() + 3) == .success)
        #expect(stopFinished.wait(timeout: .now() + 3) == .success)
        #expect(throws: OSCTransportError.notRunning) { try sender.send(.message("/after-stop")) }
    }

    @Test func coresReleaseTransportsWithoutRetainCycles() throws {
        let senderProbe = SenderProbe()
        var sender: OSCSender? = OSCSender(transport: senderProbe)
        weak let weakSender = sender
        try sender?.start()
        sender = nil
        #expect(weakSender == nil)
        #expect(senderProbe.state.withLock { $0.stops } == 1)
        let hub = ReceiverHub()
        var receiver: OSCReceiver? = OSCReceiver(port: 9000, transportFactory: hub.make)
        weak let weakReceiver = receiver
        try receiver?.start()
        receiver = nil
        #expect(weakReceiver == nil)
        #expect(!hub.probe().state.withLock { $0.running })
        hub.probe().emit(.message("/after-release"))
    }
}
