import Testing
import UIKit

@testable import WDIG

@MainActor
struct ModeTypePaletteTests {
    /// The colour's sRGB components in thousandths, as the catalog resolves it for a style.
    func components(of modeType: String, in style: UIUserInterfaceStyle) throws -> [Int] {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let color = try #require(
            UIColor(named: ModeTypePalette.assetName(for: modeType), in: Bundle.main, compatibleWith: traits))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        #expect(color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        return [red, green, blue].map { Int(($0 * 1_000).rounded()) }
    }

    @Test("Every way of moving has a colour of its own in the light and in the dark appearance")
    func everyTypeHasAColourOfItsOwnInBothAppearances() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let colours = try ModeTypePalette.types.map { try components(of: $0, in: style) }
            #expect(Set(colours).count == ModeTypePalette.types.count, "style \(style.rawValue): \(colours)")
        }
    }

    @Test("Each colour's dark appearance differs from its light one")
    func eachColoursDarkAppearanceDiffersFromItsLightOne() throws {
        for type in ModeTypePalette.types {
            #expect(try components(of: type, in: .light) != components(of: type, in: .dark), "\(type)")
        }
    }

    @Test("A way of moving the palette does not know is drawn and named as other")
    func unknownTypeIsDrawnAndNamedAsOther() {
        #expect(ModeTypePalette.assetName(for: "hoverboard") == "ModeType/other")
        #expect(ModeTypePalette.name(for: "hoverboard") == "Other")
        #expect(ModeTypePalette.name(for: "bike") == "Bike")
    }
}
