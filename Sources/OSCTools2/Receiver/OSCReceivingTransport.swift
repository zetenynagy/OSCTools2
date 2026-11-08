import Foundation
import SwiftOSC

protocol OSCReceivingTransport: Sendable {
    func start() throws
    func stop()
}
