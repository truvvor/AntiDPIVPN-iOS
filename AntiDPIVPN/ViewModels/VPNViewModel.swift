import Foundation
import SwiftUI

class VPNViewModel: ObservableObject {
    @Published var profiles: [VPNProfile] = []
    @Published var currentProfile: VPNProfile = VPNProfile()
    @Published var xrayService: XrayService = XrayService()
    @Published var socksPort: Int = 3080
    @Published var showLogs: Bool = false
    @Published var logs: [String] = []

    private let profilesUserDefaultsKey = "vpn_profiles"
    private let currentProfileUserDefaultsKey = "current_profile"

    init() {
        loadProfiles()
        loadCurrentProfile()
    }

    // MARK: - Profile Management

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

    // MARK: - VPN Connection

    func connectVPN() {
        guard let config = ConfigGenerator.generateXrayConfig(from: currentProfile) else {
            addLog("Failed to generate Xray config")
            return
        }

        let result = xrayService.startVPN(with: config)

        switch result {
        case .success:
            addLog("VPN connected successfully")
        case .failure(let error):
            addLog("Connection failed: \(error.localizedDescription)")
        }
    }

    func disconnectVPN() {
        let result = xrayService.stopVPN()

        switch result {
        case .success:
            addLog("VPN disconnected")
        case .failure(let error):
            addLog("Disconnect failed: \(error.localizedDescription)")
        }
    }

    func refreshVPNState() {
        xrayService.refreshState()
    }

    // MARK: - Logging

    func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logEntry = "[\(timestamp)] \(message)"
        DispatchQueue.main.async {
            self.logs.insert(logEntry, at: 0)
            if self.logs.count > 100 {
                self.logs.removeLast()
            }
        }
    }

    func clearLogs() {
        logs.removeAll()
    }

    // MARK: - Settings

    func setSocksPort(_ port: Int) {
        self.socksPort = port
        UserDefaults.standard.set(port, forKey: "socks_port")
    }
}
