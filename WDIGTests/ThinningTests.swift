import Foundation
import Testing

@testable import WDIG

struct ThinningTests {
    let settings = RecorderSettings()
    let start = Date(timeIntervalSince1970: 1_791_806_400)

    func fix(metersEast: Double, seconds: Double, accuracy: Double = 10) -> Fix {
        // One degree of longitude at 52.23 N is about 68,240 m.
        Fix(
            latitude: 52.2297, longitude: 21.0122 + metersEast / 68_240, horizontalAccuracy: accuracy,
            timestamp: start.addingTimeInterval(seconds))
    }

    @Test("The first fix is always kept")
    func firstFixIsAlwaysKept() {
        #expect(Thinning.shouldKeep(fix(metersEast: 0, seconds: 0), after: nil, kind: .foot, settings: settings))
    }

    @Test("On foot a fix nine metres on is dropped and one eleven metres on is kept")
    func onFootTenMetresDecides() {
        let last = fix(metersEast: 0, seconds: 0)
        #expect(!Thinning.shouldKeep(fix(metersEast: 9, seconds: 5), after: last, kind: .foot, settings: settings))
        #expect(Thinning.shouldKeep(fix(metersEast: 11, seconds: 5), after: last, kind: .foot, settings: settings))
    }

    @Test("In a vehicle the distance is fifty metres and on a bike twenty-five")
    func vehicleAndBikeDistances() {
        let last = fix(metersEast: 0, seconds: 0)
        #expect(!Thinning.shouldKeep(fix(metersEast: 40, seconds: 5), after: last, kind: .vehicle, settings: settings))
        #expect(Thinning.shouldKeep(fix(metersEast: 55, seconds: 5), after: last, kind: .vehicle, settings: settings))
        #expect(!Thinning.shouldKeep(fix(metersEast: 20, seconds: 5), after: last, kind: .cycle, settings: settings))
        #expect(Thinning.shouldKeep(fix(metersEast: 30, seconds: 5), after: last, kind: .cycle, settings: settings))
    }

    @Test("A fix sixty seconds after the last kept one is kept wherever it is")
    func sixtySecondsKeepsAFix() {
        let last = fix(metersEast: 0, seconds: 0)
        #expect(!Thinning.shouldKeep(fix(metersEast: 1, seconds: 59), after: last, kind: .vehicle, settings: settings))
        #expect(Thinning.shouldKeep(fix(metersEast: 1, seconds: 60), after: last, kind: .vehicle, settings: settings))
    }

    @Test("A fix with a negative accuracy is dropped and a poor one is kept")
    func negativeAccuracyIsDropped() {
        #expect(
            !Thinning.shouldKeep(
                fix(metersEast: 0, seconds: 0, accuracy: -1), after: nil, kind: .foot, settings: settings))
        #expect(
            Thinning.shouldKeep(
                fix(metersEast: 0, seconds: 0, accuracy: 500), after: nil, kind: .foot, settings: settings))
    }
}
