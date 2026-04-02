import SwiftUI

struct ConnectView: View {
    @EnvironmentObject var viewModel: VPNViewModel
    @State private var showProfileSelector = false

    var body: some View {
        VStack {
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

                VStack(spacing: 32) {
                    // Header
                    VStack(spacing: 12) {
                        Text("AntiDPI VPN")
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
                        // Large Connection Button
                        Button(action: {
                            if viewModel.xrayService.isRunning {
                                viewModel.disconnectVPN()
                            } else {
                                viewModel.connectVPN()
                            }
                        }) {
                            ZStack {
                                Circle()
                                    .fill(viewModel.xrayService.isRunning ? Color.green : Color.blue)
                                    .frame(width: 160, height: 160)
                                    .shadow(color: viewModel.xrayService.isRunning ? Color.green.opacity(0.4) : Color.blue.opacity(0.4), radius: 12)

                                VStack(spacing: 8) {
                                    Image(systemName: viewModel.xrayService.isRunning ? "checkmark.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 48))
                                        .foregroundColor(.white)

                                    Text(viewModel.xrayService.isRunning ? "Connected" : "Disconnected")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                }
                            }
                        }

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

                            if let errorMsg = viewModel.xrayService.errorMessage {
                                HStack {
                                    Label("Error", systemImage: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                    Spacer()
                                    Text(errorMsg)
                                        .font(.caption)
                                        .lineLimit(2)
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
                                        Text(profile.name)
                                        if profile.id == viewModel.currentProfile.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "rectangle.stack.fill")
                                Text(viewModel.currentProfile.name)
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
            .onAppear {
                viewModel.refreshVPNState()
            }
        }
    }
}

#Preview {
    ConnectView()
        .environmentObject(VPNViewModel())
}
