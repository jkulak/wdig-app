import MapKit
import SwiftUI

/// The map of one local day: the route coloured by the way of moving where the segmenter has
/// decided it, the raw route where it has not, and a dot with the time spent at each stop. It
/// shows recorded data only and never follows the phone.
struct DayMapScreen: View {
    @State private var model = DayMapModel()
    @State private var camera: MapCameraPosition = .automatic
    @State private var showingDays = false

    var body: some View {
        NavigationStack {
            Map(position: $camera) {
                ForEach(model.lines) { line in
                    MapPolyline(coordinates: line.coordinates)
                        .stroke(line.color, lineWidth: 4)
                }
                ForEach(model.dotted) { line in
                    MapPolyline(coordinates: line.coordinates)
                        .stroke(line.color, style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
                }
                ForEach(model.stops) { stop in
                    Annotation(stop.label, coordinate: stop.coordinate, anchor: .center) {
                        Circle()
                            .fill(Color.primary)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    }
                }
            }
            .mapStyle(.standard(emphasis: .muted))
            .overlay(alignment: .bottom) {
                if model.lines.isEmpty, model.stops.isEmpty {
                    Text("No data for this day")
                        .padding(8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Previous day", systemImage: "chevron.left") {
                        model.step(by: -1)
                    }
                    .disabled(!model.canGoBack)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Next day", systemImage: "chevron.right") {
                        model.step(by: 1)
                    }
                    .disabled(!model.canGoForward)
                }
                ToolbarItem(placement: .principal) {
                    Button(model.title) {
                        showingDays = true
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    ShareLink(
                        item: DayExport(day: model.day, tz: model.tz), preview: SharePreview("WDIG \(model.day)")
                    ) {
                        Label("Share the day as GPX", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.lines.isEmpty && model.stops.isEmpty)
                }
            }
            .sheet(isPresented: $showingDays) {
                DaysList(days: model.days) { day in
                    model.show(day)
                    showingDays = false
                }
            }
            .task(id: model.day) {
                await model.load()
                if let region = model.region {
                    camera = .region(region)
                }
            }
        }
    }
}

/// The list of days with data, newest first.
struct DaysList: View {
    let days: [DaySummarySnapshot]
    let choose: (String) -> Void

    var body: some View {
        NavigationStack {
            List(days, id: \.localDay) { day in
                Button {
                    choose(day.localDay)
                } label: {
                    HStack {
                        Text(day.localDay)
                        Spacer()
                        Text("\(day.pointCount) points").foregroundStyle(.secondary)
                        if day.coarse {
                            Text("coarse").font(.caption).padding(4).background(.yellow.opacity(0.3), in: Capsule())
                        }
                    }
                }
                .tint(.primary)
            }
            .navigationTitle("Days")
        }
    }
}

/// What the map draws for a day, prepared off the map view: lines per trip (or one raw line),
/// dots per stop, the region that fits them, and the day navigation.
@MainActor
@Observable
final class DayMapModel {
    struct Line: Identifiable {
        let id: UUID
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
    }

    struct Stop: Identifiable {
        let id: UUID
        let coordinate: CLLocationCoordinate2D
        let label: String
    }

    let tz = TimeZone.current.identifier
    private(set) var day: String
    private(set) var lines: [Line] = []
    private(set) var dotted: [Line] = []
    private(set) var stops: [Stop] = []
    private(set) var region: MKCoordinateRegion?
    private(set) var days: [DaySummarySnapshot] = []

    init() {
        day = LocalDay.key(for: Date(), tz: TimeZone.current.identifier)
    }

    var title: String {
        guard let bounds = LocalDay.bounds(of: day, tz: tz) else { return day }
        return bounds.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    var canGoForward: Bool {
        day < LocalDay.key(for: Date(), tz: tz)
    }

    var canGoBack: Bool {
        guard let earliest = days.last?.localDay else { return true }
        return day > earliest
    }

    func step(by days: Int) {
        guard let bounds = LocalDay.bounds(of: day, tz: tz) else { return }
        let next = bounds.start.addingTimeInterval(TimeInterval(days) * 86_400 + 3_600)
        show(LocalDay.key(for: next, tz: tz))
    }

    func show(_ newDay: String) {
        day = newDay
    }

    func load() async {
        let store = RecorderHub.shared.store
        days = (try? await store.daysWithData()) ?? []
        let points = ((try? await store.points(onDay: day)) ?? []).filter { $0.hAccM <= 100 }
        let segments = (try? await store.segments(overlappingDay: day, tz: tz)) ?? []
        var lines: [Line] = []
        var dotted: [Line] = []
        var used = Set<Date>()
        let settings = SegmentationSettings.load()
        let drafts = segments.map { segment -> SegmentDraft in
            let inside =
                segment.kind == "trip"
                ? points.filter { $0.recordedAt >= segment.startAt && $0.recordedAt <= segment.endAt } : []
            return SegmentDraft(
                kind: segment.kind, startAt: segment.startAt, endAt: segment.endAt, tz: segment.tz,
                modeDetected: segment.modeDetected, modeConf: segment.modeConf, modeType: segment.modeType,
                distanceM: segment.distanceM, pointCount: segment.pointCount, centerLat: segment.centerLat,
                centerLon: segment.centerLon, source: segment.source, coarse: segment.coarse, points: inside)
        }
        for (index, draft) in drafts.enumerated() where draft.kind == "trip" {
            let color = ModeTypePalette.color(for: draft.modeType)
            let previous = index > 0 && drafts[index - 1].kind == "stop" ? drafts[index - 1] : nil
            let next = index + 1 < drafts.count && drafts[index + 1].kind == "stop" ? drafts[index + 1] : nil
            draft.points.forEach { used.insert($0.recordedAt) }
            var run: [CLLocationCoordinate2D] = []
            for leg in Segmenter.legs(for: draft, after: previous, before: next, settings: settings) {
                let from = CLLocationCoordinate2D(latitude: leg.from.latitude, longitude: leg.from.longitude)
                let to = CLLocationCoordinate2D(latitude: leg.to.latitude, longitude: leg.to.longitude)
                if leg.dotted {
                    if run.count >= 2 {
                        lines.append(Line(id: UUID(), coordinates: run, color: color))
                    }
                    run = []
                    dotted.append(Line(id: UUID(), coordinates: [from, to], color: color.opacity(0.6)))
                } else {
                    if run.isEmpty {
                        run.append(from)
                    }
                    run.append(to)
                }
            }
            if run.count >= 2 {
                lines.append(Line(id: UUID(), coordinates: run, color: color))
            }
        }
        let rest = points.filter { !used.contains($0.recordedAt) }
        if rest.count >= 2 {
            lines.append(
                Line(id: UUID(), coordinates: rest.map(\.locationCoordinate), color: ModeTypePalette.unsegmented))
        }
        self.lines = lines
        self.dotted = dotted
        stops = segments.filter { $0.kind == "stop" }.compactMap { segment in
            guard let lat = segment.centerLat, let lon = segment.centerLon else { return nil }
            let coordinate = CLLocationCoordinate2D(
                latitude: Double(lat) / PointSample.scale, longitude: Double(lon) / PointSample.scale)
            return Stop(
                id: segment.id, coordinate: coordinate,
                label: Self.dwell(segment.endAt.timeIntervalSince(segment.startAt)))
        }
        region = Self.region(fitting: points.map(\.locationCoordinate) + stops.map(\.coordinate))
    }

    nonisolated static func dwell(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    nonisolated static func region(fitting coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.2, 0.005), longitudeDelta: max((maxLon - minLon) * 1.2, 0.005))
        return MKCoordinateRegion(center: center, span: span)
    }
}

extension PointSample {
    var locationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
