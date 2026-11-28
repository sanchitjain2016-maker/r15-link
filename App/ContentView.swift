import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var ble: BikeBLE
    @State private var raw = ""
    @State private var showConfig = false
    @State private var copiedLog = false

    private let accent = Color(red: 1, green: 0.83, blue: 0.25)
    private let canvas = Color(red: 0.04, green: 0.04, blue: 0.05)
    private let panel = Color(red: 0.09, green: 0.09, blue: 0.11)
    private let outline = Color.white.opacity(0.1)
    private let detail = Color.white.opacity(0.67)

    var body: some View {
        ZStack {
            canvas.ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(0.12), .clear],
                           center: .topTrailing, startRadius: 8, endRadius: 290)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    connectionPanel
                    telemetry
                    if !ble.found.isEmpty { devicesList }
                    logView
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .tint(accent)
        .sheet(isPresented: $showConfig) { settings }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(accent).frame(width: 34, height: 3)
                    .accessibilityHidden(true)
                Text("R15 LINK")
                    .font(.system(.largeTitle, design: .monospaced).weight(.black))
                    .tracking(1)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 12)
            Button { showConfig = true } label: {
                Image(systemName: "gearshape")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(outline))
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .accessibilityLabel("Settings")
        }
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("Connection")
                Spacer()
                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(detail)
            }
            Label {
                Text(ble.status).font(.headline).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: ble.connected ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(ble.connected ? accent : detail)
            }
            Button { ble.start() } label: {
                Label("Connect & Authenticate", systemImage: "bolt.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .padding(.horizontal, 8)
                    .foregroundStyle(.black)
                    .background(accent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            HStack {
                Button("Send Auth") { ble.sendAuth() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Stop", role: .destructive) { ble.stop() }
                    .buttonStyle(.bordered)
            }
            Divider()
            Toggle("Auto-reconnect", isOn: $ble.autoReconnect)
                .font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .panelSurface(panel, outline: outline)
    }

    private var telemetry: some View {
        HStack(spacing: 10) {
            tile("Packets", "\(ble.rxCount)")
            tile("Last opcode", ble.lastOpcode)
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(title)
            Text(value).font(.system(.title2, design: .monospaced).weight(.semibold))
                .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .panelSurface(panel, outline: outline)
        .accessibilityElement(children: .combine)
    }

    private var devicesList: some View {
        DisclosureGroup {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(ble.found.sorted { $0.rssi > $1.rssi }) { device in
                        Button { ble.connectTo(device.peripheral) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: device.name.uppercased().contains("YCCU") ? "bolt.fill" : "antenna.radiowaves.left.and.right")
                                    .foregroundStyle(accent)
                                Text(device.name)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text("\(device.rssi) dBm")
                                    .foregroundStyle(detail)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 38)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
            }
            .frame(height: CGFloat(min(ble.found.count, 3)) * 44)
        } label: {
            sectionTitle("Nearby devices")
        }
        .padding(14)
        .panelSurface(panel, outline: outline)
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                sectionTitle("Connection log")
                Spacer(minLength: 0)
                Button(copiedLog ? "Copied" : "Copy Log") {
                    UIPasteboard.general.string = ble.diagnosticLog
                    copiedLog = true
                }
                .disabled(ble.log.isEmpty)
                Button("Clear") { ble.clearLog() }
                    .disabled(ble.log.isEmpty)
                    .foregroundStyle(detail)
            }
            .font(.caption.weight(.semibold))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if ble.log.isEmpty {
                            Text("Connection events will appear here.").foregroundStyle(detail)
                        }
                        ForEach(ble.log) { line in
                            Text(line.text)
                                .foregroundStyle(logColor(line.kind))
                                .id(line.id)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(height: 168)
                .panelSurface(canvas, outline: outline, radius: 8)
                .onChange(of: ble.log.last?.id) { id in
                    copiedLog = false
                    if let id = id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            HStack {
                TextField("Raw hex", text: $raw)
                    .font(.system(.caption, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Send Hex") { ble.sendRaw(raw) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .panelSurface(panel, outline: outline)
    }

    private var settings: some View {
        NavigationView {
            Form {
                Section("Yamaha credentials") {
                    TextField("Bike ID", text: $ble.ccuId)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    SecureField("Six-digit passkey", text: $ble.passKey)
                        .keyboardType(.numberPad)
                }
                .listRowBackground(panel)
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { showConfig = false } }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
        .tint(accent)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(detail)
    }

    private func logColor(_ kind: String) -> Color {
        switch kind {
        case "tx": return accent
        case "rx": return Color(red: 0.5, green: 0.9, blue: 0.77)
        case "er": return Color(red: 1, green: 0.55, blue: 0.52)
        default: return detail
        }
    }
}

private extension View {
    func panelSurface(_ color: Color, outline: Color, radius: CGFloat = 13) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return background(color, in: shape).overlay(shape.strokeBorder(outline))
    }
}
