import SwiftUI
import MapKit
import CoreLocation
import Contacts

/// Address autocomplete backed by MapKit (MKLocalSearchCompleter) — no API key needed.
struct AddressSearchView: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (AddressFields) -> Void

    @State private var completer = AddressCompleter()
    @State private var query = ""
    @State private var resolving = false

    var body: some View {
        NavigationStack {
            List(completer.results, id: \.self) { item in
                Button {
                    Task { await resolve(item) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.title)
                        Text(item.subtitle).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay { if resolving { ProgressView() } }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Street, city…")
            .onChange(of: query) { _, q in completer.update(q) }
            .navigationTitle("Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) async {
        resolving = true; defer { resolving = false }
        let search = MKLocalSearch(request: MKLocalSearch.Request(completion: completion))
        guard let item = try? await search.start().mapItems.first else { return }
        onPick(AddressFields.from(placemark: item.placemark))
        dismiss()
    }
}

@Observable
final class AddressCompleter: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func update(_ query: String) {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { results = []; return }
        completer.queryFragment = query
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { results = completer.results }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { results = [] }
}

extension AddressFields {
    static func from(placemark p: CLPlacemark) -> AddressFields {
        var a = AddressFields()
        let number = p.subThoroughfare ?? ""
        let street = p.thoroughfare ?? ""
        a.line1 = [number, street].filter { !$0.isEmpty }.joined(separator: " ")
        a.city = p.locality ?? p.subLocality ?? ""
        a.state = p.administrativeArea ?? ""
        a.postalCode = p.postalCode ?? ""
        a.country = p.isoCountryCode ?? "US"
        a.latitude = p.location?.coordinate.latitude
        a.longitude = p.location?.coordinate.longitude
        return a
    }
}

/// One-shot current location → reverse geocoded address.
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    func currentAddress() async throws -> AddressFields {
        let location = try await currentLocation()
        let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
        guard let p = placemarks.first else { throw AppError.message("Could not resolve address") }
        var a = AddressFields.from(placemark: p)
        a.latitude = location.coordinate.latitude
        a.longitude = location.coordinate.longitude
        return a
    }

    private func currentLocation() async throws -> CLLocation {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let l = locations.last { continuation?.resume(returning: l); continuation = nil }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways,
           continuation != nil { manager.requestLocation() }
    }
}
