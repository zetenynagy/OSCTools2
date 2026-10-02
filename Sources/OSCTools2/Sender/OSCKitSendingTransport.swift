import Foundation
import OSCKit

struct OSCKitSendingTransport: OSCSendingTransport {
    private let client = OSCClient()
    func start() throws { try client.start() }
    func stop() { client.stop() }
    func send(_ message: OSCMessage, to endpoint: OSCEndpoint) throws {
        try client.send(message, to: endpoint.host, port: endpoint.port)
    }
}
