import Foundation
import NetworkExtension
import UIKit
import os.log

class VPNManager: ObservableObject {
    @Published var status: NEVPNStatus = .disconnected
    @Published var errorMessage: String? = nil
    @Published var debugLog: [String] = []

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    // App-side xray management
    private var isXrayRunningInApp = false
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var heartbeatTimer: Timer?
    private var currentFullConfigJSON: String?

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.truvvor.secureconnect")
    }

    init() {
        log("VPNManager init")
        setupStatusObserver()
        setupLifecycleObservers()
        loadManager()
    }

    deinit {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        NotificationCenter.default.removeObserver(self)
    }

    func log(_ message: String) {
        os_log(.info, "VPNManager: %{public}@", message)
        DispatchQueue.main.async {
            let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            self.debugLog.insert("[\(ts)] \(message)", at: 0)
            if self.debugLog.count > 50 { self.debugLog.removeLast() }
        }
    }

    // MARK: - Status Observer

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
            // If tunnel disconnected, clean up app-side xray
            if newStatus == .disconnected {
                self.stopXrayInApp()
            }
        }
    }

    // MARK: - App Lifecycle (foreground/background)

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleAppBecameActive()
        }
    }

    /// When the app returns to foreground, restart xray in app if VPN is connected.
    /// Extension will detect it via health check and switch back to ultra-light mode.
    private func handleAppBecameActive() {
        guard status == .connected, !isXrayRunningInApp, let config = currentFullConfigJSON else { return }
        log("App foregrounded — restarting app-side xray")
        if startXrayInAppInternal(configJSON: config) {
            log("App-side xray restarted, extension will switch to ultra-light mode")
        }
    }

    // MARK: - App-side Xray

    func startXrayInApp(configJSON: String) -> Bool {
        currentFullConfigJSON = configJSON
        return startXrayInAppInternal(configJSON: configJSON)
    }

    private func startXrayInAppInternal(configJSON: String) -> Bool {
        guard !isXrayRunningInApp else { return true }

        guard let containerURL = sharedContainerURL else {
            log("ERROR: no shared container for xray")
            return false
        }

        let datDir = containerURL.appendingPathComponent("xray_dat").path
        let cachePath = containerURL.appendingPathComponent("xray_cache").path
        try? FileManager.default.createDirectory(atPath: datDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: cachePath, withIntermediateDirectories: true)

        let requestDict: [String: Any] = [
            "datDir": datDir,
            "mphCachePath": cachePath,
            "configJSON": configJSON
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestDict),
              let base64String = jsonData.base64EncodedString() as String? else {
            log("ERROR: failed to serialize xray config")
            return false
        }

        let responseBase64 = LibXrayRunXrayFromJSON(base64String)
        if let responseData = Data(base64Encoded: responseBase64),
           let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let success = response["success"] as? Bool, success {
            isXrayRunningInApp = true
            startHeartbeat()
            beginBackgroundKeepAlive()
            log("App-side xray started on port \(ConfigGenerator.appXrayPort)")
            return true
        } else {
            log("WARNING: Failed to start app-side xray (extension will use fallback)")
            return false
        }
    }

    func stopXrayInApp() {
        guard isXrayRunningInApp else { return }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        _ = LibXrayStopXray()
        isXrayRunningInApp = false
        writeXrayAppStatus(running: false)
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
        log("App-side xray stopped")
    }

    /// Write heartbeat file so the extension knows app-side xray is alive.
    /// Updated every 2 seconds. If timestamp is stale (>5s), extension assumes app is suspended.
    private func writeXrayAppStatus(running: Bool) {
        guard let containerURL = sharedContainerURL else { return }
        let statusFile = containerURL.appendingPathComponent("xray_app_status.json")
        let status: [String: Any] = [
            "running": running,
            "port": ConfigGenerator.appXrayPort,
            "timestamp": Date().timeIntervalSince1970
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status) {
            try? data.write(to: statusFile, options: .atomic)
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        writeXrayAppStatus(running: true)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.writeXrayAppStatus(running: true)
        }
    }

    /// Keep the app alive in background as long as possible (~30s).
    /// When iOS forces expiration, stop xray — extension will fall back to its own.
    private func beginBackgroundKeepAlive() {
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask { [weak self] in
            guard let self = self else { return }
            self.log("Background task expiring — stopping app-side xray")
            // Notify extension proactively before we're suspended
            self.sendMessageToExtension("appXrayStopping")
            self.stopXrayInApp()
        }
    }

    private func sendMessageToExtension(_ message: String) {
        guard let session = tunnelProviderSession else { return }
        try? session.sendProviderMessage(message.data(using: .utf8)!) { _ in }
    }

    // MARK: - Manager

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

    // MARK: - Connect / Disconnect

    /// Connect VPN with dual-mode architecture.
    /// - fullConfigJSON: Full anti-DPI config for app-side xray (unlimited memory)
    /// - liteConfigJSON: Reduced config for extension fallback (~50MB limit)
    func connect(profile: VPNProfile, fullConfigJSON: String, liteConfigJSON: String) {
        log("connect() for \(profile.serverAddress):\(profile.serverPort)")

        guard let manager = manager else {
            log("ERROR: manager is nil")
            DispatchQueue.main.async { self.errorMessage = "VPN manager not loaded" }
            return
        }

        // Start xray in the main app with full anti-DPI features (unlimited memory)
        if startXrayInApp(configJSON: fullConfigJSON) {
            log("App-side xray started — extension will be ultra-light (~20MB)")
        } else {
            log("App-side xray failed — extension will use fallback xray")
        }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.truvvor.secureconnect.tunnel"
        proto.serverAddress = profile.serverAddress.isEmpty ? "VPN Server" : profile.serverAddress
        proto.disconnectOnSleep = false

        // Pass lite config for extension fallback mode
        proto.providerConfiguration = [
            "liteConfigJSON": liteConfigJSON,
            "serverAddress": profile.serverAddress,
            "appXrayPort": ConfigGenerator.appXrayPort,
            "fallbackXrayPort": ConfigGenerator.fallbackXrayPort
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
        stopXrayInApp()
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
