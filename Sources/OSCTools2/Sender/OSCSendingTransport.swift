import Foundation
import SwiftOSC

protocol OSCSendingTransport: Sendable {
    func start() throws
    func stop()
    func send(_ message: OSCMessage, to endpoint: OSCEndpoint) throws
    func send(_ message: OSCMessage, to endpoint: OSCEndpoint, generation: UInt64) throws
    func setErrorHandler(_ handler: (@Sendable (OSCSendingFailure) -> Void)?)
}

extension OSCSendingTransport {
    func send(_ message: OSCMessage, to endpoint: OSCEndpoint, generation: UInt64) throws {
        try send(message, to: endpoint)
    }
    func setErrorHandler(_ handler: (@Sendable (OSCSendingFailure) -> Void)?) {}
}

struct OSCSendingFailure: Sendable {
    let description: String
    let generation: UInt64?
    let socketClosed: Bool
    init(_ description: String, generation: UInt64? = nil, socketClosed: Bool = false) {
        self.description = description
        self.generation = generation
        self.socketClosed = socketClosed
    }
}
