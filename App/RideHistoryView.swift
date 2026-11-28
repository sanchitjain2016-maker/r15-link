import SwiftUI

struct RideHistoryView: View {
    @EnvironmentObject var ble: BikeBLE

    var body: some View {
        List {
            if ble.rideHistory.isEmpty {
                Text("Connected sessions of 30 seconds or longer appear here after they end.")
                    .foregroundStyle(.secondary)
            }
            ForEach(ble.rideHistory) { ride in
                Section(ride.started.formatted(date: .abbreviated, time: .shortened)) {
                    LabeledContentRow(title: "Duration", value: duration(ride.duration))
                    LabeledContentRow(title: "Distance", value: metric(ride.distance, unit: "km"))
                    LabeledContentRow(title: "Average speed", value: metric(ride.averageSpeed, unit: "km/h"))
                    LabeledContentRow(title: "Top speed", value: ride.peakSpeed.map { "\($0) km/h" } ?? "—")
                }
            }
        }
        .navigationTitle("Ride history")
    }

    private func duration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: interval) ?? "—"
    }

    private func metric(_ value: Double?, unit: String) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1))) + " " + unit } ?? "—"
    }
}

private struct FuelFill: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let odometer: Double
    let litres: Double
}

struct FuelLogView: View {
    @EnvironmentObject var ble: BikeBLE
    @AppStorage("r15link.fuelFills") private var stored = Data()
    @State private var odometer = ""
    @State private var litres = ""
    @State private var message = ""

    private var fills: [FuelFill] { (try? JSONDecoder().decode([FuelFill].self, from: stored)) ?? [] }
    private var efficiency: Double? {
        guard fills.count >= 2, let first = fills.last, let last = fills.first else { return nil }
        let fuel = fills.dropLast().reduce(0) { $0 + $1.litres }
        return fuel > 0 ? (last.odometer - first.odometer) / fuel : nil
    }

    var body: some View {
        Form {
            Section("Fuel economy") {
                LabeledContentRow(title: "Average", value: efficiency.map {
                    $0.formatted(.number.precision(.fractionLength(1))) + " km/L"
                } ?? "Two full fills needed")
                Text("Log only full-tank fills to measure fuel economy.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Add a full fill") {
                TextField("Odometer in km", text: $odometer).keyboardType(.decimalPad)
                TextField("Litres added", text: $litres).keyboardType(.decimalPad)
                Button("Save fill", action: save)
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if !fills.isEmpty {
                Section("Fuel history") {
                    ForEach(fills) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                            Text("\(entry.odometer.formatted()) km · \(entry.litres.formatted()) L")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Fuel log")
        .onAppear {
            if odometer.isEmpty, let reading = ble.telemetry.odometer {
                odometer = reading.formatted(.number.grouping(.never).precision(.fractionLength(1)))
            }
        }
    }

    private func save() {
        let format = NumberFormatter()
        format.numberStyle = .decimal
        format.allowsFloats = true
        guard let distance = format.number(from: odometer)?.doubleValue,
              let volume = format.number(from: litres)?.doubleValue,
              distance.isFinite, volume.isFinite, distance >= 0, volume > 0 else {
            message = "Enter a valid odometer reading and litres added."
            return
        }
        if let latest = fills.first, distance <= latest.odometer {
            message = "The odometer reading must be higher than the previous fill."
            return
        }
        let rows = [FuelFill(date: .now, odometer: distance, litres: volume)] + fills
        if let data = try? JSONEncoder().encode(rows) {
            stored = data
            litres = ""
            message = "Full fill saved."
        }
    }
}
