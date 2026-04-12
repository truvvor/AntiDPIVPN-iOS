import NetworkExtension
import os.log

/// Build 29 — Single-mode, memory-optimized.
/// Xray runs in extension with reduced mimicry (0.12) and infrastructure optimizations.
/// App-side mode removed (iOS sandbox blocks cross-process localhost).
class PacketTunnelProvider: NEPacketTunnelProvider {
    private var isTunnelRunning = false
    private var appSideFd: Int32 = -1
    private var tunSideFd: Int32 = -1
    private var isRelayRunning = false
    private var readSource: DispatchSourceRead?
    private var memoryTimer: DispatchSourceTimer?

    // Stats
    private var packetsSent: UInt64 = 0
    private var packetsRecv: UInt64 = 0
    private var packetsDropped: UInt64 = 0

    // Pre-allocated read buffer (reused across events)
    private let readBufSize = 2048
    private var readBuf: UnsafeMutablePointer<UInt8>?

    // Pre-built AF headers
    private static let afInet4Header = Data([0, 0, 0, 2])
    private static let afInet6Header = Data([0, 0, 0, 30])

    // Memory pressure level: 0=normal, 1=moderate(drop 50% inbound), 2=severe(drop 90% inbound)
    // NEVER drop outbound — apps must be able to close connections (FIN/RST) so Go can free memory
    private var memoryPressureLevel: Int = 0
    private var dropCounter: UInt64 = 0

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
            self.fileLog("MEM: used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB pkts=\(self.packetsSent)/\(self.packetsRecv) drop=\(self.packetsDropped)")

            // Graduated memory pressure — throttle inbound, never block outbound
            let oldLevel = self.memoryPressureLevel
            if m.avail < 12.0 && m.avail > 0 {
                self.memoryPressureLevel = 2 // severe: drop 90% inbound
            } else if m.avail < 20.0 && m.avail > 0 {
                self.memoryPressureLevel = 1 // moderate: drop 50% inbound
            } else if m.avail > 25.0 {
                self.memoryPressureLevel = 0 // normal
            }
            if oldLevel != self.memoryPressureLevel {
                let desc = ["normal", "moderate(drop 50% inbound)", "severe(drop 90% inbound)"]
                self.fileLog("Memory pressure: \(desc[self.memoryPressureLevel]) avail=\(String(format: "%.1f", m.avail))MB")
            }
        }
        memoryTimer = timer
        timer.resume()
    }

    // MARK: - Xray

    private func startXray(configJSON: String) -> Bool {
        guard let containerURL = sharedContainerURL else {
            fileLog("ERROR: no shared container")
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
            fileLog("ERROR: failed to serialize xray config")
            return false
        }

        let m0 = getMemoryMB()
        fileLog("MEM@pre-xray: used=\(String(format: "%.1f", m0.used))MB avail=\(String(format: "%.1f", m0.avail))MB")

        let responseBase64 = LibXrayRunXrayFromJSON(base64String)
        if let responseData = Data(base64Encoded: responseBase64),
           let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            let success = response["success"] as? Bool ?? false
            if success {
                let m1 = getMemoryMB()
                fileLog("xray started OK — MEM: used=\(String(format: "%.1f", m1.used))MB avail=\(String(format: "%.1f", m1.avail))MB")
                return true
            } else {
                fileLog("xray FAILED: \(response["error"] as? String ?? "unknown")")
                return false
            }
        }
        fileLog("ERROR: failed to parse xray response")
        return false
    }

    // MARK: - Tunnel Lifecycle

    private func isIPv6Address(_ address: String) -> Bool {
        address.contains(":")
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        setupFileLogging()
        let m0 = getMemoryMB()
        fileLog("Starting tunnel (build 30) — optimized single-mode")
        fileLog("MEM@start: used=\(String(format: "%.1f", m0.used))MB avail=\(String(format: "%.1f", m0.avail))MB")

        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = protocolConfig.providerConfiguration,
              let configJSON = providerConfig["configJSON"] as? String, !configJSON.isEmpty else {
            completionHandler(NSError(domain: "PTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing or empty config"]))
            return
        }

        let serverAddress = providerConfig["serverAddress"] as? String ?? ""
        fileLog("configJSON length=\(configJSON.count) server=\(serverAddress)")

        // Start xray-core
        guard startXray(configJSON: configJSON) else {
            completionHandler(NSError(domain: "PTP", code: -3, userInfo: [NSLocalizedDescriptionKey: "Xray failed to start"]))
            return
        }

        // Network settings
        let tunnelRemote = (serverAddress.isEmpty || isIPv6Address(serverAddress)) ? "254.1.1.1" : serverAddress

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemote)
        settings.mtu = 1400

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
            guard let self = self else { return }
            if let error = error {
                self.fileLog("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            self.fileLog("Network settings applied")

            self.startTun2Socks(socksPort: 3080)
            self.isTunnelRunning = true
            self.startMemoryMonitor()
            let m1 = self.getMemoryMB()
            self.fileLog("MEM@ready: used=\(String(format: "%.1f", m1.used))MB avail=\(String(format: "%.1f", m1.avail))MB")
            completionHandler(nil)
        }
    }

    // MARK: - Tun2Socks Relay

    private func startTun2Socks(socksPort: Int) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            fileLog("socketpair failed errno=\(errno)")
            return
        }
        tunSideFd = fds[0]
        appSideFd = fds[1]

        // 128KB socket buffers (vs 2MB in old builds — saves ~7.5MB)
        var bufSize: Int32 = 128 * 1024
        setsockopt(tunSideFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(tunSideFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(appSideFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(appSideFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(appSideFd, F_GETFL)
        _ = fcntl(appSideFd, F_SETFL, flags | O_NONBLOCK)
        fileLog("socketpair tunFd=\(tunSideFd) appFd=\(appSideFd) buf=128KB")

        readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: readBufSize)

        isRelayRunning = true
        startReadingFromPacketFlow()
        startReadingFromTun2Socks()

        let config = """
        tunnel:
          mtu: 1400
        socks5:
          address: 127.0.0.1
          port: \(socksPort)
          udp: udp
        misc:
          task-stack-size: 20480
          log-level: error
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

    /// packetFlow → tun2socks (outbound: NEVER drop — apps must close connections)
    private func startReadingFromPacketFlow() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRelayRunning else { return }

            // ALWAYS forward outbound packets — connection teardown (FIN/RST)
            // must work so xray can close connections and free Go memory
            for (i, packet) in packets.enumerated() {
                let protoNum = protocols[i] as! Int32
                let afHeader = (protoNum == AF_INET6) ? Self.afInet6Header : Self.afInet4Header
                let totalLen = 4 + packet.count
                let written = packet.withUnsafeBytes { packetPtr -> Int in
                    guard let packetBase = packetPtr.baseAddress else { return -1 }
                    return afHeader.withUnsafeBytes { headerPtr -> Int in
                        guard let headerBase = headerPtr.baseAddress else { return -1 }
                        var iov = [
                            iovec(iov_base: UnsafeMutableRawPointer(mutating: headerBase), iov_len: 4),
                            iovec(iov_base: UnsafeMutableRawPointer(mutating: packetBase), iov_len: packet.count)
                        ]
                        return writev(self.appSideFd, &iov, 2)
                    }
                }
                if written == totalLen { self.packetsSent += 1 }
                else { self.packetsDropped += 1 }
            }
            self.startReadingFromPacketFlow()
        }
    }

    /// tun2socks → packetFlow (inbound: graduated dropping under memory pressure)
    private func startReadingFromTun2Socks() {
        let source = DispatchSource.makeReadSource(fileDescriptor: appSideFd, queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self = self, self.isRelayRunning, let buf = self.readBuf else { return }

            var batchPackets: [Data] = []
            var batchProtos: [NSNumber] = []

            while true {
                let n = read(self.appSideFd, buf, self.readBufSize)
                if n <= 4 { break }

                // Graduated inbound throttle — keeps connections alive but reduces data flow
                let pressure = self.memoryPressureLevel
                if pressure > 0 {
                    self.dropCounter += 1
                    let shouldDrop: Bool
                    if pressure >= 2 {
                        shouldDrop = (self.dropCounter % 10) != 0 // keep 1 in 10
                    } else {
                        shouldDrop = (self.dropCounter % 2) != 0  // keep 1 in 2
                    }
                    if shouldDrop {
                        self.packetsDropped += 1
                        continue
                    }
                }

                let af = UInt32(buf[0]) << 24 | UInt32(buf[1]) << 16 | UInt32(buf[2]) << 8 | UInt32(buf[3])
                let proto: NSNumber = (af == 30) ? NSNumber(value: AF_INET6) : NSNumber(value: AF_INET)
                batchPackets.append(Data(bytes: buf + 4, count: n - 4))
                batchProtos.append(proto)

                if batchPackets.count >= 32 {
                    self.packetFlow.writePackets(batchPackets, withProtocols: batchProtos)
                    self.packetsRecv += UInt64(batchPackets.count)
                    batchPackets.removeAll(keepingCapacity: true)
                    batchProtos.removeAll(keepingCapacity: true)
                }
            }

            if !batchPackets.isEmpty {
                self.packetFlow.writePackets(batchPackets, withProtocols: batchProtos)
                self.packetsRecv += UInt64(batchPackets.count)
            }
        }
        source.setCancelHandler { [weak self] in self?.fileLog("dispatch source cancelled") }
        readSource = source
        source.resume()
        fileLog("dispatch source started")
    }

    // MARK: - App Messages

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if let command = String(data: messageData, encoding: .utf8), command == "getLogs" {
            flushLog()
            var allLogs = ""
            if let containerURL = sharedContainerURL {
                for logFile in ["tunnel.log", "antidpi-debug.log", "xray-core.log"] {
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
        completionHandler()
    }

    override func wake() {
        let m = getMemoryMB()
        fileLog("WAKE: used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB")
    }

    // MARK: - Stop

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let m = getMemoryMB()
        fileLog("STOP reason=\(reason.rawValue) used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB")
        fileLog("stats: sent=\(packetsSent) recv=\(packetsRecv) dropped=\(packetsDropped)")

        isTunnelRunning = false
        isRelayRunning = false

        memoryTimer?.cancel(); memoryTimer = nil
        readSource?.cancel(); readSource = nil

        if appSideFd >= 0 { close(appSideFd); appSideFd = -1 }
        if tunSideFd >= 0 { close(tunSideFd); tunSideFd = -1 }
        readBuf?.deallocate(); readBuf = nil

        hev_socks5_tunnel_quit()
        _ = LibXrayStopXray()
        fileLog("xray stopped")

        flushLog()
        logTimer?.cancel(); logTimer = nil
        logFileHandle?.closeFile()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completionHandler() }
    }
}
