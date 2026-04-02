import SwiftUI

@main
struct AntiDPIVPNApp: App {
    @StateObject private var vpnViewModel = VPNViewModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Connect", systemImage: "link.circle.fill") {
                    ConnectView()
                        .environmentObject(vpnViewModel)
                }

                Tab("Profiles", systemImage: "list.bullet.circle.fill") {
                    ProfilesView()
                        .environmentObject(vpnViewModel)
                }

                Tab("Settings", systemImage: "gear.circle.fill") {
                    SettingsView()
                        .environmentObject(vpnViewModel)
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        }
    }
}
