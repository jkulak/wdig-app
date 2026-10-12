import Foundation
import Testing

@testable import WDIG

struct UUIDV7Tests {
    @Test("A generated id carries version 7 and the RFC variant")
    func generatedIdCarriesVersion7() {
        let id = UUID.v7()
        #expect(id.version == 7)
        #expect(id.uuid.8 & 0xC0 == 0x80)
        #expect(UUID().version == 4)
    }

    @Test("Ids made a second apart sort by the time they were made")
    func idsMadeASecondApartSortByTime() {
        let earlier = UUID.v7(now: Date(timeIntervalSince1970: 1_791_754_200))
        let later = UUID.v7(now: Date(timeIntervalSince1970: 1_791_754_201))
        #expect(earlier.uuidString < later.uuidString)
    }

    @Test("Two ids made at the same instant differ")
    func twoIdsMadeAtTheSameInstantDiffer() {
        let instant = Date()
        #expect(UUID.v7(now: instant) != UUID.v7(now: instant))
    }
}
