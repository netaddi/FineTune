import AudioToolbox
import Testing
import os
@testable import FineTune

@Suite("Audio service resource lifetime")
struct AudioServiceLifetimeTests {
    @Test("Stale or unpublished callbacks cannot keep a silent graph healthy")
    func onlyCurrentPrimaryCountsForHealth() {
        #expect(ProcessTapController.callbackCountsForHealth(callbackID: 5, primaryID: 5, handoffAtStart: 2, currentHandoff: 2))
        #expect(!ProcessTapController.callbackCountsForHealth(callbackID: 5, primaryID: 0, handoffAtStart: 2, currentHandoff: 2))
        #expect(!ProcessTapController.callbackCountsForHealth(callbackID: 4, primaryID: 5, handoffAtStart: 2, currentHandoff: 2))
        #expect(!ProcessTapController.callbackCountsForHealth(callbackID: 5, primaryID: 5, handoffAtStart: 3, currentHandoff: 3))
        #expect(!ProcessTapController.callbackCountsForHealth(callbackID: 5, primaryID: 5, handoffAtStart: 2, currentHandoff: 4))
    }
    @Test("Unknown identity and failed IOProc join retain resources without blocking MainActor indefinitely")
    func cleanupFailureRemainsPendingAndOrdered() async {
        let state = OSAllocatedUnfairLock(initialState: (known: false, join: false, calls: [String]()))
        var resources = TapResources()
        resources.aggregateDeviceID = 999
        resources.aggregateUID = "test-only"
        resources.tapID = 998
        resources.deviceProcID = { _, _, _, _, _, _, _ in noErr }
        resources.cleanupOperations = .init(
            identity: { _, _, _, _ in state.withLock { $0.known ? .owned : .unknown } },
            stop: { _, _ in state.withLock { $0.calls.append("stop") }; return noErr },
            join: { _, _ in state.withLock { $0.calls.append("join"); return $0.join ? noErr : -1 } },
            destroyAggregate: { _ in state.withLock { $0.calls.append("aggregate") }; return noErr },
            destroyTap: { _ in state.withLock { $0.calls.append("tap") }; return noErr })
        let start = ContinuousClock.now
        let unknownComplete = resources.destroy()
        #expect(!unknownComplete)
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(state.withLock { $0.calls.isEmpty })
        state.withLock { $0.known = true }
        let failedJoinComplete = resources.destroy()
        #expect(!failedJoinComplete)
        #expect(!state.withLock { $0.calls.contains("aggregate") || $0.calls.contains("tap") })
        state.withLock { $0.join = true }
        var done = false
        for _ in 0..<20 {
            if resources.destroy() { done = true; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(done)
        #expect(state.withLock { Array($0.calls.suffix(3)) } == ["join", "aggregate", "tap"])
    }
    @Test("Retirement rejects late callbacks while accounting for a reader already inside")
    func callbackGateDrainsExistingReader() {
        let gate = AudioCallbackLifetime()
        #expect(gate.enter())
        gate.retire()
        #expect(!gate.isDrained)
        #expect(!gate.enter())
        gate.leave()
        #expect(gate.isDrained)
        #expect(!gate.enter())
        #expect(gate.isDrained)
    }

    @Test("Unknown UID read is not proof of destruction")
    func identityTriState() {
        #expect(TapResources.classifyIdentity(createdGeneration: 1, currentGeneration: 1,
            expectedUID: "old", observedUID: nil, status: -1) == .unknown)
        #expect(TapResources.classifyIdentity(createdGeneration: 1, currentGeneration: 1,
            expectedUID: "old", observedUID: "old", status: noErr) == .owned)
        #expect(TapResources.classifyIdentity(createdGeneration: 1, currentGeneration: 1,
            expectedUID: "old", observedUID: "new", status: noErr) == .gone)
        #expect(TapResources.classifyIdentity(createdGeneration: 1, currentGeneration: 2,
            expectedUID: "old", observedUID: "old", status: noErr) == .gone)
        #expect(TapResources.classifyIdentity(createdGeneration: 1, currentGeneration: 1,
            expectedUID: "old", observedUID: nil, status: kAudioHardwareBadObjectError) == .gone)
    }
}
