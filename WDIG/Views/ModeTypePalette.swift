import SwiftUI

/// The one place a way of moving gets a colour. Every view that colours by `modeType` asks
/// here, so the map, the calendar and the timeline agree.
enum ModeTypePalette {
    static let types = ["walk", "run", "scooter", "bike", "motorcycle", "car", "train", "plane", "other"]

    static func color(for modeType: String) -> Color {
        switch modeType {
        case "walk": Color(red: 0.20, green: 0.78, blue: 0.35)
        case "run": Color(red: 1.00, green: 0.58, blue: 0.00)
        case "scooter": Color(red: 0.19, green: 0.69, blue: 0.78)
        case "bike": Color(red: 0.00, green: 0.48, blue: 1.00)
        case "motorcycle": Color(red: 0.69, green: 0.32, blue: 0.87)
        case "car": Color(red: 0.56, green: 0.56, blue: 0.58)
        case "train": Color(red: 0.64, green: 0.52, blue: 0.37)
        case "plane": Color(red: 0.35, green: 0.34, blue: 0.84)
        default: Color(red: 0.78, green: 0.78, blue: 0.80)
        }
    }

    /// Points the segmenter has not assigned to a trip yet: the raw route of a day.
    static let unsegmented = Color(red: 0.00, green: 0.48, blue: 1.00).opacity(0.6)
}
