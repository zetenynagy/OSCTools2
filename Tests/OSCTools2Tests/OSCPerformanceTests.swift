import Foundation
import SwiftOSC
import XCTest
import os
@testable import OSCTools2

private final class CountingTransport: OSCSendingTransport {
    let count = OSAllocatedUnfairLock(initialState: 0)
    func start() throws {}
    func stop() {}
    func send(_ message: OSCMessage, to endpoint: OSCEndpoint) throws {
        _ = try message.rawData()
        count.withLock { $0 += 1 }
    }
}

final class OSCPerformanceTests: XCTestCase {
    func testDirectSerializationBaseline() {
        let transport = CountingTransport()
        let message = OSCMessage.message("/benchmark", values: [Int32(42), Double.pi, "test"])
        let endpoint = OSCEndpoint(host: "127.0.0.1", port: 9001)
        measure {
            for _ in 0..<10_000 { try! transport.send(message, to: endpoint) }
        }
        XCTAssertGreaterThanOrEqual(transport.count.withLock { $0 }, 100_000)
    }

    func testSenderCoreHotPath() throws {
        let transport = CountingTransport()
        let sender = OSCSender(destination: OSCEndpoint(host: "127.0.0.1", port: 9001), transport: transport)
        try sender.start()
        let message = OSCMessage.message("/benchmark", values: [Int32(42), Double.pi, "test"])
        measure {
            for _ in 0..<10_000 { try! sender.send(message) }
        }
        XCTAssertGreaterThanOrEqual(transport.count.withLock { $0 }, 100_000)
    }
}
