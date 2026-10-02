import Foundation
import Testing
@testable import OSCTools2

@Suite("Existing OSC API")
struct OSCCompatibilityTests {
    @Test func typeConversionsRemainCompatible() {
        #expect(Bool.convert(value: Int32(1)))
        #expect(!Bool.convert(value: "false"))
        #expect(Int.convert(value: "42") == 42)
        #expect(CGFloat.convert(value: Float(0.5)) == 0.5)
        #expect(String.convert(value: Int32(42)) == "42")
    }

    @Test @MainActor func existingConstructionAndListeners() {
        let osc = OSC(queue: DispatchQueue(label: "compatibility"))
        defer { osc.tearDown() }
        let all = osc.backgroundListenToAll { _, _ in }
        let single = osc.backgroundListen(to: { "/test" }) { (_: Int) in }
        let array = osc.backgroundListenToArray(to: { "/test" }) { (_: [Int]) in }
        let any = osc.backgroundListenToAny(to: { "/test" }) { _ in }
        let anyArray = osc.backgroundListenToAnyArray(to: { "/test" }) { _ in }
        let async = osc.backgroundListenToAnyArrayAsync(to: { "/test" }) { _ in }
        for id in [all, single, array, any, anyArray, async] {
            osc.unlisten(id: id)
        }
        osc.active = false
        osc.send(value: Int32(1), address: "/test")
        osc.send(values: [Double.pi], address: "/test")
        #expect(!osc.active)
    }
}
