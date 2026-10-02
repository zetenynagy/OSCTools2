import Foundation
import OSCKit

protocol OSCSendingTransport: Sendable {
    func start() throws
    func stop()
    func send(_ message: OSCMessage, to endpoint: OSCEndpoint) throws
}
