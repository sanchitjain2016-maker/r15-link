import SwiftUI

@main
struct R15LinkApp: App {
    @StateObject private var ble = BikeBLE()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(ble)
        }
    }
}
