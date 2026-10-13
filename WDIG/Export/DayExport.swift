import CoreTransferable
import Foundation
import SwiftUI

/// The day's GPX as something the share sheet can hand on; the file is written when the
/// sheet asks for it, not before.
struct DayExport: Transferable {
    let day: String
    let tz: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .gpx) { export in
            let url = try await GPXDayExporter.export(day: export.day, tz: export.tz, store: RecorderHub.shared.store)
            return SentTransferredFile(url)
        }
        .suggestedFileName { "wdig-\($0.day).gpx" }
    }
}
