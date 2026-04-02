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

                    Section("Xray Information") {
                        HStack {
                            Label("Version", systemImage: "info.circle")
                            Spacer()
                            Text(viewModel.xrayService.version)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Label("Status", systemImage: viewModel.xrayService.isRunning ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(viewModel.xrayService.isRunning ? .green : .red)
                            Spacer()
                            Text(viewModel.xrayService.isRunning ? "Running" : "Stopped")
                                .foregroundColor(viewModel.xrayService.isRunning ? .green : .red)
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

                            Link("Visit Xray Project", destination: URL(string: "https://github.com/XTLS/Xray-core")!)
                                .font(.caption)
                                .foregroundColor(.blue)
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

                if viewModel.logs.isEmpty {
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
                        ForEach(viewModel.logs, id: \.self) { log in
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

#Preview {
    SettingsView()
        .environmentObject(VPNViewModel())
}
