import Foundation
import OSCKit
import os

/// An independent, thread-safe sender. Start explicitly before sending.
/// Sending serializes synchronously and enqueues UDP output; it does not confirm delivery.
/// All mutable transport state, including lifecycle transitions, is protected by one instance lock.
public final class OSCSender: Sendable {
    private struct State: Sendable {
        let transport: any OSCSendingTransport
        var destination: OSCEndpoint?
        var running = false
        var generation: UInt64 = 0
        var activity: (@Sendable () -> Void)?
    }
    private let state: OSAllocatedUnfairLock<State>

    public convenience init(destination: OSCEndpoint? = nil) {
        self.init(destination: destination, transport: OSCKitSendingTransport())
    }

    init(destination: OSCEndpoint? = nil, transport: any OSCSendingTransport) {
        state = OSAllocatedUnfairLock(initialState: State(transport: transport, destination: destination))
    }

    public var isRunning: Bool { state.withLock { $0.running } }
    public var destination: OSCEndpoint? { state.withLock { $0.destination } }

    public func configure(destination: OSCEndpoint?) {
        state.withLock {
            guard $0.destination != destination else { return }
            $0.destination = destination
            $0.generation &+= 1
        }
    }

    var activeGeneration: UInt64? { state.withLock { $0.running ? $0.generation : nil } }

    func send(values: [any OSCValue], address: String, generation: UInt64) throws {
        try send(.message(address, values: values), overriding: nil, generation: generation)
    }

    public func start() throws {
        try state.withLock {
            guard !$0.running else { return }
            do {
                try $0.transport.start()
                $0.running = true
                $0.generation &+= 1
            } catch {
                $0.transport.stop()
                throw error
            }
        }
    }

    /// Waits for synchronous serialization/enqueueing in progress. Already queued UDP data cannot be recalled.
    public func stop() {
        state.withLock {
            guard $0.running else { return }
            $0.transport.stop()
            $0.running = false
            $0.generation &+= 1
        }
    }

    public func send(_ message: OSCMessage) throws {
        try send(message, overriding: nil)
    }

    /// This destination applies only to this message, leaving the configured destination unchanged.
    public func send(_ message: OSCMessage, to host: String, port: UInt16) throws {
        try send(message, overriding: OSCEndpoint(host: host, port: port))
    }

    public func send(values: [any OSCValue], address: String) throws {
        try send(.message(address, values: values))
    }

    public func send(values: [any OSCValue], address: String, to host: String, port: UInt16) throws {
        try send(.message(address, values: values), to: host, port: port)
    }

    func setActivityHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.activity = handler }
    }

    private func send(_ message: OSCMessage, overriding endpoint: OSCEndpoint?, generation: UInt64? = nil) throws {
        let activity = try state.withLock { state -> (@Sendable () -> Void)? in
            guard state.running, generation == nil || generation == state.generation else { throw OSCTransportError.notRunning }
            guard let destination = endpoint ?? state.destination else { throw OSCTransportError.missingDestination }
            guard destination.host.contains(where: { !$0.isWhitespace }),
                  destination.port > 0 else { throw OSCTransportError.invalidDestination }
            try state.transport.send(message, to: destination)
            return state.activity
        }
        // Callbacks never execute while the transport lock is held.
        activity?()
    }

    deinit { stop() }
}
