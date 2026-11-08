import Foundation
import SwiftOSC
import os

/// An independent, thread-safe receiver with explicit lifecycle and ordered message delivery.
/// No settings persistence, app notifications, or observable UI state is attached to this core.
public final class OSCReceiver: Sendable {
    typealias TransportFactory = @Sendable (UInt16, DispatchQueue, @escaping OSCHandlerBlock) -> any OSCReceivingTransport
    private struct Listener: Sendable {
        let id: UUID
        let callback: @Sendable (OSCMessage, OSCTimeTag, String, UInt16, UInt64) -> Void
    }
    private struct State: Sendable {
        var port: UInt16
        var transport: (any OSCReceivingTransport)?
        var generation: UInt64 = 0
        var listeners: [Listener] = []
        var activity: (@Sendable () -> Void)?
    }
    private let state: OSAllocatedUnfairLock<State>
    private let receiveQueue: DispatchQueue
    private let transportFactory: TransportFactory

    /// The supplied queue is a target for a private serial queue, preserving order even for concurrent targets.
    public convenience init(port: UInt16, receiveQueue: DispatchQueue? = nil) {
        self.init(port: port, receiveQueue: receiveQueue) { port, queue, handler in
            OSCKitReceivingTransport(port: port, queue: queue, handler: handler)
        }
    }

    init(port: UInt16, receiveQueue: DispatchQueue? = nil, transportFactory: @escaping TransportFactory) {
        state = OSAllocatedUnfairLock(initialState: State(port: port))
        self.receiveQueue = DispatchQueue(label: "OSCTools2.OSCReceiver.\(UUID())", target: receiveQueue)
        self.transportFactory = transportFactory
    }

    public var port: UInt16 { state.withLock { $0.port } }
    public var isRunning: Bool { state.withLock { $0.transport != nil } }

    public func start() throws {
        try state.withLock { state in
            guard state.transport == nil else { return }
            try startLocked(&state)
        }
    }

    /// Invalidates pending deliveries. Callbacks already selected for a delivery may finish.
    /// The underlying socket closes asynchronously; immediate rebinding can report a port conflict.
    public func stop() {
        state.withLock {
            $0.generation &+= 1
            $0.transport?.stop()
            $0.transport = nil
        }
    }

    /// Retains listeners and the stopped/running state. A bind failure leaves the receiver stopped.
    public func configure(port: UInt16) throws {
        guard port > 0 else { throw OSCTransportError.invalidPort }
        try state.withLock { state in
            guard state.port != port else { return }
            let wasRunning = state.transport != nil
            state.generation &+= 1
            state.transport?.stop()
            state.transport = nil
            state.port = port
            if wasRunning { try startLocked(&state) }
        }
    }

    @discardableResult
    public func backgroundListenToMessages(_ callback: @escaping OSCHandlerBlock) -> UUID {
        let id = UUID()
        state.withLock { $0.listeners.append(Listener(id: id, callback: { message, timeTag, host, port, _ in callback(message, timeTag, host, port) })) }
        return id
    }

    /// A listener already selected for the current message may finish after removal.
    public func unlisten(id: UUID) {
        state.withLock { $0.listeners.removeAll { $0.id == id } }
    }

    func addAsyncListener(id: UUID, address: @escaping @Sendable () async -> String?,
                          callback: @escaping @Sendable ([any OSCValue]) -> Void) {
        let listener = Listener(id: id) { [weak self] message, _, _, _, generation in
            Task {
                guard let target = await address(), Self.matches(message.addressPattern.stringValue, target: target),
                      let self else { return }
                let valid = self.state.withLock {
                    $0.transport != nil && $0.generation == generation && $0.listeners.contains { $0.id == id }
                }
                if valid { callback(message.values) }
            }
        }
        state.withLock { $0.listeners.append(listener) }
    }

    func setActivityHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.activity = handler }
    }

    private func startLocked(_ state: inout State) throws {
        guard state.port > 0 else { throw OSCTransportError.invalidPort }
        state.generation &+= 1
        let generation = state.generation
        let transport = transportFactory(state.port, receiveQueue) { [weak self] message, timeTag, host, port in
            self?.deliver(message, timeTag: timeTag, host: host, port: port, generation: generation)
        }
        do {
            try transport.start()
            state.transport = transport
        } catch {
            transport.stop()
            throw error
        }
    }

    private func deliver(_ message: OSCMessage, timeTag: OSCTimeTag, host: String, port: UInt16, generation: UInt64) {
        let delivery = state.withLock { state -> ([Listener], (@Sendable () -> Void)?)? in
            guard state.transport != nil, state.generation == generation else { return nil }
            // Array storage is shared until subscription changes; no per-message callback-array allocation.
            return (state.listeners, state.activity)
        }
        guard let (listeners, activity) = delivery else { return }
        for listener in listeners { listener.callback(message, timeTag, host, port, generation) }
        activity?()
    }

    deinit { stop() }
}
