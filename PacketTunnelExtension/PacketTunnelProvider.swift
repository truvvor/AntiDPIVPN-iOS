import NetworkExtension
import os.log

/// Build 27 — Dual-mode architecture for 3× memory reduction.
///
/// Two modes:
///   1. APP-SIDE (~20MB extension): xray runs in the main app (unlimited memory).
///      Extension is just a thin packet relay: TUN → hev-socks5-tunnel → localhost:3080 (app's xray).
///      All anti-DPI features (mimicry, fragments) run at full strength in the app.
///
///   2. FALLBACK (~40MB extension): when the app is suspended/killed, extension starts its own
///      xray with reduced mimicry (sensitivity 0.12) on port 3081.
///
/// Mode switching: health check every 10s probes SOCKS5 port.
/// App → Extension notification via handleAppMessage for proactive switching.
class PacketTunnelProvider: NEPacketTunnelProvider {

    // MARK: - Mode

    private enum XrayMode: String {
        case appSide = "app-side"      // xray in main app, extension ultra-light
        case inExtension = "fallback"  // xray in extension with lite config
    }

    private var currentMode: XrayMode = .appSide
    private var currentSocksPort: Int = 3080
    private var liteConfigJSON: String = ""
    private var fallbackXrayPort: Int = 3081
    private var appXrayPort: Int = 3080
    private var xrayRunningInExtension = false

    // MARK: - State

    private var isTunnelRunning = false
    private var appSideFd: Int32 = -1
    private var tunSideFd: Int32 = -1
    private var isRelayRunning = false
    private var readSource: DispatchSourceRead?
    private var memoryTimer: DispatchSourceTimer?
    private var healthTimer: DispatchSourceTimer?

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

    // Memory pressure flag
    private var isUnderMemoryPressure = false

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
        timer.schedule(deadline: .now() + 5, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isTunnelRunning else { return }
            let m = self.getMemoryMB()
            self.fileLog("MEM[\(self.currentMode.rawValue)]: used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB pkts=\(self.packetsSent)/\(self.packetsRecv) drop=\(self.packetsDropped)")

            if m.avail < 15.0 && m.avail > 0 {
                if !self.isUnderMemoryPressure {
                    self.fileLog("WARNING: memory pressure (avail=\(String(format: "%.1f", m.avail))MB)")
                    self.isUnderMemoryPressure = true
                }
            } else if m.avail > 20.0 && self.isUnderMemoryPressure {
                self.fileLog("Memory pressure relieved")
                self.isUnderMemoryPressure = false
            }
        }
        memoryTimer = timer
        timer.resume()
    }

    // MARK: - SOCKS5 Probe

    /// TCP connect test to localhost:port with 500ms timeout.
    /// Used to detect whether the main app's xray is running.
    private func probeSOCKS5(port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let flags = fcntl(sock, F_GETFL)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pfd, 1, 500)
        if pollResult <= 0 { return false }

        var error: Int32 = 0
        var errLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &error, &errLen)
        return error == 0
    }

    // MARK: - Health Check (mode switching)

    private func startHealthCheck() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isTunnelRunning else { return }

            switch self.currentMode {
            case .appSide:
                // Check if app's xray is still alive
                if !self.probeSOCKS5(port: self.appXrayPort) {
                    self.fileLog("Health check: app-side xray GONE — switching to fallback")
                    self.switchToFallbackMode()
                }
            case .inExtension:
                // Check if app's xray came back (user re-opened app)
                if self.probeSOCKS5(port: self.appXrayPort) {
                    self.fileLog("Health check: app-side xray BACK — switching to ultra-light")
                    self.switchToAppSideMode()
                }
            }
        }
        healthTimer = timer
        timer.resume()
    }

    /// Switch from app-side to fallback: start xray in extension, restart relay.
    private func switchToFallbackMode() {
        guard currentMode == .appSide, !liteConfigJSON.isEmpty else { return }
        fileLog("Switching to fallback mode...")

        // Stop relay
        tearDownRelay()

        // Start xray in extension with lite config
        guard startXray(configJSON: liteConfigJSON) else {
            fileLog("ERROR: fallback xray failed to start")
            return
        }
        xrayRunningInExtension = true
        currentMode = .inExtension
        currentSocksPort = fallbackXrayPort

        // Restart relay to new port
        startTun2Socks(socksPort: currentSocksPort)

        let m = getMemoryMB()
        fileLog("Switched to FALLBACK — MEM: used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB")
    }

    /// Switch from fallback to app-side: stop in-extension xray, restart relay.
    private func switchToAppSideMode() {
        guard currentMode == .inExtension else { return }
        fileLog("Switching to app-side mode...")

        // Stop relay
        tearDownRelay()

        // Stop in-extension xray
        if xrayRunningInExtension {
            _ = LibXrayStopXray()
            xrayRunningInExtension = false
            fileLog("In-extension xray stopped")
        }

        currentMode = .appSide
        currentSocksPort = appXrayPort

        // Restart relay to app's port
        startTun2Socks(socksPort: currentSocksPort)

        let m = getMemoryMB()
        fileLog("Switched to APP-SIDE — MEM: used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB")
    }

    private func tearDownRelay() {
        isRelayRunning = false
        hev_socks5_tunnel_quit()
        readSource?.cancel()
        readSource = nil

        // Brief wait for hev-socks5-tunnel thread to exit
        usleep(200_000)

        if appSideFd >= 0 { close(appSideFd); appSideFd = -1 }
        if tunSideFd >= 0 { close(tunSideFd); tunSideFd = -1 }
        readBuf?.deallocate()
        readBuf = nil
    }

    // MARK: - Xray (in-extension fallback only)

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
        fileLog("Starting fallback xray — MEM: used=\(String(format: "%.1f", m0.used))MB avail=\(String(format: "%.1f", m0.avail))MB")

        let responseBase64 = LibXrayRunXrayFromJSON(base64String)
        if let responseData = Data(base64Encoded: responseBase64),
           let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            let success = response["success"] as? Bool ?? false
            if success {
                let m1 = getMemoryMB()
                fileLog("Fallback xray started — MEM: used=\(String(format: "%.1f", m1.used))MB avail=\(String(format: "%.1f", m1.avail))MB")
                return true
            } else {
                fileLog("Fallback xray FAILED: \(response["error"] as? String ?? "unknown")")
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
        fileLog("Starting tunnel (build 27) — dual-mode architecture")
        fileLog("MEM@start: used=\(String(format: "%.1f", m0.used))MB avail=\(String(format: "%.1f", m0.avail))MB")

        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = protocolConfig.providerConfiguration else {
            completionHandler(NSError(domain: "PTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing config"]))
            return
        }

        liteConfigJSON = providerConfig["liteConfigJSON"] as? String ?? ""
        let serverAddress = providerConfig["serverAddress"] as? String ?? ""
        appXrayPort = providerConfig["appXrayPort"] as? Int ?? 3080
        fallbackXrayPort = providerConfig["fallbackXrayPort"] as? Int ?? 3081

        fileLog("server=\(serverAddress) appPort=\(appXrayPort) fallbackPort=\(fallbackXrayPort)")

        // STEP 1: Decide mode — probe app-side xray with retries
        var appXrayAvailable = false
        for attempt in 1...3 {
            if probeSOCKS5(port: appXrayPort) {
                appXrayAvailable = true
                break
            }
            if attempt < 3 { usleep(300_000) } // 300ms between retries
        }

        if appXrayAvailable {
            currentMode = .appSide
            currentSocksPort = appXrayPort
            fileLog("App-side xray detected on port \(appXrayPort) — ULTRA-LIGHT mode")
        } else {
            fileLog("App-side xray not available — starting FALLBACK mode")
            if !liteConfigJSON.isEmpty {
                guard startXray(configJSON: liteConfigJSON) else {
                    completionHandler(NSError(domain: "PTP", code: -3, userInfo: [NSLocalizedDescriptionKey: "Fallback xray failed"]))
                    return
                }
                xrayRunningInExtension = true
            } else {
                completionHandler(NSError(domain: "PTP", code: -2, userInfo: [NSLocalizedDescriptionKey: "No lite config for fallback"]))
                return
            }
            currentMode = .inExtension
            currentSocksPort = fallbackXrayPort
        }

        // STEP 2: Network settings
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

            // STEP 3: Start packet relay
            self.startTun2Socks(socksPort: self.currentSocksPort)
            self.isTunnelRunning = true
            self.startMemoryMonitor()
            self.startHealthCheck()
            let m1 = self.getMemoryMB()
            self.fileLog("MEM@ready[\(self.currentMode.rawValue)]: used=\(String(format: "%.1f", m1.used))MB avail=\(String(format: "%.1f", m1.avail))MB")
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

        // Small socket buffers — 128KB each
        var bufSize: Int32 = 128 * 1024
        setsockopt(tunSideFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(tunSideFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(appSideFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(appSideFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(appSideFd, F_GETFL)
        _ = fcntl(appSideFd, F_SETFL, flags | O_NONBLOCK)
        fileLog("socketpair tunFd=\(tunSideFd) appFd=\(appSideFd) buf=128KB -> localhost:\(socksPort)")

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

    /// packetFlow → tun2socks
    private func startReadingFromPacketFlow() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRelayRunning else { return }

            if self.isUnderMemoryPressure {
                self.packetsDropped += UInt64(packets.count)
                self.startReadingFromPacketFlow()
                return
            }

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

    /// tun2socks → packetFlow
    private func startReadingFromTun2Socks() {
        let source = DispatchSource.makeReadSource(fileDescriptor: appSideFd, queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self = self, self.isRelayRunning, let buf = self.readBuf else { return }

            var batchPackets: [Data] = []
            var batchProtos: [NSNumber] = []

            while true {
                let n = read(self.appSideFd, buf, self.readBufSize)
                if n <= 4 { break }

                if self.isUnderMemoryPressure {
                    self.packetsDropped += 1
                    continue
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
        guard let command = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }

        switch command {
        case "getLogs":
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

        case "appXrayStopping":
            // App is about to be suspended — proactively switch to fallback
            fileLog("Received appXrayStopping — proactive switch to fallback")
            if currentMode == .appSide {
                switchToFallbackMode()
            }
            completionHandler?("ok".data(using: .utf8))

        case "appXrayStarted":
            // App came back and restarted xray — switch to ultra-light
            fileLog("Received appXrayStarted — switching to app-side mode")
            if currentMode == .inExtension {
                switchToAppSideMode()
            }
            completionHandler?("ok".data(using: .utf8))

        default:
            completionHandler?(nil)
        }
    }

    // MARK: - Sleep/Wake

    override func sleep(completionHandler: @escaping () -> Void) {
        let m = getMemoryMB()
        fileLog("SLEEP[\(currentMode.rawValue)]: used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB")
        completionHandler()
    }

    override func wake() {
        let m = getMemoryMB()
        fileLog("WAKE[\(currentMode.rawValue)]: used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB")
    }

    // MARK: - Stop

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let m = getMemoryMB()
        fileLog("STOP reason=\(reason.rawValue) mode=\(currentMode.rawValue) used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB")
        fileLog("stats: sent=\(packetsSent) recv=\(packetsRecv) dropped=\(packetsDropped)")

        isTunnelRunning = false
        isRelayRunning = false

        memoryTimer?.cancel(); memoryTimer = nil
        healthTimer?.cancel(); healthTimer = nil
        readSource?.cancel(); readSource = nil

        if appSideFd >= 0 { close(appSideFd); appSideFd = -1 }
        if tunSideFd >= 0 { close(tunSideFd); tunSideFd = -1 }
        readBuf?.deallocate(); readBuf = nil

        hev_socks5_tunnel_quit()

        if xrayRunningInExtension {
            _ = LibXrayStopXray()
            xrayRunningInExtension = false
            fileLog("In-extension xray stopped")
        }

        flushLog()
        logTimer?.cancel(); logTimer = nil
        logFileHandle?.closeFile()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completionHandler() }
    }
}
