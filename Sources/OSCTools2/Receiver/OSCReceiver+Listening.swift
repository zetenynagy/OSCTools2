import Foundation
import OSCKit

extension OSCReceiver {
    @discardableResult
    public func backgroundListenToAll(_ callback: @escaping @Sendable (String, [any OSCValue]) -> Void) -> UUID {
        backgroundListenToMessages { message, _, _, _ in
            callback(message.addressPattern.stringValue, message.values)
        }
    }

    @discardableResult
    public func backgroundListen<T: OSCType>(to address: @escaping @Sendable () -> String,
                                             _ callback: @escaping @Sendable (T) -> Void) -> UUID {
        backgroundListenToAny(to: address) { callback(T.convert(value: $0)) }
    }

    @discardableResult
    public func backgroundListenToArray<T: OSCType>(to address: @escaping @Sendable () -> String,
                                                    _ callback: @escaping @Sendable ([T]) -> Void) -> UUID {
        backgroundListenToAnyArray(to: address) { callback($0.map { T.convert(value: $0) }) }
    }

    @discardableResult
    public func backgroundListenToAny(to address: @escaping @Sendable () -> String,
                                     _ callback: @escaping @Sendable (any OSCValue) -> Void) -> UUID {
        backgroundListenToAnyArray(to: address) { values in
            guard let value = values.first else { return }
            callback(value)
        }
    }

    @discardableResult
    public func backgroundListenToAnyArray(to address: @escaping @Sendable () -> String,
                                          _ callback: @escaping @Sendable ([any OSCValue]) -> Void) -> UUID {
        backgroundListenToAll { receivedAddress, values in
            guard Self.matches(receivedAddress, target: address()) else { return }
            callback(values)
        }
    }

    /// Resolving an async address may reorder deliveries. The synchronous listeners preserve receive order.
    @discardableResult
    public func backgroundListenToAnyArrayAsync(to address: @escaping @Sendable () async -> String?,
                                               _ callback: @escaping @Sendable ([any OSCValue]) -> Void) -> UUID {
        let id = UUID()
        addAsyncListener(id: id, address: address, callback: callback)
        return id
    }

    /// Whether a received address matches a local address. Preserves the legacy direction where
    /// wildcards in the received address match the local address, including '*' across path separators.
    public static func matches(_ source: String, target: String) -> Bool {
        if source == target { return true }
        guard source.contains("*") else { return false }
        let source = Array(source), target = Array(target)
        var sourceIndex = 0, targetIndex = 0
        var star: Int?, retry = 0
        while targetIndex < target.count {
            if sourceIndex < source.count, source[sourceIndex] == target[targetIndex] {
                sourceIndex += 1; targetIndex += 1
            } else if sourceIndex < source.count, source[sourceIndex] == "*" {
                star = sourceIndex; sourceIndex += 1; retry = targetIndex
            } else if let star {
                sourceIndex = star + 1; retry += 1; targetIndex = retry
            } else { return false }
        }
        while sourceIndex < source.count, source[sourceIndex] == "*" { sourceIndex += 1 }
        return sourceIndex == source.count
    }
}
