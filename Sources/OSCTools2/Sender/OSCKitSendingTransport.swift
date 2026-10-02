import Foundation
import OSCKit
import CocoaAsyncSocket
import os

struct OSCKitSendingTransport: OSCSendingTransport {
    // The Objective-C socket never escapes this lock. Descriptor access occurs
    // only in its synchronous perform block on the socket's own queue.
    private let socket = OSAllocatedUnfairLock(uncheckedState: GCDAsyncUdpSocket())
    private let delegate = SendingSocketDelegate()
    private let interface: String?

    init(interface: String? = nil) {
        self.interface = interface
        let delegate = self.delegate
        socket.withLock { $0.setDelegate(delegate, delegateQueue: DispatchQueue(label: "OSCTools2.sender.callbacks")) }
    }

    func start() throws {
        try socket.withLock { socket in
            // Preserve OSCClient's existing broadcast-send policy.
            try socket.enableBroadcast(false)
            try socket.bind(toPort: 0, interface: interface)
            if let interface {
                guard var index = OSCConnection.interfaceIndex(for: interface) else {
                    throw POSIXError(.EADDRNOTAVAIL)
                }
                // Source-address binding alone does not constrain routing on iOS.
                // Discover the interface rather than assuming a name such as en0.
                var failure: POSIXError?
                let descriptorSocket = socket
                socket.perform {
                    if setsockopt(descriptorSocket.socket4FD(), IPPROTO_IP, IP_BOUND_IF,
                                  &index, socklen_t(MemoryLayout<UInt32>.size)) != 0 {
                        failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
                if let failure { throw failure }
            }
        }
    }

    func stop() { socket.withLock { $0.close() } }

    func send(_ message: OSCMessage, to endpoint: OSCEndpoint) throws {
        try send(message, to: endpoint, generation: 0)
    }

    func send(_ message: OSCMessage, to endpoint: OSCEndpoint, generation: UInt64) throws {
        let data = try message.rawData()
        socket.withLock {
            $0.send(data, toHost: endpoint.host, port: endpoint.port, withTimeout: 1,
                    tag: Int(truncatingIfNeeded: generation))
        }
    }

    func setErrorHandler(_ handler: (@Sendable (OSCSendingFailure) -> Void)?) { delegate.handler.withLock { $0 = handler } }
}

// CocoaAsyncSocket calls this on its delegate queue. Mutable callback state is
// protected independently; callbacks never run under either sender/socket lock.
private final class SendingSocketDelegate: NSObject, GCDAsyncUdpSocketDelegate, Sendable {
    let handler = OSAllocatedUnfairLock<(@Sendable (OSCSendingFailure) -> Void)?>(initialState: nil)
    func udpSocket(_ sock: GCDAsyncUdpSocket, didNotSendDataWithTag tag: Int, dueToError error: Error?) {
        report(OSCSendingFailure(error?.localizedDescription ?? "UDP socket rejected the packet.",
                                 generation: UInt64(truncatingIfNeeded: tag)))
    }
    func udpSocketDidClose(_ sock: GCDAsyncUdpSocket, withError error: Error?) {
        report(OSCSendingFailure(error?.localizedDescription ?? "UDP socket closed.", socketClosed: true))
    }
    private func report(_ failure: OSCSendingFailure) {
        let callback = handler.withLock { $0 }
        callback?(failure)
    }
}
