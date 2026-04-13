import NetworkExtension
import Network
import os.log

/// PacketTunnelProvider — sing-box powered VPN extension.
/// sing-box handles TUN natively, no hev-socks5-tunnel needed.
/// Supports VLESS + REALITY + Vision, fake-ip DNS routing.
class PacketTunnelProvider: NEPacketTunnelProvider {
    private var boxService: LibboxBoxService?
    private var commandServer: LibboxCommandServer?
    private var isTunnelRunning = false
    private var memoryTimer: DispatchSourceTimer?
    private var pathMonitor: NWPathMonitor?
    private var currentNetworkPath: String = ""
    private var savedConfigJSON: String = ""

    // Logging
    private var logFileHandle: FileHandle?
    private var logBuffer = Data()
    private var logTimer: DispatchSourceTimer?

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.truvvor.secureconnect")
    }

    // MARK: - Logging

    private func setupFileLogging() {
        guard let containerURL = sharedContainerURL else { return }
        let logsDir = containerURL.appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logURL = logsDir.appendingPathComponent("tunnel.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logFileHandle = FileHandle(forWritingAtPath: logURL.path)

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.flushLog() }
        logTimer = timer
        timer.resume()
    }

    private func fileLog(_ message: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        if let data = "[\(ts)] \(message)\n".data(using: .utf8) {
            logBuffer.append(data)
            if logBuffer.count > 4096 { flushLog() }
        }
        os_log(.info, "PTP: %{public}@", message)
    }

    private func flushLog() {
        guard !logBuffer.isEmpty else { return }
        logFileHandle?.write(logBuffer)
        logFileHandle?.synchronizeFile()
        logBuffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Memory

    private func getMemoryMB() -> (used: Double, avail: Double) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let used = (result == KERN_SUCCESS) ? Double(info.resident_size) / 1048576.0 : -1.0
        let avail = Double(os_proc_available_memory()) / 1048576.0
        return (used, avail)
    }

    private func startMemoryMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isTunnelRunning else { return }
            let m = self.getMemoryMB()
            self.fileLog("MEM: used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB")
        }
        memoryTimer = timer
        timer.resume()
    }

    // MARK: - Network Monitor

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self, self.isTunnelRunning else { return }
            let desc = path.usesInterfaceType(.wifi) ? "wifi" :
                       path.usesInterfaceType(.cellular) ? "cellular" : "other"
            let pathKey = "\(desc)-\(path.status)"

            if self.currentNetworkPath.isEmpty {
                self.currentNetworkPath = pathKey
                self.fileLog("Network: \(desc) (\(path.status))")
            } else if pathKey != self.currentNetworkPath {
                self.fileLog("Network CHANGED: \(self.currentNetworkPath) → \(pathKey)")
                self.currentNetworkPath = pathKey
                self.boxService?.resetNetwork()
                self.fileLog("sing-box network reset")
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    // MARK: - Tunnel Lifecycle

    private func isIPv6Address(_ address: String) -> Bool {
        address.contains(":")
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        setupFileLogging()
        let m0 = getMemoryMB()
        fileLog("Starting tunnel (v1.4) — sing-box engine")
        fileLog("MEM@start: used=\(String(format: "%.1f", m0.used))MB avail=\(String(format: "%.1f", m0.avail))MB")

        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = protocolConfig.providerConfiguration,
              let configJSON = providerConfig["configJSON"] as? String, !configJSON.isEmpty else {
            completionHandler(NSError(domain: "PTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing config"]))
            return
        }

        let serverAddress = providerConfig["serverAddress"] as? String ?? ""
        let dnsServers = providerConfig["dnsServers"] as? [String] ?? ["8.8.8.8", "2001:4860:4860::8888"]
        savedConfigJSON = configJSON

        fileLog("configJSON length=\(configJSON.count) server=\(serverAddress)")
        fileLog("CONFIG: \(String(configJSON.prefix(2000)))")
        flushLog()

        // Setup sing-box
        do {
            let setupOptions = LibboxSetupOptions()
            if let containerURL = sharedContainerURL {
                setupOptions.basePath = containerURL.path
                setupOptions.workingPath = containerURL.appendingPathComponent("sing-box").path
                try? FileManager.default.createDirectory(atPath: setupOptions.workingPath, withIntermediateDirectories: true)
            }

            var setupError: NSError?
            LibboxSetup(setupOptions, &setupError)
            if let err = setupError {
                fileLog("LibboxSetup error: \(err.localizedDescription)")
                completionHandler(err)
                return
            }
            fileLog("LibboxSetup OK")
            flushLog()
        }

        // Create box service
        do {
            var serviceError: NSError?
            let service = LibboxNewService(configJSON, self, &serviceError)
            if let err = serviceError {
                fileLog("LibboxNewService error: \(err.localizedDescription)")
                completionHandler(err)
                return
            }
            guard let service = service else {
                fileLog("ERROR: LibboxNewService returned nil")
                completionHandler(NSError(domain: "PTP", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create service"]))
                return
            }
            boxService = service
            fileLog("sing-box service created")
            flushLog()

            // Start service
            var startError: NSError?
            let started = service.start(&startError)
            if let err = startError {
                fileLog("sing-box start error: \(err.localizedDescription)")
                completionHandler(err)
                return
            }

            let m1 = getMemoryMB()
            fileLog("sing-box started — MEM: used=\(String(format: "%.1f", m1.used))MB avail=\(String(format: "%.1f", m1.avail))MB")
            flushLog()
        }

        // Network settings
        let tunnelRemote = (serverAddress.isEmpty || isIPv6Address(serverAddress)) ? "254.1.1.1" : serverAddress

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemote)
        settings.mtu = 9000

        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        if !serverAddress.isEmpty && !isIPv6Address(serverAddress) {
            ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: serverAddress, subnetMask: "255.255.255.255")]
            fileLog("excludedRoutes: \(serverAddress)/32")
        }
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::1"], networkPrefixLengths: [126])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        if !serverAddress.isEmpty && isIPv6Address(serverAddress) {
            ipv6.excludedRoutes = [NEIPv6Route(destinationAddress: serverAddress, networkPrefixLength: 128)]
        }
        settings.ipv6Settings = ipv6
        settings.dnsSettings = NEDNSSettings(servers: dnsServers)
        fileLog("DNS: \(dnsServers.joined(separator: ", "))")

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.fileLog("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            self.fileLog("Network settings applied")
            self.isTunnelRunning = true
            self.startMemoryMonitor()
            self.startNetworkMonitor()
            let m2 = self.getMemoryMB()
            self.fileLog("MEM@ready: used=\(String(format: "%.1f", m2.used))MB avail=\(String(format: "%.1f", m2.avail))MB")
            completionHandler(nil)
        }
    }

    // MARK: - App Messages

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let command = String(data: messageData, encoding: .utf8), command == "getLogs" {
            flushLog()
            var allLogs = ""
            if let containerURL = sharedContainerURL {
                for logFile in ["tunnel.log"] {
                    let path = containerURL.appendingPathComponent("Logs/\(logFile)").path
                    if let data = FileManager.default.contents(atPath: path),
                       let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        allLogs += "=== \(logFile.uppercased()) ===\n" + String(text.suffix(10000)) + "\n"
                    }
                }
            }
            completionHandler?(allLogs.data(using: .utf8))
            return
        }
        completionHandler?(nil)
    }

    // MARK: - Sleep/Wake

    override func sleep(completionHandler: @escaping () -> Void) {
        let m = getMemoryMB()
        fileLog("SLEEP: used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB")
        boxService?.pause()
        completionHandler()
    }

    override func wake() {
        let m = getMemoryMB()
        fileLog("WAKE: used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB")
        boxService?.wake()
    }

    // MARK: - Stop

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let m = getMemoryMB()
        fileLog("STOP reason=\(reason.rawValue) used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB")

        isTunnelRunning = false
        memoryTimer?.cancel(); memoryTimer = nil
        pathMonitor?.cancel(); pathMonitor = nil

        do {
            try boxService?.close()
        } catch {
            fileLog("sing-box close error: \(error.localizedDescription)")
        }
        boxService = nil
        fileLog("sing-box stopped")

        flushLog()
        logTimer?.cancel(); logTimer = nil
        logFileHandle?.closeFile()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completionHandler() }
    }
}

// MARK: - LibboxPlatformInterfaceProtocol

extension PacketTunnelProvider: LibboxPlatformInterfaceProtocol {
    @objc func autoDetectInterfaceControl(_ fd: Int32) throws {
    }

    @objc func clearDNSCache() {
    }

    @objc func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListener?) throws {
    }

    @objc func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32, ret0_: UnsafeMutablePointer<Int32>?) throws {
        ret0_?.pointee = -1
    }

    @objc func getInterfaces() throws -> LibboxNetworkInterfaceIterator? {
        return nil
    }

    @objc func includeAllNetworks() -> Bool {
        return false
    }

    @objc func openTun(_ options: LibboxTunOptions?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let fd = self.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 else {
            fileLog("ERROR: cannot get TUN fd from packetFlow")
            throw NSError(domain: "PTP", code: -10, userInfo: [NSLocalizedDescriptionKey: "Cannot get TUN fd"])
        }
        ret0_?.pointee = fd
        fileLog("openTun: fd=\(fd)")
    }

    @objc func packageName(byUid uid: Int32) throws -> String {
        return ""
    }

    @objc func readWIFIState() -> LibboxWIFIState? {
        return nil
    }

    @objc func sendNotification(_ notification: LibboxNotification?) throws {
    }

    @objc func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListener?) throws {
    }

    @objc func uidByPackageName(_ packageName: String?) throws {
    }

    @objc func underNetworkExtension() -> Bool {
        return true
    }

    @objc func usePlatformAutoDetectInterfaceControl() -> Bool {
        return true
    }

    @objc func useProcFS() -> Bool {
        return false
    }

    @objc func writeLog(_ message: String?) {
        if let msg = message {
            fileLog("[sing-box] \(msg)")
        }
    }
}
