import Foundation
import NetworkExtension
import os.log

class VPNManager: ObservableObject {
    @Published var status: NEVPNStatus = .disconnected
    @Published var errorMessage: String? = nil
    @Published var debugLog: [String] = []

    private var manager: NETunnelProviderManager?

    init() {
        log("VPNManager init")
        loadManager()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusChanged),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    func log(_ message: String) {
        os_log(.info, "VPNManager: %{public}@", message)
        DispatchQueue.main.async {
            let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.debugLog.insert("[\(ts)] \(message)", at: 0)
            if self.debugLog.count > 50 { self.debugLog.removeLast() }
        }
    }

    private func loadManager() {
        log("Loading VPN managers from preferences...")
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            if let error = error {
                let nsErr = error as NSError
                self?.log("LOAD ERROR: \(error.localizedDescription) [code=\(nsErr.code) domain=\(nsErr.domain)]")
                DispatchQueue.main.async {
                    self?.errorMessage = "VPN load error: \(error.localizedDescription)"
                }
                return
            }

            let count = managers?.count ?? 0
            self?.log("Loaded \(count) manager(s)")

            if let existing = managers?.first {
                self?.manager = existing
                self?.log("Using existing manager")
            } else {
                self?.manager = NETunnelProviderManager()
                self?.log("Created new manager")
            }

            DispatchQueue.main.async {
                self?.status = self?.manager?.connection.status ?? .disconnected
                self?.log("Initial status: \(self?.statusText ?? "?")")
            }
        }
    }

    @objc private func vpnStatusChanged(_ notification: Notification) {
        guard let connection = notification.object as? NEVPNConnection else { return }
        DispatchQueue.main.async {
            self.status = connection.status
            self.log("Status -> \(self.statusText)")
        }
    }

    func connect(profile: VPNProfile, configJSON: String) {
        log("connect() called for \(profile.serverAddress):\(profile.serverPort)")

        guard let manager = manager else {
            let msg = "VPN manager is nil — NETunnelProviderManager not loaded"
            log("ERROR: \(msg)")
            DispatchQueue.main.async { self.errorMessage = msg }
            return
        }

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let libraryPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].path

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.truvvor.antidpivpn.tunnel"
        proto.serverAddress = profile.serverAddress.isEmpty ? "VPN Server" : profile.serverAddress
        proto.providerConfiguration = [
            "configJSON": configJSON,
            "datDir": (documentsPath as NSString).appendingPathComponent("xray_dat"),
            "mphCachePath": (libraryPath as NSString).appendingPathComponent("xray_cache"),
            "socksPort": 3080
        ] as [String: Any]

        manager.protocolConfiguration = proto
        manager.localizedDescription = "AntiDPI VPN"
        manager.isEnabled = true

        log("Saving to preferences...")

        manager.saveToPreferences { [weak self] error in
            if let error = error {
                let nsErr = error as NSError
                let msg = "SAVE FAILED: \(error.localizedDescription) [code=\(nsErr.code) domain=\(nsErr.domain)]"
                self?.log(msg)
                DispatchQueue.main.async { self?.errorMessage = msg }
                return
            }

            self?.log("Save OK, reloading...")

            manager.loadFromPreferences { error in
                if let error = error {
                    let nsErr = error as NSError
                    let msg = "RELOAD FAILED: \(error.localizedDescription) [code=\(nsErr.code) domain=\(nsErr.domain)]"
                    self?.log(msg)
                    DispatchQueue.main.async { self?.errorMessage = msg }
                    return
                }

                self?.log("Reload OK, starting tunnel...")

                do {
                    try manager.connection.startVPNTunnel()
                    self?.log("startVPNTunnel() called OK")
                    DispatchQueue.main.async { self?.errorMessage = nil }
                } catch {
                    let nsErr = error as NSError
                    let msg = "START FAILED: \(error.localizedDescription) [code=\(nsErr.code) domain=\(nsErr.domain)]"
                    self?.log(msg)
                    DispatchQueue.main.async { self?.errorMessage = msg }
                }
            }
        }
    }

    func disconnect() {
        log("disconnect() called")
        manager?.connection.stopVPNTunnel()
    }

    var isConnected: Bool {
        return status == .connected
    }

    var isConnecting: Bool {
        return status == .connecting
    }

    var statusText: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnecting: return "Disconnecting..."
        case .disconnected: return "Disconnected"
        case .invalid: return "Invalid"
        case .reasserting: return "Reconnecting..."
        @unknown default: return "Unknown"
        }
    }
}
