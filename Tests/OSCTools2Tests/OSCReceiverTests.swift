import Foundation
import SwiftOSC
import Testing
import os
@testable import OSCTools2

@Suite("Independent receivers")
struct OSCReceiverTests {
    @Test func preservesOrderAndMessageMetadata() throws {
        let hub = ReceiverHub()
        let receiver = OSCReceiver(port: 9000, transportFactory: hub.make)
        let values = OSAllocatedUnfairLock(initialState: [Int32]())
        receiver.backgroundListenToMessages { message, _, host, port in
            #expect(host == "127.0.0.1")
            #expect(port == 9999)
            values.withLock { $0.append(message.values[0] as! Int32) }
        }
        try receiver.start()
        for value in 0..<1000 { hub.probe().emit(.message("/test", values: [Int32(value)])) }
        #expect(values.withLock { $0 } == (0..<1000).map(Int32.init))
    }

    @Test func removalFromCallbackAndTypedFiltering() throws {
        let hub = ReceiverHub()
        let receiver = OSCReceiver(port: 9000, transportFactory: hub.make)
        let received = OSAllocatedUnfairLock(initialState: [Int]())
        let identifier = OSAllocatedUnfairLock<UUID?>(initialState: nil)
        let id = receiver.backgroundListen(to: { "/test/foo" }) { (value: Int) in
            received.withLock { $0.append(value) }
            if let id = identifier.withLock({ $0 }) { receiver.unlisten(id: id) }
        }
        identifier.withLock { $0 = id }
        try receiver.start()
        hub.probe().emit(.message("/other", values: [Int32(1)]))
        hub.probe().emit(.message("/test/*", values: [Int32(2)]))
        hub.probe().emit(.message("/test/foo", values: [Int32(3)]))
        #expect(received.withLock { $0 } == [2])
    }

    @Test func reconfigurationRejectsOldCallbacksAndKeepsListeners() throws {
        let hub = ReceiverHub()
        let receiver = OSCReceiver(port: 9000, transportFactory: hub.make)
        let received = OSAllocatedUnfairLock(initialState: [String]())
        receiver.backgroundListenToAll { address, _ in received.withLock { $0.append(address) } }
        try receiver.start()
        let old = hub.probe()
        try receiver.configure(port: 9002)
        old.emit(.message("/stale"))
        hub.probe(1).emit(.message("/new"))
        receiver.stop()
        hub.probe(1).emit(.message("/stopped"))
        try receiver.start()
        hub.probe(2).emit(.message("/restarted"))
        #expect(received.withLock { $0 } == ["/new", "/restarted"])
        #expect(receiver.port == 9002)
    }

    @Test func independentReceiversAndConcurrentRegistration() throws {
        let firstHub = ReceiverHub(), secondHub = ReceiverHub()
        let first = OSCReceiver(port: 9000, transportFactory: firstHub.make)
        let second = OSCReceiver(port: 9001, transportFactory: secondHub.make)
        let firstCount = OSAllocatedUnfairLock(initialState: 0)
        let count = OSAllocatedUnfairLock(initialState: 0)
        first.backgroundListenToAll { _, _ in firstCount.withLock { $0 += 1 } }
        second.backgroundListenToAll { _, _ in count.withLock { $0 += 1 } }
        try first.start()
        try second.start()
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            let id = first.backgroundListenToAll { _, _ in }
            firstHub.probe().emit(.message("/concurrent"))
            first.unlisten(id: id)
        }
        #expect(firstCount.withLock { $0 } == 1000)
        first.stop()
        secondHub.probe().emit(.message("/still-running"))
        #expect(second.isRunning)
        #expect(count.withLock { $0 } == 1)
    }

    @Test func startFailureIsReported() {
        let receiver = OSCReceiver(port: 9000, transportFactory: { _, _, handler in
            let probe = ReceiverProbe(handler: handler)
            probe.state.withLock { $0.fail = true }
            return probe
        })
        #expect(throws: ProbeError.self) { try receiver.start() }
        #expect(!receiver.isRunning)
        #expect(throws: OSCTransportError.invalidPort) { try OSCReceiver(port: 0).start() }
    }

    @Test(arguments: [true, false])
    func suspendedAsyncListenersDiscardResults(removeListener: Bool) async throws {
        let hub = ReceiverHub()
        let receiver = OSCReceiver(port: 9000, transportFactory: hub.make)
        let requested = AsyncStream<Void>.makeStream()
        let answers = AsyncStream<String>.makeStream()
        let deliveries = AsyncStream<[any OSCValue]>.makeStream()
        defer {
            receiver.stop()
            requested.continuation.finish()
            answers.continuation.finish()
            deliveries.continuation.finish()
        }
        let id = receiver.backgroundListenToAnyArrayAsync(to: {
            requested.continuation.yield(())
            var iterator = answers.stream.makeAsyncIterator()
            return await iterator.next()
        }) { deliveries.continuation.yield($0) }
        try receiver.start()
        hub.probe().emit(.message("/test", values: [Int32(1)]))
        var requests = requested.stream.makeAsyncIterator()
        _ = try #require(await requests.next())
        if removeListener {
            receiver.unlisten(id: id)
        } else {
            receiver.stop()
            try receiver.start()
        }
        // Resolve only after removal/restart, observing a bounded window for unwanted callbacks.
        answers.continuation.yield("/test")
        let delivered = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = deliveries.stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(100))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(!delivered)
    }
}
