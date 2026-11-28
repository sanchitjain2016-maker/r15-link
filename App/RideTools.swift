import AVFoundation
import CallKit
import CoreLocation
import MapKit
import MediaPlayer
import SwiftUI
import UserNotifications

private final class CallStatus: NSObject, ObservableObject, CXCallObserverDelegate {
    @Published private(set) var summary = "No active call"
    private let observer = CXCallObserver()

    override init() {
        super.init()
        observer.setDelegate(self, queue: .main)
        refresh()
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) { refresh() }

    private func refresh() {
        if let call = observer.calls.first(where: { !$0.hasEnded }) {
            summary = call.isOnHold ? "Call on hold" : call.hasConnected ? "Call in progress"
                : call.isOutgoing ? "Outgoing call" : "Incoming call"
        } else {
            summary = "No active call"
        }
    }
}

struct PhoneToolsView: View {
    @EnvironmentObject var ble: BikeBLE
    @Environment(\.openURL) private var openURL
    @StateObject private var calls = CallStatus()
    @AppStorage("r15link.connectionAlerts") private var alerts = false
    @State private var alertStatus = ""
    @State private var musicAccess = MPMediaLibrary.authorizationStatus()
    @State private var track = "No track playing in Apple Music"
    @State private var playing = false
    @State private var audioRoute = ""
    @State private var number = ""
    @State private var watchingMusic = false
    private var player: MPMusicPlayerController { .systemMusicPlayer }

    var body: some View {
        Form {
            Section("Apple Music") {
                if musicAccess == .authorized {
                    Text(track)
                    HStack {
                        Spacer()
                        playbackButton("Previous track", icon: "backward.fill") { player.skipToPreviousItem() }
                        Spacer()
                        playbackButton(playing ? "Pause" : "Play", icon: playing ? "pause.fill" : "play.fill") {
                            playing ? player.pause() : player.play()
                            refreshMusic()
                        }
                        Spacer()
                        playbackButton("Next track", icon: "forward.fill") { player.skipToNextItem() }
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                } else if musicAccess == .notDetermined {
                    Button("Enable Apple Music controls") {
                        MPMediaLibrary.requestAuthorization { status in
                            DispatchQueue.main.async {
                                musicAccess = status
                                startWatchingMusic()
                            }
                        }
                    }
                } else {
                    Text("Allow Media & Apple Music access in iPhone Settings to use playback controls.")
                        .foregroundStyle(.secondary)
                }
                LabeledContentRow(title: "iPhone audio output", value: audioRoute)
            }
            Section("Calls") {
                Text(calls.summary)
                TextField("Phone number", text: $number).keyboardType(.phonePad)
                Button("Call with iPhone") {
                    let digits = number.filter { $0.isASCII && $0.isNumber }
                    let dial = (number.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : "") + digits
                    if let url = URL(string: "tel:" + dial) { openURL(url) }
                }
                .disabled(number.filter { $0.isASCII && $0.isNumber }.isEmpty)
            }
            Section("Notifications") {
                LabeledContentRow(title: "Bike notification sharing",
                                  value: ble.connected ? (ble.notificationSharing ? "Authorized" : "Not authorized") : "Bike disconnected")
                if ble.connected && !ble.notificationSharing {
                    Text("If the bike offers Share System Notifications in iPhone Bluetooth settings, enable it there for dashboard alerts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Toggle("Bike connection alerts", isOn: Binding(get: { alerts }, set: setAlerts))
                if !alertStatus.isEmpty {
                    Text(alertStatus).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Phone & media")
        .onAppear {
            musicAccess = MPMediaLibrary.authorizationStatus()
            startWatchingMusic()
            refreshRoute()
        }
        .onDisappear {
            if watchingMusic { player.endGeneratingPlaybackNotifications(); watchingMusic = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerNowPlayingItemDidChange).receive(on: RunLoop.main)) { _ in refreshMusic() }
        .onReceive(NotificationCenter.default.publisher(for: .MPMusicPlayerControllerPlaybackStateDidChange).receive(on: RunLoop.main)) { _ in refreshMusic() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in refreshRoute() }
    }

    private func playbackButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).frame(width: 44, height: 44)
        }
        .accessibilityLabel(title)
    }

    private func startWatchingMusic() {
        guard musicAccess == .authorized else { return }
        if !watchingMusic { player.beginGeneratingPlaybackNotifications(); watchingMusic = true }
        refreshMusic()
    }

    private func refreshMusic() {
        guard musicAccess == .authorized, watchingMusic else { return }
        let item = player.nowPlayingItem
        track = [item?.title, item?.artist].compactMap { $0 }.joined(separator: " · ")
        if track.isEmpty { track = "No track playing in Apple Music" }
        playing = player.playbackState == .playing
    }

    private func refreshRoute() {
        audioRoute = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ")
        if audioRoute.isEmpty { audioRoute = "No active output" }
    }

    private func setAlerts(_ enabled: Bool) {
        alertStatus = ""
        guard enabled else { alerts = false; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                alerts = granted
                if !granted { alertStatus = error?.localizedDescription ?? "Allow notifications in iPhone Settings." }
            }
        }
    }
}

struct LabeledContentRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ParkingPin: Codable {
    let latitude: Double
    let longitude: Double
    let savedAt: Date
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

private final class ParkingLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var pin: ParkingPin?
    @Published private(set) var message = ""
    private let manager = CLLocationManager()
    private let storageKey = "r15link.parkingPin"
    private var saving = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            pin = try? JSONDecoder().decode(ParkingPin.self, from: data)
        }
    }

    func save() {
        guard !saving else { return }
        saving = true
        message = "Getting the iPhone’s location…"
        requestIfAuthorized()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if saving, manager.authorizationStatus != .notDetermined { requestIfAuthorized() }
    }

    private func requestIfAuthorized() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default:
            saving = false
            message = "Allow location access in iPhone Settings to save a parking pin."
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard saving else { return }
        saving = false
        guard let location = locations.last, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 60 else {
            message = "A recent GPS position is unavailable. Try again outside."
            return
        }
        let saved = ParkingPin(latitude: location.coordinate.latitude,
                               longitude: location.coordinate.longitude, savedAt: .now)
        pin = saved
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: storageKey)
        message = "Parking pin saved from this iPhone."
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        saving = false
        message = error.localizedDescription
    }
}

struct NavigationToolsView: View {
    @StateObject private var parking = ParkingLocation()
    @State private var destination = ""
    @State private var matches: [MKMapItem] = []
    @State private var searching = false
    @State private var searchStatus = ""

    var body: some View {
        Form {
            Section("Directions") {
                TextField("Destination", text: $destination).submitLabel(.search).onSubmit(search)
                Button(searching ? "Searching…" : "Find in Apple Maps", action: search)
                    .disabled(searching || destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !searchStatus.isEmpty { Text(searchStatus).foregroundStyle(.secondary) }
                ForEach(matches.indices, id: \.self) { index in
                    let item = matches[index]
                    Button {
                        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name ?? "Destination")
                            if let address = item.placemark.title {
                                Text(address).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Parked bike") {
                Button("Save my parking spot", action: parking.save)
                if let pin = parking.pin {
                    Text(pin.savedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Directions to parked bike") {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: pin.coordinate))
                        item.name = "Parked bike"
                        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                    }
                }
                if !parking.message.isEmpty {
                    Text(parking.message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Navigation")
    }

    private func search() {
        let query = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !searching else { return }
        searching = true
        searchStatus = ""
        matches = []
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        Task { @MainActor in
            defer { searching = false }
            do {
                matches = try await MKLocalSearch(request: request).start().mapItems
                if matches.isEmpty { searchStatus = "No matching destinations." }
            } catch {
                searchStatus = "Apple Maps search is unavailable. Try again or refine the destination."
            }
        }
    }
}
