import Foundation
import OSCKit
import os
@testable import OSCTools2

struct ProbeError: Error {}

final class SenderProbe: OSCSendingTransport {
    struct State {
        var starts = 0
        var stops = 0
        var messages: [(OSCMessage, OSCEndpoint)] = []
        var fail = false
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    func start() throws { state.withLock { $0.starts += 1 } }
    func stop() { state.withLock { $0.stops += 1 } }
    func send(_ message: OSCMessage, to endpoint: OSCEndpoint) throws {
        try state.withLock {
            if $0.fail { throw ProbeError() }
            _ = try message.rawData()
            $0.messages.append((message, endpoint))
        }
    }
}

final class ReceiverProbe: OSCReceivingTransport {
    let handler: OSCHandlerBlock
    let state = OSAllocatedUnfairLock(initialState: (running: false, fail: false))
    init(handler: @escaping OSCHandlerBlock) { self.handler = handler }
    func start() throws {
        try state.withLock {
            if $0.fail { throw ProbeError() }
            $0.running = true
        }
    }
    func stop() { state.withLock { $0.running = false } }
    func emit(_ message: OSCMessage) { handler(message, .immediate(), "127.0.0.1", 9999) }
}

final class ReceiverHub: Sendable {
    let probes = OSAllocatedUnfairLock(initialState: [ReceiverProbe]())
    func make(_ port: UInt16, _ queue: DispatchQueue, _ handler: @escaping OSCHandlerBlock) -> any OSCReceivingTransport {
        let probe = ReceiverProbe(handler: handler)
        probes.withLock { $0.append(probe) }
        return probe
    }
    func probe(_ index: Int = 0) -> ReceiverProbe { probes.withLock { $0[index] } }
}
