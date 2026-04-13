import Foundation
import SwiftUI
import Combine
import NetworkExtension

class VPNViewModel: ObservableObject {
    @Published var profiles: [VPNProfile] = []
    @Published var currentProfile: VPNProfile = VPNProfile()
    @Published var vpnManager: VPNManager = VPNManager()
    @Published var xrayVersion: String = "Unknown"
    @Published var socksPort: Int = 3080
    @Published var showLogs: Bool = false
    @Published var logs: [String] = []
    @Published var adaptiveLevel: Int = 3
    @Published var adaptiveStatus: String = ""
    @Published var globalRoute: RouteConfig = RouteConfig()

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.truvvor.secureconnect")
    }

    private var cancellables = Set<AnyCancellable>()
    private let profilesUserDefaultsKey = "vpn_profiles"
    private let currentProfileUserDefaultsKey = "current_profile"
    private let adaptiveLevelKey = "adaptive_level"
    private let globalRouteKey = "global_route_config"
    private var connectionStartTime: Date?
    private var reconnectTimer: Timer?
    private var stabilityTimer: Timer?
    private var consecutiveDisconnects: Int = 0

    // Adaptive levels: GLOBAL bandwidth limit in KB/s (shared across ALL connections)
    static let adaptiveLevels: [Int] = [1024, 3072, 8192, 20480, 0]

    init() {
        vpnManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        vpnManager.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStatus in self?.handleStatusChange(newStatus) }
            .store(in: &cancellables)

        loadProfiles()
        loadCurrentProfile()
        loadAdaptiveLevel()
        loadGlobalRoute()
        updateVersion()
    }

    var allLogs: [String] { (logs + vpnManager.debugLog).sorted().reversed() }

    var currentBandwidthKBs: Int {
        let idx = max(0, min(adaptiveLevel - 1, Self.adaptiveLevels.count - 1))
        return Self.adaptiveLevels[idx]
    }

    var adaptiveLevelDescription: String {
        switch adaptiveLevel {
        case 1: return "Stealth (1 MB/s)"
        case 2: return "Conservative (3 MB/s)"
        case 3: return "Balanced (8 MB/s)"
        case 4: return "Performance (20 MB/s)"
        case 5: return "Max (unlimited)"
        default: return "Unknown"
        }
    }

    private func loadAdaptiveLevel() {
        let saved = UserDefaults.standard.integer(forKey: adaptiveLevelKey)
        adaptiveLevel = saved > 0 ? min(max(saved, 1), 5) : 3
    }

    private func saveAdaptiveLevel() {
        UserDefaults.standard.set(adaptiveLevel, forKey: adaptiveLevelKey)
    }

    private func handleStatusChange(_ newStatus: NEVPNStatus) {
        switch newStatus {
        case .connected:
            connectionStartTime = Date()
            consecutiveDisconnects = 0
            adaptiveStatus = "Connected at level \(adaptiveLevel)"
            addLog("[Adaptive] Connected: \(adaptiveLevelDescription)")
            startStabilityTimer()
        case .disconnected:
            stabilityTimer?.invalidate()
            stabilityTimer = nil
            let wasConnected = connectionStartTime != nil
            if wasConnected && currentProfile.antiDPISettings.adaptiveEnabled {
                let duration: TimeInterval
                if let start = connectionStartTime { duration = Date().timeIntervalSince(start) } else { duration = 0 }
                connectionStartTime = nil
                if duration < 120 {
                    consecutiveDisconnects += 1
                    if adaptiveLevel > 1 {
                        adaptiveLevel -= 1
                        saveAdaptiveLevel()
                        addLog("[Adaptive] DPI disconnect after \(Int(duration))s, dropping to level \(adaptiveLevel)")
                    }
                    let delay = min(Double(2 + consecutiveDisconnects * 2), 30.0)
                    adaptiveStatus = "DPI detected, retry level \(adaptiveLevel) in \(Int(delay))s..."
                    scheduleReconnect(delay: delay)
                } else {
                    adaptiveStatus = "Disconnected after \(Int(duration))s, reconnecting..."
                    scheduleReconnect(delay: 3.0)
                }
            } else {
                connectionStartTime = nil
                adaptiveStatus = ""
            }
        case .connecting:
            adaptiveStatus = "Connecting at level \(adaptiveLevel)..."
        default: break
        }
    }

    private func scheduleReconnect(delay: TimeInterval) {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.vpnManager.status == .disconnected {
                    self.addLog("[Adaptive] Auto-reconnecting at level \(self.adaptiveLevel)...")
                    self.connectVPN()
                }
            }
        }
    }

    private func startStabilityTimer() {
        stabilityTimer?.invalidate()
        stabilityTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.vpnManager.status == .connected, self.currentProfile.antiDPISettings.adaptiveEnabled else { return }
                if self.adaptiveLevel < 5 {
                    self.adaptiveLevel += 1
                    self.saveAdaptiveLevel()
                    self.adaptiveStatus = "Stable 5min+, saved level \(self.adaptiveLevel) for next connect"
                    self.addLog("[Adaptive] Upgraded to level \(self.adaptiveLevel): \(self.adaptiveLevelDescription) (applied on next connect)")
                }
            }
        }
    }

    func resetAdaptiveLevel() {
        adaptiveLevel = 3
        saveAdaptiveLevel()
        adaptiveStatus = "Reset to level 3 (8 MB/s)"
        addLog("[Adaptive] Reset to default level 3")
    }

    // MARK: - Global Route

    func loadGlobalRoute() {
        if let data = UserDefaults.standard.data(forKey: globalRouteKey),
           let decoded = try? JSONDecoder().decode(RouteConfig.self, from: data) {
            self.globalRoute = decoded
        }
    }

    func saveGlobalRoute() {
        if let encoded = try? JSONEncoder().encode(globalRoute) {
            UserDefaults.standard.set(encoded, forKey: globalRouteKey)
        }
    }

    func importRoute(from urlString: String) throws {
        let route = try StreisandRouteParser.parse(urlString)
        globalRoute = route
        saveGlobalRoute()
        addLog("Imported route '\(route.name)' with \(route.rules.count) rules")
    }

    func addRule(_ rule: RouteRule) {
        globalRoute.rules.append(rule)
        saveGlobalRoute()
    }

    func deleteRule(at offsets: IndexSet) {
        globalRoute.rules.remove(atOffsets: offsets)
        saveGlobalRoute()
    }

    func clearRoute() {
        globalRoute = RouteConfig()
        saveGlobalRoute()
    }

    // MARK: - VPN Connection

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

        // If routing uses geosite/geoip, ensure geo data files are downloaded first
        let geoMgr = GeoDataManager.shared
        if geoMgr.needsGeoData(for: globalRoute) && !geoMgr.hasGeoData {
            addLog("Downloading geo data for routing rules...")
            geoMgr.ensureGeoData(progress: { [weak self] msg in
                self?.addLog(msg)
            }) { [weak self] (error: Error?) in
                guard let self = self else { return }
                if let error = error {
                    self.addLog("Geo data download failed: \(error.localizedDescription)")
                    DispatchQueue.main.async { self.vpnManager.errorMessage = "Failed to download geo data: \(error.localizedDescription)" }
                    return
                }
                self.addLog("Geo data ready")
                self.doConnect()
            }
        } else {
            doConnect()
        }
    }

    private func doConnect() {
        let bandwidth: Int
        if currentProfile.antiDPISettings.adaptiveEnabled {
            bandwidth = currentBandwidthKBs
        } else {
            bandwidth = currentProfile.antiDPISettings.bandwidthLimitKBs
        }

        var debugLogPath: String? = nil
        if let containerURL = sharedContainerURL {
            let logsDir = containerURL.appendingPathComponent("Logs")
            try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            debugLogPath = logsDir.appendingPathComponent("antidpi-debug.log").path
        }

        guard let config = ConfigGenerator.generateXrayConfig(
            from: currentProfile, routeConfig: globalRoute, bandwidthKBs: bandwidth, debugLogPath: debugLogPath
        ) else {
            addLog("Failed to generate Xray config")
            return
        }

        let routeInfo = globalRoute.isEmpty ? "no routing" : "\(globalRoute.rules.count) rules"
        let dnsInfo = currentProfile.dnsServers.isEmpty ? "default DNS" : currentProfile.effectiveDNS.joined(separator: ", ")
        let bwStr = bandwidth > 0 ? "\(bandwidth) KB/s" : "unlimited"
        addLog("Connecting [\(routeInfo), \(dnsInfo), bw=\(bwStr)]...")

        vpnManager.connect(profile: currentProfile, configJSON: config)
    }

    func disconnectVPN() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        stabilityTimer?.invalidate()
        stabilityTimer = nil
        connectionStartTime = nil
        adaptiveStatus = ""
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

    func fetchTunnelLogs(completion: @escaping (String) -> Void) {
        guard let session = vpnManager.tunnelProviderSession else {
            completion("No active tunnel session")
            return
        }
        do {
            try session.sendProviderMessage("getLogs".data(using: .utf8)!) { responseData in
                if let data = responseData, let text = String(data: data, encoding: .utf8) {
                    completion(text)
                } else {
                    completion("No log data received")
                }
            }
        } catch {
            completion("Error fetching logs: \(error.localizedDescription)")
        }
    }

    func readSharedLogs() -> String {
        guard let containerURL = sharedContainerURL else { return "No shared container" }
        var result = ""
        let logsDir = containerURL.appendingPathComponent("Logs")
        for file in ["tunnel.log", "antidpi-debug.log", "xray-core.log"] {
            let path = logsDir.appendingPathComponent(file).path
            if let data = FileManager.default.contents(atPath: path),
               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                result += "=== \(file) ===\n"
                result += (text.count > 5000 ? String(text.suffix(5000)) : text) + "\n\n"
            }
        }
        return result.isEmpty ? "No logs yet" : result
    }

    func setSocksPort(_ port: Int) {
        self.socksPort = port
        UserDefaults.standard.set(port, forKey: "socks_port")
    }
}