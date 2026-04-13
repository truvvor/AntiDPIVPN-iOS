import SwiftUI

struct RoutingSettingsView: View {
    @EnvironmentObject var viewModel: VPNViewModel
    @State private var showRouteImport = false
    @State private var routeImportText = ""
    @State private var routeImportError: String? = nil
    @State private var showAddRule = false
    @State private var isDownloadingGeo = false
    @State private var geoDownloadStatus = ""

    var body: some View {
        Form {
            // Geo data status
            Section(header: Text("Geo Data"), footer: Text("Required for geosite: and geoip: rules. Downloaded once (~10 MB).")) {
                HStack {
                    Label(GeoDataManager.shared.hasGeoData ? "Installed" : "Not installed",
                          systemImage: GeoDataManager.shared.hasGeoData ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(GeoDataManager.shared.hasGeoData ? .green : .red)
                    Spacer()
                    if isDownloadingGeo {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text(geoDownloadStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Button(action: downloadGeoData) {
                    Label(GeoDataManager.shared.hasGeoData ? "Re-download" : "Download Now",
                          systemImage: "arrow.down.circle")
                }
                .disabled(isDownloadingGeo)
            }

            // Strategy
            Section(header: Text("Strategy")) {
                Picker("Domain Strategy", selection: $viewModel.globalRoute.domainStrategy) {
                    Text("AsIs").tag("AsIs")
                    Text("IPIfNonMatch").tag("IPIfNonMatch")
                    Text("IPOnDemand").tag("IPOnDemand")
                }
                .onChange(of: viewModel.globalRoute.domainStrategy) { _ in
                    viewModel.saveGlobalRoute()
                }
            }

            // Import
            Section(header: Text("Import")) {
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
                    Label("Import Streisand Route", systemImage: "square.and.arrow.down")
                }

                if !viewModel.globalRoute.name.isEmpty {
                    HStack {
                        Text("Current")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(viewModel.globalRoute.name)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Rules list
            Section(header: rulesHeader) {
                if viewModel.globalRoute.rules.isEmpty {
                    Text("No rules. All traffic goes through VPN.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else {
                    ForEach(viewModel.globalRoute.rules) { rule in
                        RuleRowView(rule: rule)
                    }
                    .onDelete { offsets in
                        viewModel.deleteRule(at: offsets)
                    }
                }
            }

            // Clear all
            if !viewModel.globalRoute.isEmpty {
                Section {
                    Button(role: .destructive) {
                        viewModel.clearRoute()
                    } label: {
                        Label("Remove All Rules", systemImage: "trash")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1) : UIColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 1) }),
                    Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.15, green: 0.11, blue: 0.15, alpha: 1) : UIColor(red: 0.95, green: 0.93, blue: 0.98, alpha: 1) })
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle("Routing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { showAddRule = true }) {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("Import Streisand Route", isPresented: $showRouteImport) {
            TextField("streisand://...", text: $routeImportText)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button("Import") {
                do {
                    try viewModel.importRoute(from: routeImportText)
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
                Text("Paste a Streisand route URL. This replaces all existing rules.")
            }
        }
        .sheet(isPresented: $showAddRule) {
            AddRuleView { rule in
                viewModel.addRule(rule)
            }
        }
    }

    private var rulesHeader: some View {
        HStack {
            Text("Rules (\(viewModel.globalRoute.rules.count))")
            Spacer()
            Text("Applied to all profiles")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func downloadGeoData() {
        isDownloadingGeo = true
        geoDownloadStatus = "Starting..."
        GeoDataManager.shared.ensureGeoData(progress: { msg in
            DispatchQueue.main.async { geoDownloadStatus = msg }
        }) { (error: Error?) in
            DispatchQueue.main.async {
                isDownloadingGeo = false
                if let error = error {
                    geoDownloadStatus = "Failed: \(error.localizedDescription)"
                } else {
                    geoDownloadStatus = "Done"
                }
            }
        }
    }
}

// MARK: - Rule Row

struct RuleRowView: View {
    let rule: RouteRule

    var body: some View {
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
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.systemGray5))
                    .cornerRadius(4)
            }
            Text(rule.values.prefix(3).joined(separator: ", "))
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(2)
            if rule.values.count > 3 {
                Text("+\(rule.values.count - 3) more")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
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

// MARK: - Add Rule

struct AddRuleView: View {
    @Environment(\.dismiss) var dismiss
    @State private var ruleType: RouteRule.RuleType = .domain
    @State private var outboundTag: String = "direct"
    @State private var valuesText: String = ""

    var onSave: (RouteRule) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Action") {
                    Picker("Route to", selection: $outboundTag) {
                        Label("Direct", systemImage: "arrow.right").tag("direct")
                        Label("Proxy", systemImage: "shield.fill").tag("proxy")
                        Label("Block", systemImage: "xmark.circle").tag("block")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Match Type") {
                    Picker("Type", selection: $ruleType) {
                        Text("Domain").tag(RouteRule.RuleType.domain)
                        Text("Geosite").tag(RouteRule.RuleType.geosite)
                        Text("GeoIP").tag(RouteRule.RuleType.geoip)
                        Text("Regexp").tag(RouteRule.RuleType.regexp)
                        Text("Port").tag(RouteRule.RuleType.port)
                    }
                }

                Section(header: Text("Values"), footer: valuesFooter) {
                    TextEditor(text: $valuesText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle("Add Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let values = valuesText
                            .split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        if !values.isEmpty {
                            let rule = RouteRule(type: ruleType, values: values, outboundTag: outboundTag)
                            onSave(rule)
                        }
                        dismiss()
                    }
                    .disabled(valuesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var valuesFooter: Text {
        switch ruleType {
        case .domain: return Text("One per line. E.g.:\nexample.com\n*.example.com")
        case .geosite: return Text("One per line. E.g.:\ngeosite:google\ngeosite:apple")
        case .geoip: return Text("One per line. E.g.:\ngeoip:us\ngeoip:private")
        case .regexp: return Text("One per line. E.g.:\n.*\\.example\\.com$")
        case .port: return Text("Comma-separated. E.g.:\n80,443,8080")
        }
    }
}
