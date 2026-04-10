import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject var viewModel: VPNViewModel
    @State private var showAddProfile = false
    @State private var showImportURL = false
    @State private var importURLText = ""
    @State private var importError: String? = nil

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

                VStack(spacing: 0) {
                    if viewModel.profiles.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 44))
                                .foregroundColor(.secondary)

                            Text("No Profiles")
                                .font(.headline)

                            Text("Create a new profile or import from URL")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(viewModel.profiles) { profile in
                                NavigationLink(destination: ProfileEditView(profile: profile)) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(profile.name)
                                                .font(.headline)

                                            if profile.id == viewModel.currentProfile.id {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(.green)
                                                    .font(.caption)
                                            }

                                            Spacer()

                                            if profile.antiDPISettings.enabled {
                                                Image(systemName: "shield.checkered")
                                                    .font(.caption)
                                                    .foregroundColor(.purple)
                                            }
                                        }

                                        HStack(spacing: 12) {
                                            Label(profile.serverAddress, systemImage: "server.rack")
                                                .font(.caption)
                                                .foregroundColor(.secondary)

                                            Label("\(profile.serverPort)", systemImage: "network")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        viewModel.deleteProfile(profile)
                                    } label: {
                                        Label("Delete", systemImage: "trash.fill")
                                    }
                                }
                            }
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Profiles")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(action: { showAddProfile = true }) {
                            Label("New Profile", systemImage: "plus")
                        }
                        Button(action: {
                            importURLText = ""
                            importError = nil
                            showImportURL = true
                        }) {
                            Label("Import from URL", systemImage: "link.badge.plus")
                        }
                        Button(action: importFromClipboard) {
                            Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showAddProfile) {
                ProfileEditView(profile: VPNProfile(), isNew: true)
                    .environmentObject(viewModel)
            }
            .alert("Import from URL", isPresented: $showImportURL) {
                TextField("vless://...", text: $importURLText)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Button("Import") { importFromURL() }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let error = importError {
                    Text(error)
                } else {
                    Text("Paste a VLESS share URL to create a profile")
                }
            }
        }
    }

    private func importFromURL() {
        do {
            let profile = try VLESSURLParser.parse(importURLText)
            viewModel.addProfile(profile)
            importError = nil
        } catch {
            importError = error.localizedDescription
            showImportURL = true
        }
    }

    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            importError = "Clipboard is empty"
            showImportURL = true
            return
        }
        importURLText = text
        importFromURL()
    }
}

#Preview {
    ProfilesView()
        .environmentObject(VPNViewModel())
}