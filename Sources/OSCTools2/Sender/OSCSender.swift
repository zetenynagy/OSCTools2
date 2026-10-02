import Foundation
import OSCKit
import os

/// An independent, thread-safe sender. Start explicitly before sending.
/// Sending serializes synchronously and enqueues UDP output; it does not confirm delivery.
/// All mutable transport state, including lifecycle transitions, is protected by one instance lock.
public final class OSCSender: Sendable {
    private struct State: Sendable {
        var transport: any OSCSendingTransport
        let transportFactory: @Sendable (String?) -> any OSCSendingTransport
        var destination: OSCEndpoint?
        var interface: String?
        var running = false
        var generation: UInt64 = 0
        var activity: (@Sendable () -> Void)?
        var errorHandler: (@Sendable (String, UInt64) -> Void)?
    }
    private let state: OSAllocatedUnfairLock<State>

    public convenience init(destination: OSCEndpoint? = nil) {
        self.init(destination: destination, interface: nil)
    }

    /// A nil interface retains system routing. Supply a local IPv4 address to
    /// constrain output; destination overrides still use this same interface.
    public convenience init(destination: OSCEndpoint? = nil, interface: String?) {
        self.init(destination: destination, interface: interface,
                  transportFactory: { OSCKitSendingTransport(interface: $0) })
    }

    convenience init(destination: OSCEndpoint? = nil, transport: any OSCSendingTransport) {
        self.init(destination: destination, transportFactory: { _ in transport })
    }

    init(destination: OSCEndpoint? = nil, interface: String? = nil,
         transportFactory: @escaping @Sendable (String?) -> any OSCSendingTransport) {
        state = OSAllocatedUnfairLock(initialState: State(
            transport: transportFactory(interface), transportFactory: transportFactory,
            destination: destination, interface: interface))
    }

    public var isRunning: Bool { state.withLock { $0.running } }
    public var destination: OSCEndpoint? { state.withLock { $0.destination } }
    public var interface: String? { state.withLock { $0.interface } }

    public func configure(destination: OSCEndpoint?) {
        state.withLock {
            guard $0.destination != destination else { return }
            $0.destination = destination
            $0.generation &+= 1
            installErrorHandler(in: &$0)
        }
    }

    /// Rebind only when the explicit local IPv4 address changes. A failed bind
    /// leaves this sender stopped, without falling back to another interface.
    public func configure(interface: String?) throws {
        try state.withLock { state in
            guard state.interface != interface else { return }
            let wasRunning = state.running
            state.transport.setErrorHandler(nil)
            state.transport.stop()
            state.running = false
            state.generation &+= 1
            state.interface = interface
            if wasRunning { try start(state: &state) }
        }
    }

    var activeGeneration: UInt64? { state.withLock { $0.running ? $0.generation : nil } }
    func matchesGeneration(_ generation: UInt64) -> Bool { state.withLock { $0.generation == generation } }

    func send(values: [any OSCValue], address: String, generation: UInt64) throws {
        try send(.message(address, values: values), overriding: nil, generation: generation)
    }

    public func start() throws {
        try state.withLock { try start(state: &$0) }
    }

    private func start(state: inout State) throws {
        guard !state.running else { return }
        // A fresh transport prevents close callbacks from a stopped socket
        // sharing state with a restarted socket. Messages reuse it until then.
        state.transport = state.transportFactory(state.interface)
        state.generation &+= 1
        installErrorHandler(in: &state)
        do {
            try state.transport.start()
            state.running = true
        } catch {
            state.transport.setErrorHandler(nil)
            state.transport.stop()
            throw error
        }
    }

    /// Waits for synchronous serialization/enqueueing in progress. Already queued UDP data cannot be recalled.
    public func stop() {
        state.withLock {
            // Invalidate pending error publications even after a socket failure
            // has already stopped output.
            $0.generation &+= 1
            guard $0.running else { return }
            $0.transport.setErrorHandler(nil)
            $0.transport.stop()
            $0.running = false
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

    func setErrorHandler(_ handler: (@Sendable (String, UInt64) -> Void)?) {
        state.withLock { $0.errorHandler = handler }
    }

    private func installErrorHandler(in state: inout State) {
        let transportGeneration = state.generation
        state.transport.setErrorHandler { [weak self] failure in
            guard let self else { return }
            let generation = failure.generation ?? transportGeneration
            let callback = self.state.withLock { state -> (@Sendable (String, UInt64) -> Void)? in
                guard state.running, state.generation == generation else { return nil }
                if failure.socketClosed {
                    // A closed socket must not reopen implicitly without its
                    // explicit bind. Restart creates and binds a fresh transport.
                    state.transport.setErrorHandler(nil)
                    state.transport.stop()
                    state.running = false
                }
                return state.errorHandler
            }
            callback?(failure.description, generation)
        }
    }

    private func send(_ message: OSCMessage, overriding endpoint: OSCEndpoint?, generation: UInt64? = nil) throws {
        let activity = try state.withLock { state -> (@Sendable () -> Void)? in
            guard state.running, generation == nil || generation == state.generation else { throw OSCTransportError.notRunning }
            guard let destination = endpoint ?? state.destination else { throw OSCTransportError.missingDestination }
            guard destination.host.contains(where: { !$0.isWhitespace }),
                  destination.port > 0 else { throw OSCTransportError.invalidDestination }
            try state.transport.send(message, to: destination, generation: state.generation)
            return state.activity
        }
        // Callbacks never execute while the transport lock is held.
        activity?()
    }

    deinit { stop() }
}
