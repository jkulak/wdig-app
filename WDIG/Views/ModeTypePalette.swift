import SwiftUI

/// The one place a way of moving gets a colour and a name. Every view that colours by
/// `modeType` asks here, so the map, the calendar and the timeline agree, and the colours
/// themselves live in the asset catalog, one set per type with a light and a dark appearance.
enum ModeTypePalette {
    static let types = ["walk", "run", "scooter", "bike", "motorcycle", "car", "train", "plane", "other"]

    /// The palette's type for a stored one: a type it does not know is drawn as `other`.
    static func known(_ modeType: String) -> String {
        types.contains(modeType) ? modeType : "other"
    }

    /// The colour set's name in the asset catalog, under the `ModeType` folder.
    static func assetName(for modeType: String) -> String {
        "ModeType/\(known(modeType))"
    }

    static func color(for modeType: String) -> Color {
        Color(assetName(for: modeType), bundle: nil)
    }

    /// The type's name for a label, from the String Catalog.
    static func name(for modeType: String) -> String {
        switch known(modeType) {
        case "walk": String(localized: "Walk")
        case "run": String(localized: "Run")
        case "scooter": String(localized: "Scooter")
        case "bike": String(localized: "Bike")
        case "motorcycle": String(localized: "Motorcycle")
        case "car": String(localized: "Car")
        case "train": String(localized: "Train")
        case "plane": String(localized: "Plane")
        default: String(localized: "Other")
        }
    }

    /// Points the segmenter has not assigned to a trip yet: the raw route of a day.
    static let unsegmented = color(for: "bike").opacity(0.6)
}
