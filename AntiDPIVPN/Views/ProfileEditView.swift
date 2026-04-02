import SwiftUI

struct ProfileEditView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var viewModel: VPNViewModel
    @State private var profile: VPNProfile
    @State private var isNew: Bool = false
    @State private var portString: String = ""

    init(profile: VPNProfile, isNew: Bool = false) {
        _profile = State(initialValue: profile)
        _isNew = State(initialValue: isNew)
        _portString = State(initialValue: String(profile.serverPort))
    }

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
                    Section("Profile Name") {
                        TextField("Profile Name", text: $profile.name)
                    }

                    Section("Server Settings") {
                        TextField("Server Address", text: $profile.serverAddress)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        HStack {
                            Text("Port")
                            Spacer()
                            TextField("443", text: $portString)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 100)
                                .onChange(of: portString) { newValue in
                                    let filtered = newValue.filter { $0.isNumber }
                                    if filtered != newValue {
                                        portString = filtered
                                    }
                                    if let port = Int(filtered), port >= 1 && port <= 65535 {
                                        profile.serverPort = port
                                    }
                                }
                        }
                    }

                    Section("UUID") {
                        TextField("UUID", text: $profile.uuid)
                            .font(.system(.caption, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }

                    Section("REALITY Settings") {
                        TextField("Public Key", text: $profile.realityPublicKey)
                            .font(.system(.caption, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        TextField("Short ID", text: $profile.realityShortId)
                            .font(.system(.caption, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        TextField("Server Name (SNI)", text: $profile.realityServerName)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)

                        Picker("Fingerprint", selection: $profile.realityFingerprint) {
                            ForEach(["chrome", "firefox", "safari", "edge"], id: \.self) { fp in
                                Text(fp).tag(fp)
                            }
                        }
                    }

                    Section(header: Text("NFS Encryption"), footer: Text("X25519 public key for NFS encryption layer. Required when Anti-DPI is enabled.")) {
                        TextField("NFS Public Key", text: $profile.nfsPublicKey)
                            .font(.system(.caption, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }

                    Section {
                        NavigationLink("Anti-DPI Settings", destination: AntiDPISettingsView(settings: $profile.antiDPISettings))
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(isNew ? "New Profile" : profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Ensure port is valid before saving
                        if let port = Int(portString), port >= 1 && port <= 65535 {
                            profile.serverPort = port
                        }
                        if isNew {
                            viewModel.addProfile(profile)
                        } else {
                            viewModel.updateProfile(profile)
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ProfileEditView(profile: VPNProfile(), isNew: true)
        .environmentObject(VPNViewModel())
}
