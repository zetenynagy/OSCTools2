import Foundation
import Testing
@testable import OSCTools2

@Suite("Injectable settings") @MainActor
struct OSCSettingsTests {
    @Test func inMemorySettingsStayIndependent() {
        let first = OSCSettings(clientAddress: "127.0.0.1", clientPort: 9001, serverPort: 9000, persistence: .none)
        let second = OSCSettings(clientAddress: "127.0.0.2", clientPort: 9101, serverPort: 9100, persistence: .none)
        first.clientPort = 9002
        #expect(second.clientPort == 9101)
        #expect(second.serverPort == 9100)
    }

    @Test func namespacesAndLegacyKeysArePreserved() throws {
        let name = "OSCTools2Tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = OSCSettings(persistence: .userDefaults(defaults, namespace: "first"))
        let second = OSCSettings(persistence: .userDefaults(defaults, namespace: "second"))
        first.serverPort = 9000
        second.serverPort = 9100
        #expect(OSCSettings(persistence: .userDefaults(defaults, namespace: "first")).serverPort == 9000)
        #expect(OSCSettings(persistence: .userDefaults(defaults, namespace: "second")).serverPort == 9100)
        defaults.set(9200, forKey: "setting-server-port")
        let legacy = OSCSettings(persistence: .userDefaults(defaults, namespace: nil))
        #expect(legacy.serverPort == 9200)
        legacy.clientPort = 9201
        #expect(defaults.integer(forKey: "setting-client-port") == 9201)
    }

    @Test func injectedSettingsApplyBeforeStartupAndUpdateBothOwners() {
        let settings = OSCSettings(clientPort: 9001, serverPort: 9000, persistence: .none)
        let first = OSC(settings: settings, autoStart: false, manageLifecycle: false)
        let second = OSC(settings: settings, autoStart: false, manageLifecycle: false)
        defer { first.tearDown(); second.tearDown() }
        #expect(first.receiver.port == 9000)
        #expect(first.sender.destination?.port == 9001)
        settings.clientPort = 9002
        settings.serverPort = 9003
        #expect(first.sender.destination?.port == 9002)
        #expect(second.sender.destination?.port == 9002)
        #expect(first.receiver.port == 9003)
        #expect(second.receiver.port == 9003)
    }

    @Test func pauseSurvivesForegroundAndPortChange() {
        let osc = OSC(settings: OSCSettings(serverPort: 9000, persistence: .none), autoStart: false, manageLifecycle: false)
        defer { osc.tearDown() }
        osc.active = false
        osc.settings.serverPort = 9002
        osc.didBecomeActive()
        #expect(!osc.active)
        #expect(!osc.sender.isRunning)
        #expect(!osc.receiver.isRunning)
    }
}
