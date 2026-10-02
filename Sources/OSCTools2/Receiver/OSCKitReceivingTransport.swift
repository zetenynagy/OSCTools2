import Foundation
import OSCKit

struct OSCKitReceivingTransport: OSCReceivingTransport {
    private let server: OSCServer
    init(port: UInt16, queue: DispatchQueue, handler: @escaping OSCHandlerBlock) {
        server = OSCServer(port: port, receiveQueue: queue, handler: handler)
    }
    func start() throws { try server.start() }
    func stop() { server.stop() }
}
