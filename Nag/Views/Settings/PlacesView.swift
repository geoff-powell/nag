import CoreLocation
import MapKit
import NagKit
import SwiftUI

/// Saved places for nags and locks that start at a place. Places stay on this iPhone.
struct PlacesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: SavedPlace?
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Location", value: locationLabel)
                if model.locationStatus == .notDetermined || model.locationStatus == .authorizedWhenInUse {
                    Button(model.locationStatus == .notDetermined ? "Allow location" : "Allow location all the time") {
                        model.requestLocation()
                    }
                }
            } footer: {
                Text("Nag only checks whether you've arrived at or left your saved places. \"Always\" lets that work with Nag closed; with \"While Using\", places only work while Nag is open.")
            }

            Section {
                ForEach(model.state.places) { place in
                    Button {
                        editing = place
                    } label: {
                        LabeledContent(place.name, value: "\(Int(place.radius)) m")
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    for index in offsets { model.deletePlace(model.state.places[index].id) }
                }
                Button("Add place", systemImage: "plus") { adding = true }
            } header: {
                Text("Places")
            } footer: {
                let overflow = PlaceMonitoring.overflow(for: model.state)
                if overflow > 0 {
                    Text("iPhone watches up to \(PlaceMonitoring.regionLimit) places. \(overflow) unused \(overflow == 1 ? "place isn't" : "places aren't") watched.")
                } else {
                    Text("Places stay on this iPhone and don't sync. Monitoring starts again after the first unlock following a restart.")
                }
            }

            if !foreignRefs.isEmpty {
                Section {
                    ForEach(foreignRefs, id: \.id) { ref in
                        Picker(ref.name, selection: Binding(
                            get: { model.state.placeLinks[ref.id.uuidString] },
                            set: { model.linkPlace(ref, to: $0) }
                        )) {
                            Text("Not on this iPhone").tag(UUID?.none)
                            ForEach(model.state.places) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                } header: {
                    Text("From your other devices")
                } footer: {
                    Text("Some nags use places saved on another device. Pick a place here to use them on this iPhone too.")
                }
            }
        }
        .navigationTitle("Places")
        .sheet(isPresented: $adding) {
            PlaceEditorView(place: nil)
        }
        .sheet(item: $editing) { place in
            PlaceEditorView(place: place)
        }
    }

    /// Places nags and locks mention that aren't this iPhone's own, linked or not.
    private var foreignRefs: [PlaceRef] {
        var seen = Set<UUID>()
        let refs = model.state.tasks.compactMap(\.placeTrigger?.place) + model.state.profiles.compactMap(\.place)
        return refs.filter { model.state.place($0.id) == nil && seen.insert($0.id).inserted }
    }

    private var locationLabel: String {
        switch model.locationStatus {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While using Nag"
        case .denied: "Off — turn on in Settings"
        case .restricted: "Restricted"
        default: "Not asked yet"
        }
    }
}

struct PlaceEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let isNew: Bool
    @State private var place: SavedPlace
    @State private var hasLocation: Bool
    @State private var camera: MapCameraPosition
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var locating = false
    @State private var message: String?

    init(place: SavedPlace?) {
        isNew = place == nil
        let initial = place ?? SavedPlace(name: "", latitude: 0, longitude: 0)
        _place = State(initialValue: initial)
        _hasLocation = State(initialValue: place != nil)
        _camera = State(initialValue: place.map { .region(Self.region(for: $0)) } ?? .userLocation(fallback: .automatic))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Home", text: $place.name)
                }

                Section {
                    MapReader { proxy in
                        Map(position: $camera) {
                            if hasLocation {
                                MapCircle(center: coordinate, radius: place.radius)
                                    .foregroundStyle(.orange.opacity(0.25))
                                    .stroke(.orange, lineWidth: 2)
                                Marker(place.name.isEmpty ? "Place" : place.name, coordinate: coordinate)
                                    .tint(.orange)
                            }
                            UserAnnotation()
                        }
                        .onTapGesture { point in
                            if let tapped = proxy.convert(point, from: .local) { setLocation(tapped) }
                        }
                    }
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())

                    Button {
                        Task { await useCurrentLocation() }
                    } label: {
                        Label(locating ? "Finding you…" : "Use current location", systemImage: "location.fill")
                    }
                    .disabled(locating)
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Tap the map to move the place.")
                }

                Section("Search") {
                    TextField("Address or place", text: $query)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    ForEach(results, id: \.self) { item in
                        Button {
                            pick(item)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.name ?? "Place")
                                if let address = item.placemark.title {
                                    Text(address).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }

                Section {
                    LabeledContent("Radius", value: "\(Int(place.radius)) m")
                    Slider(value: $place.radius, in: SavedPlace.radiusRange, step: 25)
                } footer: {
                    Text("Bigger is more reliable. Under about 150 m, arrivals can be late or missed.")
                }

                if !isNew {
                    Section {
                        Button("Delete place", role: .destructive) {
                            model.deletePlace(place.id)
                            dismiss()
                        }
                    } footer: {
                        Text("Nags and locks using it stay, but won't start here until you pick another place.")
                    }
                }
            }
            .navigationTitle(isNew ? "New place" : "Edit place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        place.name = place.name.trimmingCharacters(in: .whitespaces)
                        model.savePlace(place)
                        if model.locationStatus == .notDetermined { model.requestLocation() }
                        dismiss()
                    }
                    .disabled(!hasLocation || place.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
    }

    private static func region(for place: SavedPlace) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
            latitudinalMeters: place.radius * 5,
            longitudinalMeters: place.radius * 5
        )
    }

    private func setLocation(_ coordinate: CLLocationCoordinate2D, recenter: Bool = false) {
        place.latitude = coordinate.latitude
        place.longitude = coordinate.longitude
        hasLocation = true
        if recenter { camera = .region(Self.region(for: place)) }
    }

    private func useCurrentLocation() async {
        message = nil
        if model.locationStatus == .notDetermined {
            model.requestLocation()
        }
        locating = true
        defer { locating = false }
        guard let coordinate = await model.placeMonitor?.currentCoordinate() else {
            message = "Couldn't find your location. Check that Nag can use it in Settings."
            return
        }
        setLocation(coordinate, recenter: true)
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        results = (try? await MKLocalSearch(request: request).start().mapItems.prefix(5).map { $0 }) ?? []
    }

    private func pick(_ item: MKMapItem) {
        if place.name.trimmingCharacters(in: .whitespaces).isEmpty, let name = item.name { place.name = name }
        setLocation(item.placemark.coordinate, recenter: true)
        results = []
    }
}
