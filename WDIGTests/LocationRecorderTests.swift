import Foundation
import Testing

@testable import WDIG

/// Core Location as the tests see it: every call written down, the live sequence fed by hand.
actor FakeLocationSource: LocationProviding {
    private(set) var calls: [String] = []
    private(set) var liveKinds: [MovementKind] = []
    private(set) var fences: [(center: Coordinate, radius: Double)] = []
    private var live: AsyncThrowingStream<LiveUpdate, any Error>.Continuation?

    func start(for recorder: LocationRecorder) {
        calls.append("start")
    }

    func stop() {
        calls.append("stop")
    }

    func liveUpdates(_ kind: MovementKind) -> AsyncThrowingStream<LiveUpdate, any Error> {
        liveKinds.append(kind)
        live?.finish()
        let (stream, continuation) = AsyncThrowingStream<LiveUpdate, any Error>.makeStream()
        live = continuation
        return stream
    }

    func startWarm() {
        calls.append("startWarm")
    }

    func stopWarm() {
        calls.append("stopWarm")
    }

    func startVisits() {
        calls.append("startVisits")
    }

    func stopVisits() {
        calls.append("stopVisits")
    }

    func setFence(around center: Coordinate, radius: Double) {
        fences.append((center, radius))
    }

    func removeFence() {
        calls.append("removeFence")
    }

    /// What Core Location would hand the recorder on the live sequence.
    func deliver(_ update: LiveUpdate) {
        live?.yield(update)
    }
}

struct LocationRecorderTests {
    let clock = TestClock()
    let location = FakeLocationSource()
    let stopAt = Date(timeIntervalSince1970: 1_791_806_400)
    let normalPower = PowerSnapshot(level: 0.8, state: 1, lowPowerMode: false)

    func makeRecorder() throws -> LocationRecorder {
        let store = RecorderStore(modelContainer: try Store.container(inMemory: true))
        return LocationRecorder(
            store: store, locationSource: location, clock: clock, settings: RecorderSettings(),
            activitySource: FakeActivitySource(), stepsSource: FakeStepsSource())
    }

    /// Waits, briefly and on real time, for the recorder's own tasks to reach `condition`.
    func settles(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    func noted(_ event: RecorderEvent, by recorder: LocationRecorder) async -> Bool {
        await recorder.events().map(\.event).contains(event)
    }

    @Test("The warm phase ends six hundred seconds after the stop and not a second before")
    func warmPhaseEndsSixHundredSecondsAfterTheStop() async throws {
        let recorder = try makeRecorder()
        await recorder.start(trigger: .user, power: normalPower)
        #expect(await settles { await location.liveKinds == [.foot] })
        let stop = Fix(latitude: 52.2297, longitude: 21.0122, timestamp: stopAt)
        await location.deliver(LiveUpdate(stationary: true, fix: stop))
        #expect(await settles { await recorder.currentPhase() == .warm && clock.sleeping == 1 })
        #expect(await noted(.warmPhaseBegan, by: recorder))
        #expect(await location.calls.contains("startWarm"))

        clock.advance(by: .seconds(599))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.currentPhase() == .warm)
        #expect(await !noted(.warmPhaseEnded, by: recorder))
        #expect(await location.fences.isEmpty)

        clock.advance(by: .seconds(1))
        #expect(await settles { await noted(.warmPhaseEnded, by: recorder) })
        #expect(await recorder.currentPhase() == .asleep)
        #expect(await location.calls.contains("stopWarm"))
        let fences = await location.fences
        #expect(fences.count == 1)
        #expect(fences.first?.center == stop.coordinate)
        #expect(fences.first?.radius == 150)
        await recorder.stop()
    }

    @Test("Low Power Mode drops the recorder to coarse mode, and leaving it resumes live updates")
    func lowPowerModeEntersCoarseModeAndLeavingItResumes() async throws {
        let recorder = try makeRecorder()
        await recorder.start(trigger: .user, power: normalPower)
        #expect(await settles { await location.liveKinds == [.foot] })

        await recorder.powerChanged(PowerSnapshot(level: 0.8, state: 1, lowPowerMode: true))
        #expect(await recorder.currentPhase() == .coarse)
        #expect(await noted(.coarseModeEntered(reason: "lowPowerMode"), by: recorder))
        #expect(await location.calls.contains("startVisits"))
        #expect(await !noted(.coarseModeLeft, by: recorder))

        await recorder.powerChanged(normalPower)
        #expect(await recorder.currentPhase() == .live(.foot))
        #expect(await noted(.coarseModeLeft, by: recorder))
        #expect(await location.calls.contains("stopVisits"))
        #expect(await settles { await location.liveKinds == [.foot, .foot] })
        await recorder.stop()
    }

    @Test("A launch by the system notes a started event and resumes live updates")
    func launchNotesStartedAndResumesLiveUpdates() async throws {
        let recorder = try makeRecorder()
        await recorder.start(trigger: .launch, power: normalPower)
        #expect(await recorder.events().map(\.event.text).contains("started (launch)"))
        #expect(await recorder.currentPhase() == .live(.foot))
        #expect(await settles { await location.liveKinds == [.foot] })
        #expect(await location.calls.first == "start")
        #expect(await !noted(.resumed(trigger: .launch), by: recorder))

        await recorder.stop()
        #expect(await recorder.currentPhase() == .off)
        #expect(await noted(.stopped, by: recorder))
        #expect(await location.calls.last == "stop")
    }
}
