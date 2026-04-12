import Foundation
import NetworkExtension
import os.log

class VPNManager: ObservableObject {
    @Published var status: NEVPNStatus = .disconnected
    @Published var errorMessage: String? = nil
    @Published var debugLog: [String] = []

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init() {
        log("VPNManager init")
        setupStatusObserver()
        loadManager()
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func log(_ message: String) {
        os_log(.info, "VPNManager: %{public}@", message)
        DispatchQueue.main.async {
            let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.debugLog.insert("[\(ts)] \(message)", at: 0)
            if self.debugLog.count > 50 { self.debugLog.removeLast() }
        }
    }

    private func setupStatusObserver() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            let newStatus = self.manager?.connection.status ?? .disconnected
            self.status = newStatus
            self.log("Status -> \(self.statusText)")
        }
    }

    private func loadManager() {
        log("Loading VPN managers...")
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.log("LOAD ERROR: \(error.localizedDescription)")
                return
            }
            self.log("Loaded \(managers?.count ?? 0) manager(s)")
            if let existing = managers?.first {
                self.manager = existing
                self.log("Using existing manager")
            } else {
                self.manager = NETunnelProviderManager()
                self.log("Created new manager")
            }
            DispatchQueue.main.async {
                self.status = self.manager?.connection.status ?? .disconnected
                self.log("Initial status: \(self.statusText)")
            }
        }
    }

    func connect(profile: VPNProfile, configJSON: String) {
        log("connect() for \(profile.serverAddress):\(profile.serverPort)")

        guard let manager = manager else {
            log("ERROR: manager is nil")
            DispatchQueue.main.async { self.errorMessage = "VPN manager not loaded" }
            return
        }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.truvvor.secureconnect.tunnel"
        proto.serverAddress = profile.serverAddress.isEmpty ? "VPN Server" : profile.serverAddress
        proto.disconnectOnSleep = false

        proto.providerConfiguration = [
            "configJSON": configJSON,
            "serverAddress": profile.serverAddress,
            "dnsServers": profile.effectiveDNS
        ] as [String: Any]

        manager.protocolConfiguration = proto
        manager.localizedDescription = "AntiDPI VPN"
        manager.isEnabled = true

        log("Saving...")
        manager.saveToPreferences { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.log("SAVE FAILED: \(error.localizedDescription)")
                DispatchQueue.main.async { self.errorMessage = "Save failed: \(error.localizedDescription)" }
                return
            }
            self.log("Save OK, reloading...")

            NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
                guard let self = self else { return }
                if let error = error {
                    self.log("RELOAD FAILED: \(error.localizedDescription)")
                    DispatchQueue.main.async { self.errorMessage = "Reload failed: \(error.localizedDescription)" }
                    return
                }

                guard let freshManager = managers?.first else {
                    self.log("ERROR: No manager after reload")
                    return
                }

                self.manager = freshManager
                self.log("Got fresh manager, starting tunnel...")

                DispatchQueue.main.async {
                    self.status = freshManager.connection.status
                }

                do {
                    try freshManager.connection.startVPNTunnel()
                    self.log("startVPNTunnel() called OK")
                    DispatchQueue.main.async { self.errorMessage = nil }
                } catch {
                    let msg = "START FAILED: \(error.localizedDescription)"
                    self.log(msg)
                    DispatchQueue.main.async { self.errorMessage = msg }
                }
            }
        }
    }

    func disconnect() {
        log("disconnect() called")
        manager?.connection.stopVPNTunnel()
    }

    var tunnelProviderSession: NETunnelProviderSession? {
        return manager?.connection as? NETunnelProviderSession
    }

    var isConnected: Bool { status == .connected }
    var isConnecting: Bool { status == .connecting }

    var statusText: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnecting: return "Disconnecting..."
        case .disconnected: return "Disconnected"
        case .invalid: return "Not Configured"
        case .reasserting: return "Reconnecting..."
        @unknown default: return "Unknown"
        }
    }
}
