import Foundation

public enum OSCTransportError: Error, Equatable, LocalizedError {
    case notRunning
    case missingDestination
    case invalidDestination
    case invalidPort

    public var errorDescription: String? {
        switch self {
        case .notRunning: "The OSC transport is stopped."
        case .missingDestination: "Configure an OSC destination or supply one when sending."
        case .invalidDestination: "Enter a destination host and a port from 1 to 65535."
        case .invalidPort: "Enter a receive port from 1 to 65535."
        }
    }
}
