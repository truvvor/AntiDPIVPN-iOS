import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var viewModel: VPNViewModel
    @State private var showLogs = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1) : UIColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 1) }),
                        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.15, green: 0.11, blue: 0.15, alpha: 1) : UIColor(red: 0.95, green: 0.93, blue: 0.98, alpha: 1) })
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Form {
                    Section("Connection Settings") {
                        HStack {
                            Label("SOCKS Port", systemImage: "network")
                            Spacer()
                            TextField("Port", value: $viewModel.socksPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.numberPad)
                                .frame(width: 80)
                        }

                        Text("Default SOCKS proxy port is 3080")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Section("Routing") {
                        NavigationLink {
                            RoutingSettingsView()
                                .environmentObject(viewModel)
                        } label: {
                            HStack {
                                Label("Routing Rules", systemImage: "arrow.triangle.branch")
                                Spacer()
                                if !viewModel.globalRoute.isEmpty {
                                    Text("\(viewModel.globalRoute.rules.count) rules")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("None")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .foregroundColor(.primary)
                        }
                    }

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

                        Button(action: {
                            viewModel.clearLogs()
                        }) {
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

                            Text("Version 1.0.0")
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
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1) : UIColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 1) }),
                        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.15, green: 0.11, blue: 0.15, alpha: 1) : UIColor(red: 0.95, green: 0.93, blue: 0.98, alpha: 1) })
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
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
                            VStack(alignment: .leading, spacing: 4) {
                                Text(log)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(nil)
                                    .foregroundColor(.primary)
                            }
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
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct TunnelDebugLogsView: View {
    @EnvironmentObject var viewModel: VPNViewModel
    @State private var logText: String = "Loading..."
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
        // Try reading from shared container first
        let sharedLogs = viewModel.readSharedLogs()
        if sharedLogs != "No logs yet" {
            logText = sharedLogs
            isLoading = false
            return
        }

        // Fallback: try via tunnel message
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
