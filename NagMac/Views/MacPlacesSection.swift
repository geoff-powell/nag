import CoreLocation
import MapKit
import NagKit
import SwiftUI

/// Saved places in Settings. Places stay on this Mac and are only watched while Nag is running.
struct MacPlacesSection: View {
    @Environment(MacModel.self) private var model
    @State private var editing: SavedPlace?
    @State private var adding = false

    var body: some View {
        Section {
            LabeledContent("Location", value: locationLabel)
            if model.locationStatus == .notDetermined {
                Button("Allow location") { model.requestLocation() }
            } else if model.locationStatus == .denied {
                Button("Open Location Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            ForEach(model.state.places) { place in
                HStack {
                    Text(place.name)
                    Spacer()
                    Text("\(Int(place.radius)) m").foregroundStyle(.secondary)
                    Button("Edit") { editing = place }
                    Button("Delete", systemImage: "trash") { model.deletePlace(place.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            Button("Add place…", systemImage: "plus") { adding = true }

            ForEach(foreignRefs, id: \.id) { ref in
                Picker("“\(ref.name)” from another device", selection: Binding(
                    get: { model.state.placeLinks[ref.id.uuidString] },
                    set: { model.linkPlace(ref, to: $0) }
                )) {
                    Text("Not on this Mac").tag(UUID?.none)
                    ForEach(model.state.places) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
        } header: {
            Text("Places")
        } footer: {
            Text("Optional. Start nags or switch on locks when this Mac arrives at or leaves a place. Places stay on this Mac, and are only watched while Nag is running.")
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $adding) { MacPlaceEditor(place: nil) }
        .sheet(item: $editing) { MacPlaceEditor(place: $0) }
    }

    private var foreignRefs: [PlaceRef] {
        var seen = Set<UUID>()
        let refs = model.state.tasks.compactMap(\.placeTrigger?.place) + model.state.profiles.compactMap(\.place)
        return refs.filter { model.state.place($0.id) == nil && seen.insert($0.id).inserted }
    }

    private var locationLabel: String {
        switch model.locationStatus {
        case .authorizedAlways: "Allowed"
        case .denied: "Off — turn on in System Settings"
        case .restricted: "Restricted"
        default: "Not asked yet"
        }
    }
}

struct MacPlaceEditor: View {
    @Environment(MacModel.self) private var model
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
        _camera = State(initialValue: place.map { .region(Self.region(for: $0)) } ?? .automatic)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $place.name, prompt: Text("e.g. Office"))
                HStack {
                    TextField("Search", text: $query, prompt: Text("Address or place"))
                        .onSubmit { Task { await search() } }
                    Button(locating ? "Finding…" : "Use current location", systemImage: "location.fill") {
                        Task { await useCurrentLocation() }
                    }
                    .disabled(locating)
                }
                ForEach(results, id: \.self) { item in
                    Button {
                        pick(item)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.name ?? "Place")
                            if let title = item.placemark.title {
                                Text(title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if let message {
                    Text(message).foregroundStyle(.red)
                }
                MapReader { proxy in
                    Map(position: $camera) {
                        if hasLocation {
                            MapCircle(center: coordinate, radius: place.radius)
                                .foregroundStyle(.orange.opacity(0.25))
                                .stroke(.orange, lineWidth: 2)
                            Marker(place.name.isEmpty ? "Place" : place.name, coordinate: coordinate)
                                .tint(.orange)
                        }
                    }
                    .onTapGesture { point in
                        if let tapped = proxy.convert(point, from: .local) { setLocation(tapped) }
                    }
                }
                .frame(height: 220)
                LabeledContent("Radius: \(Int(place.radius)) m") {
                    Slider(value: $place.radius, in: SavedPlace.radiusRange, step: 25)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text("Click the map to move the place.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    place.name = place.name.trimmingCharacters(in: .whitespaces)
                    model.savePlace(place)
                    if model.locationStatus == .notDetermined { model.requestLocation() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasLocation || place.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
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
        if model.locationStatus == .notDetermined { model.requestLocation() }
        locating = true
        defer { locating = false }
        guard let coordinate = await model.placeMonitor?.currentCoordinate() else {
            message = "Couldn't find this Mac's location. Check that Nag can use it in System Settings."
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
