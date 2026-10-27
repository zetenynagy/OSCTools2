# OSCTools2

Swift 6.4 OSC tools for iOS 17, tvOS 17, macOS 14, and visionOS 1 or later.

`OSCSender` and `OSCReceiver` are independent, `Sendable` cores. Each instance owns its socket and synchronization; there is no shared sender, receiver, settings, or listener registry. Create as many as needed, using different receive ports. Their implementation lives in `Sources/OSCTools2/Sender/` and `Sources/OSCTools2/Receiver/`.

## Standalone transports

```swift
import OSCTools2
import OSCKit

let sender = OSCSender(destination: OSCEndpoint(host: "127.0.0.1", port: 9001))
let receiver = OSCReceiver(port: 9000)

let subscription = receiver.backgroundListenToMessages { message, timeTag, host, port in
    // Runs on this receiver's serial receive queue. Handle errors for your application.
    do { try sender.send(message) } catch { print(error) }
}

try sender.start()
try receiver.start()
try sender.send(values: [Int32(42), Double.pi, "hello"], address: "/example")
try sender.send(.message("/other"), to: "127.0.0.1", port: 9002)

receiver.unlisten(id: subscription)
receiver.stop()
sender.stop()
```

Construction does not start networking. `start()` is idempotent and throws socket errors; sending while stopped throws `OSCTransportError.notRunning`. The sender's destination can be omitted when every send supplies a host and port. Overrides apply to one message. Configure defaults with `sender.configure(destination:)`; these changes do not recreate its socket. Values retain their OSC types, including Double, blob, booleans, and empty argument lists.

By default, senders use system routing. Supply a local IPv4 address with `OSCSender(interface: "192.168.1.20")` or `try sender.configure(interface: "192.168.1.20")` to bind output and constrain routing to that interface. A nil interface restores system routing. Changing the interface replaces only the sending socket; unchanged selections and destination changes reuse it. Destination overrides use the same selected interface. A failed bind leaves the sender stopped without falling back. Interface lookup and binding happen at startup, not per message. Receivers continue listening on all interfaces, including broadcasts.

`receiver.configure(port:)` retains listeners and whether the receiver was running, replacing only its receiving socket. A bind failure leaves it stopped at the requested port; call `start()` to retry. Ports must be nonzero. `stop()` invalidates queued deliveries from that socket, though callbacks already selected for a message can finish. OSCKit's socket descriptor closes asynchronously, so immediately rebinding the same port can fail temporarily. Listeners can safely register, remove, stop, or reconfigure the receiver from a callback. Removing a listener does not cancel an already selected callback.

Synchronous callbacks run in receive order. An optional `receiveQueue` is the target of a private serial queue, so a concurrent target also preserves that order. Async address suppliers can reorder delivery; they discard results after their registration is removed or their socket generation changes. UI work should explicitly hop to the main actor. Address-filtered APIs retain the legacy convention: wildcards in the **received** address match the supplied local address, and `*` can span path separators.

Sending serializes and enqueues UDP output synchronously under a per-sender lock. Successful sends do not confirm delivery. Stopping waits for serialization/enqueueing in progress; already queued datagrams cannot be recalled. The cores add no per-message task, main-actor hop, logging, persistence, or observable state to synchronous traffic. Receiver callbacks execute outside its lock, using a copy-on-write listener snapshot. The async address API creates tasks only when explicitly used.

## Observable OSC facade and settings

`OSC()` and `OSC(queue:)` retain the existing app-facing API, automatic startup, legacy UserDefaults keys, typed listeners, and Double/CGFloat-to-Float conversion in `send`. `OSC` delegates transport work to its public `sender` and `receiver`. `relay(_:to:port:)` forwards a message directly through that sender without coercion or another dispatch hop.

For separate configurations, construct settings explicitly on the main actor:

```swift
@MainActor
func makeOSC() -> OSC {
    let settings = OSCSettings(clientAddress: "127.0.0.1", clientPort: 9001, serverPort: 9000)
    return OSC(settings: settings, autoStart: false, manageLifecycle: false)
}
```

Explicit settings default to memory-only storage. `OSCSettings()` alone loads the legacy standard UserDefaults keys. For persistence without collisions, inject a defaults store and namespace:

```swift
let settings = OSCSettings(
    serverPort: 9000,
    persistence: .userDefaults(.standard, namespace: "stageA")
)
```

A nil namespace uses the old `setting-client-address`, `setting-client-port`, `setting-server-port`, and `setting-preferred-server-address` keys. Sharing a settings instance intentionally updates every facade observing it. Independent settings objects do not synchronize after construction. Standalone cores have no persistence; applications can configure them from any settings system.

The facade applies `preferredServerAddress` before startup. `setPreferred(ipAddress:)` now binds sending to that local IPv4 address; `resetPreferredIPAddress()` restores system routing. Wi-Fi and wired interface changes are monitored independently of internet connectivity, with another refresh on foreground activation. If the selected IP disappears, only sending pauses and `lastError` describes the missing address. Sending resumes when it returns, provided the facade is still active and wants to run. The receiver keeps its wildcard bind throughout these changes.

The facade follows app activation by default. Pausing with `active = false` or calling `stop()` survives foreground notifications and settings edits. A receive-port bind failure, such as a port already in use, leaves sending running; the sender binds its own ephemeral port. Changing the receiving port keeps the sender and listeners and retries a previous bind failure if the facade still wants to run. `tearDown()` is terminal and removes lifecycle/settings subscriptions. Startup and asynchronous UDP send errors are exposed through `lastError`; `isServerPortOpen` reports an actual running receiver. `OSC.isPortOpen(_:)` probes UDP availability without reserving a port. Activity indicators are opt-in through `updateRecentInput` and `updateRecentOutput`.

## Swift 6 migration

`OSC`, `OSCSettings`, `OSCConnection`, and local-network authorization isolate their UI/configuration state to `@MainActor`. Construct and modify them there. Sending, relaying, registering listeners, and removing listeners remain nonisolated, backed by the `Sendable` cores. Background callbacks and address suppliers are `@Sendable`: protect mutable captures or use actors, and explicitly hop to the main actor for UI changes. Custom `OSCType` conformances now require `SendableMetatype` so conversion methods can run in background callbacks.

The Connectivity integration uses the main queue for configuration and status checks, avoiding races in the dependency's default concurrent queue. HTTP requests stay asynchronous, and starting its notifier repeatedly is idempotent. This integration is separate from the background transport cores.

The facade keeps its existing simulator networking restriction; standalone transports support simulator networking. Applications remain responsible for local-network privacy configuration and lifecycle policy. The receiving adapter retains the server API supported by the minimum OSCKit version 1.2.1; newer releases emit rename deprecations for that alias. The sending adapter uses OSCKit serialization and its existing CocoaAsyncSocket dependency to control interface binding and routing.

## Tests

```sh
swift test --package-path Packages/OSCTools2
swift test --package-path Packages/OSCTools2 -c release
swift test --package-path Packages/OSCTools2 --sanitize=thread
```

The `OSCTools2Tests` target covers legacy construction/conversion, injected and namespaced settings, independent transports, concurrent operations, lifecycle synchronization, stale callbacks, typed messages, errors, and real UDP loopback with multiple senders/receivers. XCTest performance cases compare 10,000 sends through the core with direct serialization using the same test transport; they do not measure network delivery throughput.
