import Foundation
import SwiftUI
import Combine

class VPNViewModel: ObservableObject {
    @Published var profiles: [VPNProfile] = []
    @Published var currentProfile: VPNProfile = VPNProfile()
    @Published var vpnManager: VPNManager = VPNManager()
    @Published var xrayVersion: String = "Unknown"
    @Published var socksPort: Int = 3080
    @Published var showLogs: Bool = false
    @Published var logs: [String] = []

    private var cancellables = Set<AnyCancellable>()
    private let profilesUserDefaultsKey = "vpn_profiles"
    private let currentProfileUserDefaultsKey = "current_profile"

    init() {
        // Forward vpnManager changes to trigger SwiftUI re-render
        vpnManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        loadProfiles()
        loadCurrentProfile()
        updateVersion()
    }

    var allLogs: [String] {
        return (logs + vpnManager.debugLog).sorted().reversed()
    }

    func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: profilesUserDefaultsKey),
           let decoded = try? JSONDecoder().decode([VPNProfile].self, from: data) {
            self.profiles = decoded
        } else {
            self.profiles = [VPNProfile()]
            saveProfiles()
        }
    }

    func saveProfiles() {
        if let encoded = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(encoded, forKey: profilesUserDefaultsKey)
        }
    }

    func addProfile(_ profile: VPNProfile) {
        var newProfile = profile
        newProfile.id = UUID()
        newProfile.createdAt = Date()
        newProfile.updatedAt = Date()
        profiles.append(newProfile)
        saveProfiles()
    }

    func updateProfile(_ profile: VPNProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            var updated = profile
            updated.updatedAt = Date()
            profiles[index] = updated
            saveProfiles()
            if currentProfile.id == profile.id {
                currentProfile = updated
                saveCurrentProfile()
            }
        }
    }

    func deleteProfile(_ profile: VPNProfile) {
        profiles.removeAll { $0.id == profile.id }
        saveProfiles()
    }

    func loadCurrentProfile() {
        if let data = UserDefaults.standard.data(forKey: currentProfileUserDefaultsKey),
           let decoded = try? JSONDecoder().decode(VPNProfile.self, from: data) {
            self.currentProfile = decoded
        } else if !profiles.isEmpty {
            self.currentProfile = profiles[0]
            saveCurrentProfile()
        }
    }

    func saveCurrentProfile() {
        if let encoded = try? JSONEncoder().encode(currentProfile) {
            UserDefaults.standard.set(encoded, forKey: currentProfileUserDefaultsKey)
        }
    }

    func setCurrentProfile(_ profile: VPNProfile) {
        self.currentProfile = profile
        saveCurrentProfile()
    }

    func validateProfile(_ profile: VPNProfile) -> String? {
        if profile.serverAddress.trimmingCharacters(in: .whitespaces).isEmpty { return "Server address is not configured" }
        if profile.uuid.trimmingCharacters(in: .whitespaces).isEmpty { return "UUID is not configured" }
        if profile.realityPublicKey.trimmingCharacters(in: .whitespaces).isEmpty { return "REALITY public key is not configured" }
        if profile.realityShortId.trimmingCharacters(in: .whitespaces).isEmpty { return "REALITY short ID is not configured" }
        if profile.realityServerName.trimmingCharacters(in: .whitespaces).isEmpty { return "REALITY server name is not configured" }
        if profile.antiDPISettings.enabled && profile.nfsPublicKey.trimmingCharacters(in: .whitespaces).isEmpty { return "NFS public key is required when Anti-DPI is enabled" }
        return nil
    }

    func connectVPN() {
        if let validationError = validateProfile(currentProfile) {
            addLog("Configuration error: \(validationError)")
            DispatchQueue.main.async { self.vpnManager.errorMessage = validationError }
            return
        }
        guard let config = ConfigGenerator.generateXrayConfig(from: currentProfile) else {
            addLog("Failed to generate Xray config")
            return
        }
        addLog("Connecting to \(currentProfile.serverAddress):\(currentProfile.serverPort)...")
        vpnManager.connect(profile: currentProfile, configJSON: config)
    }

    func disconnectVPN() {
        vpnManager.disconnect()
        addLog("VPN disconnected")
    }

    private func updateVersion() {
        DispatchQueue.global(qos: .background).async {
            let responseBase64 = LibXrayXrayVersion()
            if let responseData = Data(base64Encoded: responseBase64),
               let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let data = response["data"] as? String {
                DispatchQueue.main.async { self.xrayVersion = data }
            }
        }
    }

    func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(message)"
        DispatchQueue.main.async {
            self.logs.insert(logEntry, at: 0)
            if self.logs.count > 100 { self.logs.removeLast() }
        }
    }

    func clearLogs() {
        logs.removeAll()
        vpnManager.debugLog.removeAll()
    }

    func setSocksPort(_ port: Int) {
        self.socksPort = port
        UserDefaults.standard.set(port, forKey: "socks_port")
    }
}
