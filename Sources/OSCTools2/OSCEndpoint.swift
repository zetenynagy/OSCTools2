import Foundation

/// A destination for UDP OSC messages. Configuration and persistence belong to the caller.
public struct OSCEndpoint: Equatable, Hashable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}
