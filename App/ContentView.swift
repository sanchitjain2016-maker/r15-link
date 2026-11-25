import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ble: BikeBLE
    @State private var raw = ""
    @State private var showConfig = false

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                statusBar
                telemetry
                controls
                logView
            }
            .padding(.horizontal, 12)
            .navigationTitle("R15 M · Link")
            .toolbar { Button { showConfig.toggle() } label: { Image(systemName: "gearshape") } }
            .sheet(isPresented: $showConfig) { config }
        }
    }

    var statusBar: some View {
        HStack {
            Circle().fill(ble.connected ? .green : .gray).frame(width: 10, height: 10)
            Text(ble.status).font(.subheadline.weight(.semibold))
            Spacer()
            Toggle("auto-reconnect", isOn: $ble.autoReconnect).labelsHidden()
            Text("auto").font(.caption).foregroundColor(.secondary)
        }
        .padding(10).background(Color(.secondarySystemBackground)).cornerRadius(10)
    }

    var telemetry: some View {
        HStack {
            tile("packets", "\(ble.rxCount)")
            tile("last opcode", ble.lastOpcode)
        }
    }
    func tile(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption2).foregroundColor(.secondary)
            Text(v).font(.title3.monospaced().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(Color(.secondarySystemBackground)).cornerRadius(10)
    }

    var controls: some View {
        VStack(spacing: 8) {
            Button { ble.start() } label: { Label("Connect & Authenticate", systemImage: "bolt.horizontal.circle") .frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
            HStack {
                Button("Send Auth") { ble.sendAuth() }.buttonStyle(.bordered)
                Button("Stop") { ble.stop() }.buttonStyle(.bordered).tint(.red)
            }
            HStack {
                TextField("raw hex e.g. 0101…", text: $raw).textFieldStyle(.roundedBorder).font(.system(.footnote, design: .monospaced)).autocapitalization(.none)
                Button("TX") { ble.sendRaw(raw) }.buttonStyle(.bordered)
            }
        }
    }

    var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text("log").font(.caption).foregroundColor(.secondary); Spacer()
                Button("clear") { ble.clearLog() }.font(.caption) }
            ScrollViewReader { pr in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(ble.log) { l in
                            Text(l.text).font(.system(size: 11, design: .monospaced))
                                .foregroundColor(color(l.kind)).frame(maxWidth: .infinity, alignment: .leading).id(l.id)
                        }
                    }.padding(8)
                }
                .background(Color(.systemBackground)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator)))
                .onChange(of: ble.log.count) { _ in if let last = ble.log.last { withAnimation { pr.scrollTo(last.id) } } }
            }
        }
    }
    func color(_ k: String) -> Color { k == "tx" ? .blue : k == "rx" ? .green : k == "er" ? .red : .secondary }

    var config: some View {
        NavigationView {
            Form {
                Section("Credentials (from Yamaha cloud)") {
                    LabeledTextField("ccuId (hex)", $ble.ccuId)
                    LabeledTextField("passKey", $ble.passKey)
                    Picker("passKey encoding", selection: $ble.passEncoding) {
                        Text("ASCII").tag("ascii"); Text("hex").tag("hex")
                        Text("uint32 BE").tag("int4"); Text("uint24 BE").tag("int3")
                    }
                }
                Section("Auth frame preview") {
                    Text(ble.hex(ble.authFrame())).font(.system(.footnote, design: .monospaced))
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { showConfig = false } }
        }
    }
}

struct LabeledTextField: View {
    let label: String; @Binding var text: String
    init(_ l: String, _ t: Binding<String>) { label = l; _text = t }
    var body: some View {
        HStack { Text(label).foregroundColor(.secondary)
            TextField("", text: $text).multilineTextAlignment(.trailing).font(.system(.body, design: .monospaced)).autocapitalization(.none) }
    }
}
