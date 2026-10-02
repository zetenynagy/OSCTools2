import Foundation
import OSCKit

protocol OSCReceivingTransport: Sendable {
    func start() throws
    func stop()
}
