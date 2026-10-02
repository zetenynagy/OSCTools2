import SwiftUI
import OSCKit
import os

/// App-facing facade. Settings and UI state are main-actor isolated; the transport cores are Sendable.
@MainActor @Observable
public class OSC {
    nonisolated public let sender: OSCSender
    nonisolated public let receiver: OSCReceiver
    public let connection: OSCConnection
    public let settings: OSCSettings

    @ObservationIgnored nonisolated private let queue: DispatchQueue
    @ObservationIgnored nonisolated private let pending = OSAllocatedUnfairLock(initialState: (input: false, output: false, errorGeneration: UInt64?.none))
    @ObservationIgnored private let localNetworkAuthorization = LocalNetworkAuthorization()
    @ObservationIgnored private var settingsObserver: UUID?
    @ObservationIgnored private var observingLifecycle = false
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var isTornDown = false
    @ObservationIgnored private var sendingInterfaceAvailable = true
    @ObservationIgnored private var recentInputTimer: Timer?
    @ObservationIgnored private var recentOutputTimer: Timer?

    public private(set) var isServerPortOpen = false
    public private(set) var lastError: String?
    public private(set) var recentInput = false
    public private(set) var recentOutput = false
    public var updateRecentInput = false {
        didSet {
            if updateRecentInput {
                receiver.setActivityHandler { [weak self] in self?.recordActivity(input: true) }
            } else { receiver.setActivityHandler(nil) }
        }
    }
    public var updateRecentOutput = false {
        didSet {
            if updateRecentOutput {
                sender.setActivityHandler { [weak self] in self?.recordActivity(input: false) }
            } else { sender.setActivityHandler(nil) }
        }
    }
    public var active = true {
        didSet {
            guard active != oldValue else { return }
            if active { start() } else { stop() }
        }
    }

    public convenience init(queue: DispatchQueue = .main) {
        self.init(settings: OSCSettings(), queue: queue)
    }

    /// Supply separate settings for independent OSC instances, or share them intentionally.
    public convenience init(settings: OSCSettings, queue: DispatchQueue = .main,
                autoStart: Bool = true, manageLifecycle: Bool = true) {
        self.init(settings: settings, queue: queue, autoStart: autoStart,
                  manageLifecycle: manageLifecycle, connection: OSCConnection())
    }

    init(settings: OSCSettings, queue: DispatchQueue = .main,
         autoStart: Bool = true, manageLifecycle: Bool = true, connection: OSCConnection) {
        self.settings = settings
        self.queue = queue
        self.connection = connection
        connection.preferredIPAddress = settings.preferredServerAddress
        sender = OSCSender(destination: OSCEndpoint(host: settings.clientAddress, port: Self.clampedPort(settings.clientPort)),
                           interface: settings.preferredServerAddress)
        receiver = OSCReceiver(port: Self.clampedPort(settings.serverPort))
        sendingInterfaceAvailable = settings.preferredServerAddress.map { connection.allIpAddresses.contains($0) } ?? true
        connection.addressesDidChange = { [weak self] in self?.refreshSendingInterface() }
        sender.setErrorHandler { [weak self] description, generation in
            self?.reportSendError(description, generation: generation)
        }
        settingsObserver = settings.observe { [weak self] change in self?.settingsChanged(change) }
        if manageLifecycle { listenToApp() }
        if autoStart { start() }
    }

    public func start() {
        guard !isTornDown, active else { return }
        wantsRunning = true
        connection.check()
#if !targetEnvironment(simulator)
        do {
            try receiver.start()
            isServerPortOpen = receiver.isRunning
        } catch {
            sender.stop()
            isServerPortOpen = false
            lastError = error.localizedDescription
            return
        }
        guard sendingInterfaceAvailable else {
            sender.stop()
            lastError = unavailableInterfaceDescription
            return
        }
        do {
            try sender.start()
            lastError = nil
        } catch {
            // A send-side bind failure must not interrupt wildcard receiving.
            lastError = error.localizedDescription
        }
#endif
    }

    public func stop() {
        wantsRunning = false
        suspendTransport()
    }

    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        stop()
        if let settingsObserver { settings.removeObserver(settingsObserver) }
        settingsObserver = nil
        NotificationCenter.default.removeObserver(self)
        observingLifecycle = false
        sender.setActivityHandler(nil)
        sender.setErrorHandler(nil)
        receiver.setActivityHandler(nil)
        recentInputTimer?.invalidate()
        recentOutputTimer?.invalidate()
        connection.addressesDidChange = nil
        connection.stop()
    }

    private func suspendTransport() {
        // Stop receiving before closing the sending socket.
        receiver.stop()
        sender.stop()
        isServerPortOpen = false
    }

    private func settingsChanged(_ change: OSCSettings.Change) {
        guard !isTornDown else { return }
        switch change {
        case .clientAddress, .clientPort:
            sender.configure(destination: OSCEndpoint(host: settings.clientAddress, port: Self.clampedPort(settings.clientPort)))
        case .serverPort:
            configureReceiver(port: Self.clampedPort(settings.serverPort))
        case .preferredServerAddress:
            connection.preferredIPAddress = settings.preferredServerAddress
        }
    }

    // Retained public settings hooks.
    public func setting(clientAddress: String) {
        var endpoint = sender.destination ?? OSCEndpoint(host: clientAddress, port: Self.clampedPort(settings.clientPort))
        endpoint.host = clientAddress
        sender.configure(destination: endpoint)
    }
    public func setting(clientPort: Int) {
        var endpoint = sender.destination ?? OSCEndpoint(host: settings.clientAddress, port: Self.clampedPort(clientPort))
        endpoint.port = Self.clampedPort(clientPort)
        sender.configure(destination: endpoint)
    }
    public func setting(serverPort: Int) {
        configureReceiver(port: Self.clampedPort(serverPort))
    }

    private func configureReceiver(port: UInt16) {
        do {
            try receiver.configure(port: port)
            if active, wantsRunning {
                // Recover after a previous bind failure without reviving an explicitly paused facade.
                start()
            } else {
                isServerPortOpen = receiver.isRunning
                lastError = nil
            }
        } catch {
            isServerPortOpen = receiver.isRunning
            lastError = error.localizedDescription
        }
    }

    public func setPreferred(ipAddress: String) {
        settings.preferredServerAddress = ipAddress
    }
    public func resetPreferredIPAddress() {
        settings.preferredServerAddress = nil
    }

    private var unavailableInterfaceDescription: String {
        "Selected local IP address \(settings.preferredServerAddress ?? "") is unavailable. Select another IP address or Default."
    }

    private func refreshSendingInterface() {
        guard !isTornDown else { return }
        let preferred = settings.preferredServerAddress
        let available = preferred.map { connection.allIpAddresses.contains($0) } ?? true
        guard sender.interface != preferred || available != sendingInterfaceAvailable else { return }
        sendingInterfaceAvailable = available
        do {
            if !available { sender.stop() }
            try sender.configure(interface: preferred)
            if !available {
                lastError = unavailableInterfaceDescription
            } else {
#if !targetEnvironment(simulator)
                if active, wantsRunning, receiver.isRunning { try sender.start() }
#endif
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // Legacy send preserves numeric conversion and the caller's configured sending queue.
    nonisolated public func send(value: any OSCValue, address: String) {
        send(values: [value], address: address)
    }
    nonisolated public func send(values: [any OSCValue], address: String) {
        guard let generation = sender.activeGeneration else { return }
        let values = values.map { value -> any OSCValue in
            if let value = value as? CGFloat { return Float(value) }
            if let value = value as? Double { return Float(value) }
            return value
        }
        queue.async { [weak self, sender] in
            do { try sender.send(values: values, address: address, generation: generation) }
            catch OSCTransportError.notRunning { /* Pausing invalidates queued sends. */ }
            catch { self?.reportSendError(error.localizedDescription, generation: generation) }
        }
    }

    /// Forwards a decoded message without coercion or an additional dispatch hop.
    nonisolated public func relay(_ message: OSCMessage, to host: String, port: UInt16) throws {
        try sender.send(message, to: host, port: port)
    }

    nonisolated private func reportSendError(_ description: String, generation: UInt64) {
        let report = pending.withLock { state in
            guard state.errorGeneration != generation else { return false }
            state.errorGeneration = generation
            return true
        }
        guard report else { return }
        Task { @MainActor [weak self] in
            guard let self, self.sender.matchesGeneration(generation), self.active,
                  self.wantsRunning, !self.isTornDown else { return }
            self.lastError = description
        }
    }

    nonisolated private func recordActivity(input: Bool) {
        let schedule = pending.withLock { state in
            if input {
                guard !state.input else { return false }
                state.input = true
            } else {
                guard !state.output else { return false }
                state.output = true
            }
            return true
        }
        guard schedule else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pending.withLock { if input { $0.input = false } else { $0.output = false } }
            guard !self.isTornDown else { return }
            if input { self.setRecentInput() } else { self.setRecentOutput() }
        }
    }
    func setRecentInput() {
        recentInput = true
        recentInputTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.recentInput = false }
        }
        recentInputTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func setRecentOutput() {
        recentOutput = true
        recentOutputTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.recentOutput = false }
        }
        recentOutputTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func authorize(completion: ((Bool) -> Void)? = nil) {
        localNetworkAuthorization.requestAuthorization { completion?($0) }
    }

    func listenToApp() {
        guard !observingLifecycle else { return }
        observingLifecycle = true
#if os(macOS)
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive), name: NSApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate), name: NSApplication.willTerminateNotification, object: nil)
#else
        NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
#endif
    }
    @objc func didBecomeActive() {
        guard !isTornDown else { return }
        connection.start()
        connection.check()
#if !os(macOS)
        if active, wantsRunning { start() }
#endif
    }
    @objc func willResignActive() {
#if !os(macOS)
        suspendTransport()
#endif
        connection.stop()
    }
    @objc func willTerminate() { stop() }

    /// Tests whether a UDP port can currently be bound. Successful probing does not reserve it.
    nonisolated public static func isPortOpen(_ port: Int) -> Bool {
        let port = clampedPort(port)
        guard port > 0 else { return false }
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
    nonisolated private static func clampedPort(_ port: Int) -> UInt16 {
        UInt16(clamping: port)
    }

    isolated deinit {
        receiver.stop()
        sender.stop()
        if let settingsObserver { settings.removeObserver(settingsObserver) }
        NotificationCenter.default.removeObserver(self)
        recentInputTimer?.invalidate()
        recentOutputTimer?.invalidate()
        connection.stop()
    }
}
