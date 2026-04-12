import NetworkExtension
import os.log

/// PacketTunnelProvider — runs xray-core + hev-socks5-tunnel in extension process
class PacketTunnelProvider: NEPacketTunnelProvider {
    private var isTunnelRunning = false
    private var appSideFd: Int32 = -1
    private var tunSideFd: Int32 = -1
    private var isRelayRunning = false
    private var readSource: DispatchSourceRead?
    private var packetCount: UInt64 = 0
    private var relayedBackCount: UInt64 = 0
    private let AF_INET_BYTES: [UInt8] = [0, 0, 0, 2]
    private let AF_INET6_BYTES: [UInt8] = [0, 0, 0, 30]
    private var droppedPackets: UInt64 = 0

    // Synchronous file logger
    private var logFileHandle: FileHandle?

    // Memory monitor
    private var memoryTimer: DispatchSourceTimer?

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.truvvor.secureconnect")
    }

    private func setupFileLogging() {
        guard let containerURL = sharedContainerURL else { return }
        let logsDir = containerURL.appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logURL = logsDir.appendingPathComponent("tunnel.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logFileHandle = FileHandle(forWritingAtPath: logURL.path)
        fileLog("=== PacketTunnelProvider log started ===")
    }

    private func fileLog(_ message: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] \(message)\n"
        if let data = line.data(using: .utf8) {
            logFileHandle?.write(data)
            logFileHandle?.synchronizeFile()
        }
        os_log(.info, "PTP: %{public}@", message)
    }

    private func getMemoryMB() -> (Double, Double) {
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
            self.fileLog("MEM: used=\(String(format: "%.1f", m.0))MB avail=\(String(format: "%.1f", m.1))MB pkts=\(self.packetCount)/\(self.relayedBackCount) drop=\(self.droppedPackets)")
            // Emergency: if available memory drops below 15MB, log warning
            if m.1 < 15.0 && m.1 > 0 {
                self.fileLog("⚠️ LOW MEMORY avail=\(String(format: "%.1f", m.1))MB")
            }
        }
        memoryTimer = timer
        timer.resume()
    }

    private func isIPv6Address(_ address: String) -> Bool {
        return address.contains(":")
    }

    // MARK: - Xray Lifecycle

    private func startXray(configJSON: String) -> Bool {
        fileLog("Starting xray-core in extension...")
        let m0 = getMemoryMB()
        fileLog("MEM@pre-xray: used=\(String(format: "%.1f", m0.0))MB avail=\(String(format: "%.1f", m0.1))MB")

        guard let containerURL = sharedContainerURL else {
            fileLog("ERROR: no shared container")
            return false
        }

        let logsDir = containerURL.appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

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
            fileLog("ERROR: failed to serialize xray config")
            return false
        }

        let responseBase64 = LibXrayRunXrayFromJSON(base64String)
        if let responseData = Data(base64Encoded: responseBase64),
           let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            let success = response["success"] as? Bool ?? false
            let errMsg = response["error"] as? String ?? "unknown"
            if success {
                let m1 = getMemoryMB()
                fileLog("xray started OK — MEM: used=\(String(format: "%.1f", m1.0))MB avail=\(String(format: "%.1f", m1.1))MB")
                return true
            } else {
                fileLog("xray FAILED: \(errMsg)")
                return false
            }
        }
        fileLog("ERROR: failed to parse xray response")
        return false
    }

    // MARK: - NEProvider Lifecycle

    override func sleep(completionHandler: @escaping () -> Void) {
        let m = getMemoryMB()
        fileLog("SLEEP: used=\(String(format: "%.1f", m.0))MB avail=\(String(format: "%.1f", m.1))MB")
        completionHandler()
    }

    override func wake() {
        let m = getMemoryMB()
        fileLog("WAKE: used=\(String(format: "%.1f", m.0))MB avail=\(String(format: "%.1f", m.1))MB")
    }

    // MARK: - Tunnel

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        setupFileLogging()
        fileLog("Starting tunnel (build 24) — xray IN extension, aggressive mem mgmt")

        let m0 = getMemoryMB()
        fileLog("MEM@start: used=\(String(format: "%.1f", m0.0))MB avail=\(String(format: "%.1f", m0.1))MB")

        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = protocolConfig.providerConfiguration else {
            completionHandler(NSError(domain: "PTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing config"]))
            return
        }

        let configJSON = providerConfig["configJSON"] as? String ?? ""
        let serverAddress = providerConfig["serverAddress"] as? String ?? ""
        fileLog("configJSON length=\(configJSON.count) server=\(serverAddress)")

        guard !configJSON.isEmpty else {
            fileLog("ERROR: empty configJSON — cannot start xray")
            completionHandler(NSError(domain: "PTP", code: -2, userInfo: [NSLocalizedDescriptionKey: "Empty configJSON"]))
            return
        }

        // STEP 1: Start xray-core in extension process
        guard startXray(configJSON: configJSON) else {
            completionHandler(NSError(domain: "PTP", code: -3, userInfo: [NSLocalizedDescriptionKey: "Xray failed to start"]))
            return
        }

        let socksPort = 3080
        let tunnelRemote: String
        if serverAddress.isEmpty || isIPv6Address(serverAddress) {
            tunnelRemote = "254.1.1.1"
        } else {
            tunnelRemote = serverAddress
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemote)
        settings.mtu = 1500

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        if !serverAddress.isEmpty && !isIPv6Address(serverAddress) {
            ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: serverAddress, subnetMask: "255.255.255.255")]
            fileLog("excludedRoutes: \(serverAddress)/32")
        }
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fd00::1"], networkPrefixLengths: [128])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        if !serverAddress.isEmpty && isIPv6Address(serverAddress) {
            ipv6.excludedRoutes = [NEIPv6Route(destinationAddress: serverAddress, networkPrefixLength: 128)]
        }
        settings.ipv6Settings = ipv6
        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "2001:4860:4860::8888"])

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                self?.fileLog("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            self?.fileLog("Network settings applied")

            // STEP 2: Start tun2socks relay to xray's SOCKS5 on localhost
            self?.startTun2Socks(socksPort: socksPort)
            self?.isTunnelRunning = true
            self?.startMemoryMonitor()
            let m1 = self?.getMemoryMB() ?? (0.0, 0.0)
            self?.fileLog("MEM@ready: used=\(String(format: "%.1f", m1.0))MB avail=\(String(format: "%.1f", m1.1))MB")
            completionHandler(nil)
        }
    }

    private func startTun2Socks(socksPort: Int) {
        var fds: [Int32] = [0, 0]
        let ret = socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds)
        guard ret == 0 else { fileLog("socketpair failed errno=\(errno)"); return }
        tunSideFd = fds[0]; appSideFd = fds[1]

        var bufSize: Int32 = 2 * 1024 * 1024
        setsockopt(tunSideFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(tunSideFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(appSideFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(appSideFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(appSideFd, F_GETFL)
        let _ = fcntl(appSideFd, F_SETFL, flags | O_NONBLOCK)
        fileLog("socketpair tunFd=\(tunSideFd) appFd=\(appSideFd) buf=2MB")

        isRelayRunning = true
        startReadingFromPacketFlow()
        startReadingFromTun2Socks()

        let config = """
        tunnel:
          mtu: 1500
        socks5:
          address: 127.0.0.1
          port: \(socksPort)
          udp: udp
        misc:
          task-stack-size: 81920
          log-level: warning
        """
        fileLog("Starting hev-socks5-tunnel -> localhost:\(socksPort)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let configData = config.data(using: .utf8) else { return }
            configData.withUnsafeBytes { ptr in
                let basePtr = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let result = hev_socks5_tunnel_main_from_str(basePtr, UInt32(configData.count), self.tunSideFd)
                self.fileLog("hev-socks5-tunnel exited code=\(result)")
            }
            self.isRelayRunning = false
            self.readSource?.cancel()
        }
    }

    private func startReadingFromPacketFlow() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRelayRunning else { return }
            for (i, packet) in packets.enumerated() {
                let protoNum = protocols[i] as! Int32
                let afHeader = (protoNum == AF_INET6) ? self.AF_INET6_BYTES : self.AF_INET_BYTES
                var framedPacket = Data(afHeader)
                framedPacket.append(packet)
                let written = framedPacket.withUnsafeBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return write(self.appSideFd, base, framedPacket.count)
                }
                if written < 0 { self.droppedPackets += 1 }
                else { self.packetCount += 1 }
            }
            self.startReadingFromPacketFlow()
        }
    }

    private func startReadingFromTun2Socks() {
        let source = DispatchSource.makeReadSource(fileDescriptor: appSideFd, queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self = self, self.isRelayRunning else { return }
            let bufSize = 65536
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while true {
                let n = read(self.appSideFd, buf, bufSize)
                if n <= 4 { break }
                let ipPacket = Data(bytes: buf + 4, count: n - 4)
                let af = UInt32(buf[0]) << 24 | UInt32(buf[1]) << 16 | UInt32(buf[2]) << 8 | UInt32(buf[3])
                let proto: NSNumber = (af == 30) ? NSNumber(value: AF_INET6) : NSNumber(value: AF_INET)
                self.packetFlow.writePackets([ipPacket], withProtocols: [proto])
                self.relayedBackCount += 1
            }
        }
        source.setCancelHandler { [weak self] in self?.fileLog("dispatch source cancelled") }
        readSource = source
        source.resume()
        fileLog("dispatch source started")
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let command = String(data: messageData, encoding: .utf8), command == "getLogs" {
            var allLogs = ""
            if let containerURL = sharedContainerURL {
                let tunnelLogPath = containerURL.appendingPathComponent("Logs/tunnel.log").path
                if let data = FileManager.default.contents(atPath: tunnelLogPath),
                   let text = String(data: data, encoding: .utf8) {
                    allLogs += "=== TUNNEL LOG ===\n" + text + "\n"
                }
                for logFile in ["antidpi-debug.log", "xray-core.log"] {
                    let path = containerURL.appendingPathComponent("Logs/\(logFile)").path
                    if let data = FileManager.default.contents(atPath: path),
                       let text = String(data: data, encoding: .utf8) {
                        allLogs += "=== \(logFile.uppercased()) ===\n" + String(text.suffix(10000)) + "\n"
                    }
                }
            }
            completionHandler?(allLogs.data(using: .utf8))
            return
        }
        completionHandler?(nil)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let m = getMemoryMB()
        fileLog("STOP reason=\(reason.rawValue) used=\(String(format: "%.1f", m.0))MB avail=\(String(format: "%.1f", m.1))MB")
        fileLog("stats: sent=\(packetCount) recv=\(relayedBackCount) dropped=\(droppedPackets)")
        isTunnelRunning = false; isRelayRunning = false
        memoryTimer?.cancel(); memoryTimer = nil
        readSource?.cancel(); readSource = nil
        if appSideFd >= 0 { close(appSideFd); appSideFd = -1 }
        if tunSideFd >= 0 { close(tunSideFd); tunSideFd = -1 }
        hev_socks5_tunnel_quit()
        // Stop xray-core
        let _ = LibXrayStopXray()
        fileLog("xray stopped")
        logFileHandle?.synchronizeFile()
        logFileHandle?.closeFile()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completionHandler() }
    }
}