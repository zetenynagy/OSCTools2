import Foundation
import Observation

/// Observable settings for the OSC facade. Standalone transports never persist settings.
@MainActor @Observable
public class OSCSettings {
    public enum Persistence {
        case none
        /// A nil namespace retains the keys used by previous OSCTools2 releases.
        case userDefaults(UserDefaults, namespace: String?)
    }
    enum Change { case clientAddress, clientPort, serverPort, preferredServerAddress }

    nonisolated public static let kDefaultClientAddress = "localhost"
    nonisolated public static let kDefaultClientPort = 8000
    nonisolated public static let kDefaultServerPort = 7000

    @ObservationIgnored private let persistence: Persistence
    @ObservationIgnored private var observers: [UUID: (Change) -> Void] = [:]

    public var clientAddress: String {
        didSet { persist(clientAddress, key: "setting-client-address"); notify(.clientAddress) }
    }
    public var preferredServerAddress: String? {
        didSet { persist(preferredServerAddress, key: "setting-preferred-server-address"); notify(.preferredServerAddress) }
    }
    public var clientPort: Int {
        didSet { persist(clientPort, key: "setting-client-port"); notify(.clientPort) }
    }
    public var serverPort: Int {
        didSet { persist(serverPort, key: "setting-server-port"); notify(.serverPort) }
    }

    /// Existing apps retain their saved configuration without changing OSC().
    public convenience init() {
        self.init(persistence: .userDefaults(.standard, namespace: nil))
    }

    /// Explicitly constructed settings default to in-memory storage for independent instances.
    public init(clientAddress: String = kDefaultClientAddress,
                clientPort: Int = kDefaultClientPort,
                serverPort: Int = kDefaultServerPort,
                preferredServerAddress: String? = nil,
                persistence: Persistence = .none) {
        self.persistence = persistence
        if case let .userDefaults(defaults, namespace) = persistence {
            func key(_ key: String) -> String { namespace.map { "\($0).\(key)" } ?? key }
            self.clientAddress = defaults.string(forKey: key("setting-client-address")) ?? clientAddress
            let savedClientPort = defaults.integer(forKey: key("setting-client-port"))
            self.clientPort = savedClientPort == 0 ? clientPort : savedClientPort
            let savedServerPort = defaults.integer(forKey: key("setting-server-port"))
            self.serverPort = savedServerPort == 0 ? serverPort : savedServerPort
            self.preferredServerAddress = defaults.string(forKey: key("setting-preferred-server-address")) ?? preferredServerAddress
        } else {
            self.clientAddress = clientAddress
            self.clientPort = clientPort
            self.serverPort = serverPort
            self.preferredServerAddress = preferredServerAddress
        }
    }

    func observe(_ callback: @escaping (Change) -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func notify(_ change: Change) {
        for callback in observers.values { callback(change) }
    }
    private func persist(_ value: Any?, key: String) {
        guard case let .userDefaults(defaults, namespace) = persistence else { return }
        defaults.set(value, forKey: namespace.map { "\($0).\(key)" } ?? key)
    }
}
