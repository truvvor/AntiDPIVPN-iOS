import SwiftUI

struct ProfileEditView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var viewModel: VPNViewModel
    @State private var profile: VPNProfile
    @State private var isNew: Bool = false
    @State private var portString: String = ""
    @State private var showShareSheet = false
    @State private var showImportURL = false
    @State private var importURLText = ""
    @State private var importError: String? = nil
    @State private var shareURL: String = ""
    @State private var showRouteImport = false
    @State private var routeImportText = ""
    @State private var routeImportError: String? = nil
    @State private var dnsText: String = ""

    init(profile: VPNProfile, isNew: Bool = false) {
        _profile = State(initialValue: profile)
        _isNew = State(initialValue: isNew)
        _portString = State(initialValue: String(profile.serverPort))
        _dnsText = State(initialValue: profile.dnsServers.joined(separator: ", "))
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
                    // Import from URL section for new profiles
                    if isNew {
                        Section {
                            Button(action: {
                                if let text = UIPasteboard.general.string,
                                   text.lowercased().hasPrefix("vless://") {
                                    importURLText = text
                                } else {
                                    importURLText = ""
                                }
                                importError = nil
                                showImportURL = true
                            }) {
                                Label("Import from URL", systemImage: "link.badge.plus")
                            }
                        }
                    }

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

                    Section(header: Text("DNS Servers"), footer: Text("Comma-separated. Empty = Google DNS (8.8.8.8). Examples: 1.1.1.1, 8.8.8.8")) {
                        TextField("8.8.8.8, 2001:4860:4860::8888", text: $dnsText)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .onChange(of: dnsText) { newValue in
                                profile.dnsServers = newValue
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }
                            }
                    }

                    Section(header: Text("Routing"), footer: routeFooter) {
                        if profile.routeConfig.isEmpty {
                            Button(action: {
                                if let text = UIPasteboard.general.string,
                                   text.lowercased().hasPrefix("streisand://") {
                                    routeImportText = text
                                } else {
                                    routeImportText = ""
                                }
                                routeImportError = nil
                                showRouteImport = true
                            }) {
                                Label("Import Route from Streisand", systemImage: "arrow.triangle.branch")
                            }
                        } else {
                            HStack {
                                Label(profile.routeConfig.name, systemImage: "arrow.triangle.branch")
                                    .font(.headline)
                                Spacer()
                                Text("\(profile.routeConfig.rules.count) rules")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            NavigationLink("View Rules") {
                                RouteRulesView(routeConfig: profile.routeConfig)
                            }

                            Button(role: .destructive) {
                                profile.routeConfig = RouteConfig()
                            } label: {
                                Label("Remove Route", systemImage: "trash")
                            }

                            Button(action: {
                                routeImportText = ""
                                routeImportError = nil
                                showRouteImport = true
                            }) {
                                Label("Replace Route", systemImage: "arrow.triangle.branch")
                            }
                        }
                    }

                    Section {
                        NavigationLink("Anti-DPI Settings", destination: AntiDPISettingsView(settings: $profile.antiDPISettings, viewModel: viewModel))
                    }

                    // Share URL section for existing profiles
                    if !isNew {
                        Section("Share") {
                            Button(action: {
                                shareURL = VLESSURLParser.generate(from: profile)
                                UIPasteboard.general.string = shareURL
                            }) {
                                Label("Copy Share URL", systemImage: "doc.on.doc")
                            }
                        }
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
            .alert("Import from URL", isPresented: $showImportURL) {
                TextField("vless://...", text: $importURLText)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("Import") {
                    do {
                        let parsed = try VLESSURLParser.parse(importURLText)
                        profile = parsed
                        portString = String(parsed.serverPort)
                        importError = nil
                    } catch {
                        importError = error.localizedDescription
                        showImportURL = true
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let error = importError {
                    Text(error)
                } else {
                    Text("Paste a VLESS share URL")
                }
            }
            .alert("Import Route", isPresented: $showRouteImport) {
                TextField("streisand://...", text: $routeImportText)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("Import") {
                    do {
                        let parsed = try StreisandRouteParser.parse(routeImportText)
                        profile.routeConfig = parsed
                        routeImportError = nil
                    } catch {
                        routeImportError = error.localizedDescription
                        showRouteImport = true
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let error = routeImportError {
                    Text(error)
                } else {
                    Text("Paste a Streisand route URL")
                }
            }
        }
    }

    private var routeFooter: Text {
        if profile.routeConfig.isEmpty {
            return Text("Split tunneling: route Russian sites directly, blocked sites through VPN.")
        } else {
            return Text("Strategy: \(profile.routeConfig.domainStrategy)")
        }
    }
}

// MARK: - Route Rules View

struct RouteRulesView: View {
    let routeConfig: RouteConfig

    var body: some View {
        List {
            ForEach(routeConfig.rules) { rule in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: iconForTag(rule.outboundTag))
                            .foregroundColor(colorForTag(rule.outboundTag))
                        Text(rule.outboundTag.uppercased())
                            .font(.caption.bold())
                            .foregroundColor(colorForTag(rule.outboundTag))
                        Spacer()
                        Text(rule.type.rawValue)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Text(rule.values.prefix(5).joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.primary)

                    if rule.values.count > 5 {
                        Text("... +\(rule.values.count - 5) more")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle(routeConfig.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func iconForTag(_ tag: String) -> String {
        switch tag {
        case "direct": return "arrow.right"
        case "proxy": return "shield.fill"
        case "block": return "xmark.circle"
        default: return "questionmark.circle"
        }
    }

    private func colorForTag(_ tag: String) -> Color {
        switch tag {
        case "direct": return .green
        case "proxy": return .blue
        case "block": return .red
        default: return .gray
        }
    }
}

#Preview {
    ProfileEditView(profile: VPNProfile(), isNew: true)
        .environmentObject(VPNViewModel())
}