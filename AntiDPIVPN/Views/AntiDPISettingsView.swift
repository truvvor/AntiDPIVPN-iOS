import SwiftUI

struct AntiDPISettingsView: View {
    @Binding var settings: AntiDPISettings
    @ObservedObject var viewModel: VPNViewModel

    var body: some View {
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
                Section("Master Control") {
                    Toggle("Anti-DPI Enabled", isOn: $settings.enabled)
                }

                if settings.enabled {
                    // === ADAPTIVE ANTI-DPI ===
                    Section {
                        Toggle("Adaptive Mode", isOn: $settings.adaptiveEnabled)

                        if settings.adaptiveEnabled {
                            HStack {
                                Text("Current Level")
                                Spacer()
                                Text(viewModel.adaptiveLevelDescription)
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }

                            if !viewModel.adaptiveStatus.isEmpty {
                                HStack {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .foregroundColor(.blue)
                                    Text(viewModel.adaptiveStatus)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Button("Reset to Default Level") {
                                viewModel.resetAdaptiveLevel()
                            }
                            .foregroundColor(.orange)
                        }
                    } header: {
                        Label("Adaptive Anti-DPI", systemImage: "brain.head.profile")
                    } footer: {
                        Text("Auto-adjusts global bandwidth limit to evade DPI. Reduces on disconnect, increases after 5 min stable. Levels: 1/3/8/20/unlimited MB/s.")
                    }

                    // === MANUAL BANDWIDTH (when adaptive is off) ===
                    if !settings.adaptiveEnabled {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Global Bandwidth Limit")
                                    Spacer()
                                    Text(settings.bandwidthLimitKBs > 0 ? "\(settings.bandwidthLimitKBs / 1024) MB/s" : "Unlimited")
                                        .foregroundColor(.secondary)
                                }
                                Slider(
                                    value: Binding(
                                        get: { Double(settings.bandwidthLimitKBs) },
                                        set: { settings.bandwidthLimitKBs = Int($0) }
                                    ),
                                    in: 0...51200,
                                    step: 1024
                                )
                            }
                        } header: {
                            Label("Bandwidth Control", systemImage: "gauge.with.dots.needle.bottom.50percent")
                        } footer: {
                            Text("Global limit shared across all connections. Lower = stealthier. 0 = unlimited.")
                        }
                    }

                    Section("Scatter") {
                        Toggle("Scatter", isOn: $settings.scatterEnabled)

                        if settings.scatterEnabled {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Min Bytes")
                                    Spacer()
                                    Text("\(settings.scatterMinBytes)")
                                        .foregroundColor(.secondary)
                                }
                                Slider(
                                    value: Binding(get: { Double(settings.scatterMinBytes) }, set: { settings.scatterMinBytes = Int($0) }),
                                    in: 64...256,
                                    step: 1
                                ) { _ in }
                                .onChange(of: settings.scatterMinBytes) { _ in
                                    if settings.scatterMinBytes > settings.scatterMaxBytes {
                                        settings.scatterMaxBytes = settings.scatterMinBytes
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Max Bytes")
                                    Spacer()
                                    Text("\(settings.scatterMaxBytes)")
                                        .foregroundColor(.secondary)
                                }
                                Slider(
                                    value: Binding(get: { Double(settings.scatterMaxBytes) }, set: { settings.scatterMaxBytes = Int($0) }),
                                    in: Double(settings.scatterMinBytes)...Double(1024),
                                    step: 1
                                ) { _ in }
                            }
                        }
                    }

                    Section("Heartbeat") {
                        Toggle("Heartbeat", isOn: $settings.heartbeatEnabled)

                        if settings.heartbeatEnabled {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Min Interval (s)")
                                    Spacer()
                                    Text("\(settings.heartbeatMinInterval)")
                                        .foregroundColor(.secondary)
                                }
                                Slider(
                                    value: Binding(get: { Double(settings.heartbeatMinInterval) }, set: { settings.heartbeatMinInterval = Int($0) }),
                                    in: 1...30,
                                    step: 1
                                ) { _ in }
                                .onChange(of: settings.heartbeatMinInterval) { _ in
                                    if settings.heartbeatMinInterval > settings.heartbeatMaxInterval {
                                        settings.heartbeatMaxInterval = settings.heartbeatMinInterval
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Max Interval (s)")
                                    Spacer()
                                    Text("\(settings.heartbeatMaxInterval)")
                                        .foregroundColor(.secondary)
                                }
                                Slider(
                                    value: Binding(get: { Double(settings.heartbeatMaxInterval) }, set: { settings.heartbeatMaxInterval = Int($0) }),
                                    in: Double(settings.heartbeatMinInterval)...Double(60),
                                    step: 1
                                ) { _ in }
                            }
                        }
                    }

                    Section("Random Record Sizes") {
                        Toggle("Enable Random Record Sizes", isOn: $settings.randomRecordSizes)
                    }

                    Section("Header Padding") {
                        Toggle("Header Padding", isOn: $settings.headerPaddingEnabled)

                        if settings.headerPaddingEnabled {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Min Bytes")
                                    Spacer()
                                    Text("\(settings.headerPaddingMinBytes)")
                                        .foregroundColor(.secondary)
                                }
                                Slider(
                                    value: Binding(get: { Double(settings.headerPaddingMinBytes) }, set: { settings.headerPaddingMinBytes = Int($0) }),
                                    in: 8...64,
                                    step: 1
                                ) { _ in }
                                .onChange(of: settings.headerPaddingMinBytes) { _ in
                                    if settings.headerPaddingMinBytes > settings.headerPaddingMaxBytes {
                                        settings.headerPaddingMaxBytes = settings.headerPaddingMinBytes
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Max Bytes")
                                    Spacer()
                                    Text("\(settings.headerPaddingMaxBytes)")
                                        .foregroundColor(.secondary)
                                }
                                Slider(
                                    value: Binding(get: { Double(settings.headerPaddingMaxBytes) }, set: { settings.headerPaddingMaxBytes = Int($0) }),
                                    in: Double(settings.headerPaddingMinBytes)...Double(128),
                                    step: 1
                                ) { _ in }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Anti-DPI Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AntiDPISettingsView(settings: .constant(AntiDPISettings()), viewModel: VPNViewModel())
    }
}
