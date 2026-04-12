import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var viewModel: VPNViewModel
    @State private var showLogs = false

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) build \(b)"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient.appBackground
                    .ignoresSafeArea()

                Form {
                    Section("Xray Information") {
                        HStack {
                            Label("Version", systemImage: "info.circle")
                            Spacer()
                            Text(viewModel.xrayVersion)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Label("VPN Status", systemImage: viewModel.vpnManager.isConnected ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(viewModel.vpnManager.isConnected ? .green : .red)
                            Spacer()
                            Text(viewModel.vpnManager.statusText)
                                .foregroundColor(viewModel.vpnManager.isConnected ? .green : .red)
                        }
                    }

                    Section("Debugging") {
                        Button(action: { showLogs = true }) {
                            HStack {
                                Label("View Logs", systemImage: "terminal.fill")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                            .foregroundColor(.primary)
                        }

                        Button(action: { viewModel.clearLogs() }) {
                            Label("Clear Logs", systemImage: "trash.fill")
                                .foregroundColor(.red)
                        }

                        NavigationLink {
                            TunnelDebugLogsView()
                                .environmentObject(viewModel)
                        } label: {
                            HStack {
                                Label("Tunnel Debug Logs", systemImage: "ant.fill")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                            .foregroundColor(.primary)
                        }
                    }

                    Section("About") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("AntiDPI VPN")
                                .font(.headline)

                            Text(appVersion)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("Powered by Xray with anti-DPI capabilities")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showLogs) {
                LogsView()
                    .environmentObject(viewModel)
            }
        }
    }
}

struct LogsView: View {
    @EnvironmentObject var viewModel: VPNViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient.appBackground
                    .ignoresSafeArea()

                if viewModel.allLogs.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "terminal")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("No Logs")
                            .font(.headline)
                        Text("VPN events will appear here")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    List {
                        ForEach(viewModel.allLogs, id: \.self) { log in
                            Text(log)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(nil)
                                .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Event Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct TunnelDebugLogsView: View {
    @EnvironmentObject var viewModel: VPNViewModel
    @State private var logText = "Loading..."
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground).ignoresSafeArea()
            ScrollView {
                Text(logText)
                    .font(.system(.caption2, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Debug Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    Button(action: refreshLogs) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    ShareLink(item: logText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear { refreshLogs() }
    }

    private func refreshLogs() {
        isLoading = true
        let sharedLogs = viewModel.readSharedLogs()
        if sharedLogs != "No logs yet" {
            logText = sharedLogs
            isLoading = false
            return
        }
        viewModel.fetchTunnelLogs { result in
            DispatchQueue.main.async {
                logText = result
                isLoading = false
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(VPNViewModel())
}
