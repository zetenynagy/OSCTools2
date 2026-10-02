import Foundation
import OSCKit

extension OSC {
    nonisolated public func unlisten(id: UUID) { receiver.unlisten(id: id) }

    @discardableResult
    nonisolated public func backgroundListenToMessages(_ callback: @escaping OSCHandlerBlock) -> UUID {
        receiver.backgroundListenToMessages(callback)
    }
    @discardableResult
    nonisolated public func backgroundListenToAll(_ callback: @escaping @Sendable (String, [any OSCValue]) -> Void) -> UUID {
        receiver.backgroundListenToAll(callback)
    }
    @discardableResult
    nonisolated public func backgroundListen<T: OSCType>(to address: @escaping @Sendable () -> String,
                                                        _ callback: @escaping @Sendable (T) -> Void) -> UUID {
        receiver.backgroundListen(to: address, callback)
    }
    @discardableResult
    nonisolated public func backgroundListenToArray<T: OSCType>(to address: @escaping @Sendable () -> String,
                                                               _ callback: @escaping @Sendable ([T]) -> Void) -> UUID {
        receiver.backgroundListenToArray(to: address, callback)
    }
    @discardableResult
    nonisolated public func backgroundListenToAny(to address: @escaping @Sendable () -> String,
                                                _ callback: @escaping @Sendable (any OSCValue) -> Void) -> UUID {
        receiver.backgroundListenToAny(to: address, callback)
    }
    @discardableResult
    nonisolated public func backgroundListenToAnyArray(to address: @escaping @Sendable () -> String,
                                                     _ callback: @escaping @Sendable ([any OSCValue]) -> Void) -> UUID {
        receiver.backgroundListenToAnyArray(to: address, callback)
    }
    @discardableResult
    nonisolated public func backgroundListenToAnyArrayAsync(to address: @escaping @Sendable () async -> String?,
                                                          _ callback: @escaping @Sendable ([any OSCValue]) -> Void) -> UUID {
        receiver.backgroundListenToAnyArrayAsync(to: address, callback)
    }
}
