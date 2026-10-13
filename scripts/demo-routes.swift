// Fetches the street routes the demo month is built from, through Apple Maps directions, and
// writes them as WDIG/Resources/DemoRoutes.json (also copied into wdig-backend/fixtures), so
// both generators tell the same story over the same streets, offline and deterministically.
//
//   swift scripts/demo-routes.swift [output.json]
//
// The places are addresses in Warsaw; a leg is one direction between two places by one way of
// moving (walk, bike, car), as Apple Maps routes it. Runs reuse the walking legs.
import Foundation
import MapKit

struct Place {
    let key: String
    let name: String
    let address: String
    let fallback: CLLocationCoordinate2D
    /// Some addresses geocode to the wrong spot; these keep their coordinate as given.
    var geocode: Bool = true
}

let places: [Place] = [
    Place(
        key: "home", name: "Home", address: "Żurawia 16, Warszawa",
        fallback: .init(latitude: 52.2288, longitude: 21.0168)),
    Place(
        key: "oldTown", name: "Old Town", address: "Rynek Starego Miasta, Warszawa",
        fallback: .init(latitude: 52.2497, longitude: 21.0122)),
    Place(
        key: "vistula", name: "Vistula boulevard", address: "Bulwar Bohdana Grzymały-Siedleckiego, Warszawa",
        fallback: .init(latitude: 52.2410, longitude: 21.0290)),
    Place(
        key: "lomianki", name: "Łomianki", address: "Warszawska 73, Łomianki",
        fallback: .init(latitude: 52.3328, longitude: 20.8862)),
    Place(
        key: "office", name: "Office", address: "Czerniakowska 87A, Warszawa",
        fallback: .init(latitude: 52.2110, longitude: 21.0470)),
    Place(
        key: "zloteTarasy", name: "Złote Tarasy", address: "Złota 59, Warszawa",
        fallback: .init(latitude: 52.2297, longitude: 21.0028)),
    Place(
        key: "kinoteka", name: "Kinoteka", address: "plac Defilad 1, Warszawa",
        fallback: .init(latitude: 52.2318, longitude: 21.0063)),
    Place(
        key: "lazienki", name: "Łazienki", address: "Pałac na Wyspie, Łazienki Królewskie, Warszawa",
        fallback: .init(latitude: 52.2149, longitude: 21.0355), geocode: false),
    Place(
        key: "koszyki", name: "Hala Koszyki", address: "Koszykowa 63, Warszawa",
        fallback: .init(latitude: 52.2225, longitude: 21.0107)),
]

struct LegSpec {
    let from: String
    let to: String
    let mode: String
}

var legSpecs: [LegSpec] = []
for pair in [
    ("home", "oldTown"), ("home", "vistula"), ("home", "zloteTarasy"), ("home", "kinoteka"), ("home", "lazienki"),
    ("home", "koszyki"),
] {
    legSpecs.append(LegSpec(from: pair.0, to: pair.1, mode: "walk"))
    legSpecs.append(LegSpec(from: pair.1, to: pair.0, mode: "walk"))
}
for pair in [("home", "vistula"), ("vistula", "lomianki")] {
    legSpecs.append(LegSpec(from: pair.0, to: pair.1, mode: "bike"))
    legSpecs.append(LegSpec(from: pair.1, to: pair.0, mode: "bike"))
}
legSpecs.append(LegSpec(from: "home", to: "office", mode: "car"))
legSpecs.append(LegSpec(from: "office", to: "home", mode: "car"))

func transport(_ mode: String) -> MKDirectionsTransportType {
    switch mode {
    case "car": .automobile
    case "bike": .cycling
    default: .walking
    }
}

var coordinates: [String: CLLocationCoordinate2D] = [:]
let geocoder = CLGeocoder()
// Everything runs on the main queue through callbacks: a wait on the main thread would block
// the very queue the callbacks arrive on. Geocode one at a time: the geocoder refuses
// parallel requests.
func geocode(_ index: Int) {
    guard index < places.count else {
        fetch(0)
        return
    }
    let place = places[index]
    if !place.geocode {
        coordinates[place.key] = place.fallback
        DispatchQueue.main.async { geocode(index + 1) }
        return
    }
    geocoder.geocodeAddressString(place.address) { marks, _ in
        if let c = marks?.first?.location?.coordinate {
            coordinates[place.key] = c
            FileHandle.standardError.write("geocoded \(place.key): \(c.latitude), \(c.longitude)\n".data(using: .utf8)!)
        } else {
            coordinates[place.key] = place.fallback
            FileHandle.standardError.write("fallback \(place.key)\n".data(using: .utf8)!)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { geocode(index + 1) }
    }
}
var legs: [String: Any] = [:]
func fetch(_ index: Int) {
    guard index < legSpecs.count else {
        finish()
        return
    }
    let spec = legSpecs[index]
    let request = MKDirections.Request()
    request.source = MKMapItem(
        location: CLLocation(latitude: coordinates[spec.from]!.latitude, longitude: coordinates[spec.from]!.longitude),
        address: nil)
    request.destination = MKMapItem(
        location: CLLocation(latitude: coordinates[spec.to]!.latitude, longitude: coordinates[spec.to]!.longitude),
        address: nil)
    request.transportType = transport(spec.mode)
    MKDirections(request: request).calculate { response, error in
        let key = "\(spec.from)-\(spec.to)-\(spec.mode)"
        if let route = response?.routes.first {
            var points = [MKMapPoint](repeating: MKMapPoint(), count: route.polyline.pointCount)
            let raw = route.polyline.points()
            for i in 0..<route.polyline.pointCount { points[i] = raw[i] }
            let coords = points.map {
                [($0.coordinate.latitude * 1e6).rounded() / 1e6, ($0.coordinate.longitude * 1e6).rounded() / 1e6]
            }
            legs[key] = [
                "from": spec.from, "to": spec.to, "mode": spec.mode, "distanceM": Int(route.distance),
                "expectedS": Int(route.expectedTravelTime), "coordinates": coords,
            ]
            FileHandle.standardError.write(
                "\(key): \(coords.count) points, \(Int(route.distance)) m\n".data(using: .utf8)!)
        } else {
            FileHandle.standardError.write("\(key): failed \(error.map { "\($0)" } ?? "")\n".data(using: .utf8)!)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { fetch(index + 1) }
    }
}
func finish() {
    var placesJSON: [String: Any] = [:]
    for place in places {
        let c = coordinates[place.key]!
        placesJSON[place.key] = [
            "name": place.name, "address": place.address, "lat": (c.latitude * 1e6).rounded() / 1e6,
            "lon": (c.longitude * 1e6).rounded() / 1e6,
        ]
    }
    let document: [String: Any] = [
        "generated": ISO8601DateFormatter().string(from: Date()), "source": "Apple Maps directions",
        "places": placesJSON, "legs": legs,
    ]
    let data = try! JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "WDIG/Resources/DemoRoutes.json"
    try! data.write(to: URL(fileURLWithPath: output))
    print("wrote \(output): \(legs.count) legs")
    exit(legs.count == legSpecs.count ? 0 : 1)
}
geocode(0)
dispatchMain()
