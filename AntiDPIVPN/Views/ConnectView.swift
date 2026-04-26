import SwiftUI
import NetworkExtension

struct ConnectView: View {
    @EnvironmentObject var viewModel: VPNViewModel
    @State private var showProfileSelector = false

    private var isConnected: Bool {
        viewModel.vpnManager.status == .connected
    }

    private var isConnecting: Bool {
        viewModel.vpnManager.status == .connecting || viewModel.vpnManager.status == .reasserting
    }

    var body: some View {
        VStack {
            ZStack {
                LinearGradient.appBackground
                .ignoresSafeArea()

                VStack(spacing: 32) {
                    // Header
                    VStack(spacing: 12) {
                        Text("Vinoterra VPN")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)

                        if !viewModel.currentProfile.name.isEmpty {
                            Text(viewModel.currentProfile.name)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 20)

                    Spacer()

                    // Connection Status
                    VStack(spacing: 20) {
                        Button(action: {
                            if isConnected {
                                viewModel.disconnectVPN()
                            } else if !isConnecting {
                                viewModel.connectVPN()
                            }
                        }) {
                            ZStack {
                                Circle()
                                    .fill(isConnected ? Color.green : (isConnecting ? Color.orange : Color.blue))
                                    .frame(width: 160, height: 160)
                                    .shadow(color: isConnected ? Color.green.opacity(0.4) : Color.blue.opacity(0.4), radius: 12)

                                VStack(spacing: 8) {
                                    if isConnecting {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                            .scaleEffect(1.5)
                                    } else {
                                        Image(systemName: isConnected ? "checkmark.circle.fill" : "play.circle.fill")
                                            .font(.system(size: 48))
                                            .foregroundColor(.white)
                                    }

                                    Text(viewModel.vpnManager.statusText)
                                        .font(.headline)
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .disabled(isConnecting)
                        .accessibilityIdentifier("ConnectButton")

                        // Status Details
                        VStack(spacing: 8) {
                            HStack {
                                Label("Server", systemImage: "server.rack")
                                Spacer()
                                Text(viewModel.currentProfile.serverAddress)
                                    .font(.monospaced(.footnote)())
                            }
                            .foregroundColor(.secondary)

                            HStack {
                                Label("Port", systemImage: "network")
                                Spacer()
                                Text("\(viewModel.currentProfile.serverPort)")
                                    .font(.monospaced(.footnote)())
                            }
                            .foregroundColor(.secondary)

                            if let errorMsg = viewModel.vpnManager.errorMessage {
                                HStack {
                                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                    Spacer()
                                    Text(errorMsg)
                                        .font(.caption)
                                        .lineLimit(3)
                                }
                                .foregroundColor(.red)
                            }
                        }
                        .font(.system(.footnote, design: .monospaced))
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }

                    Spacer()

                    // Profile Selector
                    VStack(spacing: 12) {
                        Text("Current Profile")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Menu {
                            ForEach(viewModel.profiles) { profile in
                                Button(action: { viewModel.setCurrentProfile(profile) }) {
                                    HStack {
                                        Text(profile.name.isEmpty ? "Unnamed" : profile.name)
                                        if profile.id == viewModel.currentProfile.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "rectangle.stack.fill")
                                Text(viewModel.currentProfile.name.isEmpty ? "Select Profile" : viewModel.currentProfile.name)
                                Spacer()
                                Image(systemName: "chevron.down")
                            }
                            .padding(12)
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                            .foregroundColor(.primary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 20)
                }
                .padding()
            }
        }
    }
}

#Preview {
    ConnectView()
        .environmentObject(VPNViewModel())
}
