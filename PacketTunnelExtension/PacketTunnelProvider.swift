import NetworkExtension
import Network
import os.log

/// Build 42 — iOS memory-pressure hook + adaptive RX backpressure.
/// Works with LibXray built with runtime/debug.SetMemoryLimit(45MiB)+
/// SetGCPercent(50) in init() and exported LibXrayLibXrayFreeOSMemory.
///
/// On iOS memory-pressure events, explicitly ask Go to return freed
/// heap pages to the kernel — without this, Go GC's internally but RSS
/// stays at peak and iOS reads RSS for jetsam decisions.
///
/// On readPackets, when os_proc_available_memory reports tight headroom,
/// defer the next read. This propagates as TCP backpressure to apps
/// on-device, slowing new connection creation and letting Go drain
/// existing goroutine state before more arrives.
class PacketTunnelProvider: NEPacketTunnelProvider {
    private var isTunnelRunning = false
    private var appSideFd: Int32 = -1
    private var tunSideFd: Int32 = -1
    private var isRelayRunning = false
    private var readSource: DispatchSourceRead?
    private var memoryTimer: DispatchSourceTimer?

    // Saved for in-place xray restart (used only from stopTunnel path now)
    private var savedConfigJSON: String = ""

    // Network change detection (diagnostic-only — no auto-restart)
    private var pathMonitor: NWPathMonitor?
    private var currentNetworkPath: String = ""

    // iOS memory-pressure source — forces Go to return heap to kernel
    // on warning/critical events so RSS doesn't stay at peak after a
    // connection burst. Needs LibXrayLibXrayFreeOSMemory export.
    private var memPressureSource: DispatchSourceMemoryPressure?

    // Stats
    private var packetsSent: UInt64 = 0
    private var packetsRecv: UInt64 = 0
    private var packetsDropped: UInt64 = 0

    // RX scratch buffer for read() from the socketpair. Contents are
    // copied into a fresh Data before the next read(), so one buffer is
    // safe. Do NOT hand this pointer to NE via Data(bytesNoCopy:) —
    // writePackets is async and the buffer would be overwritten in-flight.
    private let readBufSize = 2048
    private var readBuf: UnsafeMutablePointer<UInt8>?

    // Preallocated iovec pair for TX writev. Safe to reuse because writev
    // is synchronous — consumes iov_base/iov_len before returning.
    private var txIov: UnsafeMutablePointer<iovec>?

    // Pre-built AF headers
    private static let afInet4Header = Data([0, 0, 0, 2])
    private static let afInet6Header = Data([0, 0, 0, 30])

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

        // Preserve history across crash+auto-reconnect. If the previous
        // session died silently, iOS restarts the extension and we used to
        // wipe the log — losing the last messages before the kill. Now we
        // append, with a 1MB soft cap: when size exceeds, rotate current
        // to tunnel.log.prev and start fresh. Gives us at most ~2MB of
        // rolling history — enough for the post-crash forensic window.
        let maxSize: UInt64 = 1_048_576
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? UInt64, size > maxSize {
            let prevURL = logsDir.appendingPathComponent("tunnel.log.prev")
            try? FileManager.default.removeItem(at: prevURL)
            try? FileManager.default.moveItem(at: logURL, to: prevURL)
        }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logFileHandle = FileHandle(forWritingAtPath: logURL.path)
        logFileHandle?.seekToEndOfFile()

        // Clear session separator so the crashed previous session is
        // distinguishable from this one in the combined log.
        let sep = "\n===== Session start build 44 at \(Date()) =====\n"
        if let data = sep.data(using: .utf8) {
            logFileHandle?.write(data)
        }

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

    // MARK: - Memory (diagnostic only, no throttling)

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
        // Diagnostic + proactive memory reclamation.
        //
        // DispatchSource.memoryPressure fires on SYSTEM-wide pressure, not when
        // a NE extension hits its own ~50MB per-process limit. On a 12GB device
        // iOS sees no global shortage even when we're seconds away from jetsam,
        // so we must poll our own budget via os_proc_available_memory() and
        // call FreeOSMemory() ourselves. Without this, Go GC frees heap
        // internally but RSS stays at peak, and eventually mmap() returns
        // ENOMEM → runtime.throw("out of memory") → SIGABRT.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isTunnelRunning else { return }
            let m = self.getMemoryMB()
            if m.avail < 20.0 {
                // Proactive: don't wait for an iOS pressure event that won't
                // come. Ask Go to return freed pages to the kernel now.
                LibXrayLibXrayFreeOSMemory()
                let after = self.getMemoryMB()
                self.fileLog("MEM: used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB pkts=\(self.packetsSent)/\(self.packetsRecv) — proactive FreeOSMemory → used=\(String(format: "%.1f", after.used))MB avail=\(String(format: "%.1f", after.avail))MB")
                self.flushLog()
            } else {
                self.fileLog("MEM: used=\(String(format: "%.1f", m.used))MB avail=\(String(format: "%.1f", m.avail))MB pkts=\(self.packetsSent)/\(self.packetsRecv)")
            }
        }
        memoryTimer = timer
        timer.resume()
    }

    // MARK: - Xray

    /// Restart xray in-place to recover from stalled VLESS connection.
    private func restartXray() {
        guard !savedConfigJSON.isEmpty else {
            fileLog("Cannot restart: no saved config")
            return
        }
        let m0 = getMemoryMB()
        fileLog("Restarting xray — MEM: used=\(String(format: "%.1f", m0.used))MB avail=\(String(format: "%.1f", m0.avail))MB")
        _ = LibXrayStopXray()
        usleep(300_000)
        if startXray(configJSON: savedConfigJSON) {
            let m1 = getMemoryMB()
            fileLog("Xray restarted OK — MEM: used=\(String(format: "%.1f", m1.used))MB avail=\(String(format: "%.1f", m1.avail))MB")
        } else {
            fileLog("ERROR: xray restart FAILED")
        }
    }

    private func startXray(configJSON: String) -> Bool {
        guard let containerURL = sharedContainerURL else {
            fileLog("ERROR: no shared container")
            return false
        }

        let datDir = containerURL.appendingPathComponent("xray_dat").path
        try? FileManager.default.createDirectory(atPath: datDir, withIntermediateDirectories: true)

        // Delete old xray_cache directory (was incorrectly used as mphCachePath)
        let oldCacheDir = containerURL.appendingPathComponent("xray_cache").path
        try? FileManager.default.removeItem(atPath: oldCacheDir)

        // List dat files for debugging
        let datFiles = (try? FileManager.default.contentsOfDirectory(atPath: datDir)) ?? []
        fileLog("datDir files: \(datFiles)")
        flushLog()

        let requestDict: [String: Any] = [
            "datDir": datDir,
            "configJSON": configJSON
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestDict),
              let base64String = jsonData.base64EncodedString() as String? else {
            fileLog("ERROR: failed to serialize xray request")
            flushLog()
            return false
        }

        fileLog("xray request base64 length: \(base64String.count)")
        let m0 = getMemoryMB()
        fileLog("MEM@pre-xray: used=\(String(format: "%.1f", m0.used))MB avail=\(String(format: "%.1f", m0.avail))MB")
        flushLog()

        fileLog("Calling LibXrayRunXrayFromJSON...")
        flushLog()

        // GC + memory limit are now set programmatically inside LibXray's
        // init() via runtime/debug.SetMemoryLimit(45MiB)+SetGCPercent(50).
        // setenv() here used to be a no-op because Go reads env only at
        // dyld load, before Swift runs.
        let responseBase64 = LibXrayRunXrayFromJSON(base64String)

        let m1 = getMemoryMB()
        fileLog("LibXray returned — MEM: used=\(String(format: "%.1f", m1.used))MB avail=\(String(format: "%.1f", m1.avail))MB")
        fileLog("Response length: \(responseBase64.count)")

        if let responseData = Data(base64Encoded: responseBase64),
           let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            let success = response["success"] as? Bool ?? false
            let errMsg = response["error"] as? String ?? ""
            fileLog("xray response: success=\(success) error='\(errMsg)'")
            flushLog()
            if success {
                return true
            } else {
                return false
            }
        }
        fileLog("ERROR: failed to decode xray response base64")
        fileLog("Raw response: \(String(responseBase64.prefix(200)))")
        flushLog()
        return false
    }

    // MARK: - Tunnel Lifecycle

    private func isIPv6Address(_ address: String) -> Bool {
        address.contains(":")
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        setupFileLogging()
        let m0 = getMemoryMB()
        fileLog("Starting tunnel (build 52) — sync.Pool in mimicry+finalmask + mux=16")
        fileLog("MEM@start: used=\(String(format: "%.1f", m0.used))MB avail=\(String(format: "%.1f", m0.avail))MB")

        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = protocolConfig.providerConfiguration,
              let configJSON = providerConfig["configJSON"] as? String, !configJSON.isEmpty else {
            completionHandler(NSError(domain: "PTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing or empty config"]))
            return
        }

        let serverAddress = providerConfig["serverAddress"] as? String ?? ""
        let dnsServers = providerConfig["dnsServers"] as? [String] ?? ["8.8.8.8", "2001:4860:4860::8888"]
        fileLog("configJSON length=\(configJSON.count) server=\(serverAddress)")
        // Log first 2000 chars of config for debugging routing issues
        fileLog("CONFIG: \(String(configJSON.prefix(2000)))")
        flushLog()

        savedConfigJSON = configJSON
        guard startXray(configJSON: configJSON) else {
            completionHandler(NSError(domain: "PTP", code: -3, userInfo: [NSLocalizedDescriptionKey: "Xray failed to start"]))
            return
        }

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

            self.startTun2Socks(socksPort: 3080)
            self.isTunnelRunning = true
            self.startMemoryMonitor()
            self.startMemoryPressureMonitor()
            self.startNetworkMonitor()
            let m1 = self.getMemoryMB()
            self.fileLog("MEM@ready: used=\(String(format: "%.1f", m1.used))MB avail=\(String(format: "%.1f", m1.avail))MB")
            completionHandler(nil)
        }
    }

    // MARK: - Tun2Socks Relay (no throttling — full speed always)

    private func startTun2Socks(socksPort: Int) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            fileLog("socketpair failed errno=\(errno)")
            return
        }
        tunSideFd = fds[0]
        appSideFd = fds[1]

        var bufSize: Int32 = 128 * 1024
        setsockopt(tunSideFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(tunSideFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(appSideFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(appSideFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(appSideFd, F_GETFL)
        _ = fcntl(appSideFd, F_SETFL, flags | O_NONBLOCK)
        fileLog("socketpair tunFd=\(tunSideFd) appFd=\(appSideFd) buf=128KB")

        readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: readBufSize)
        txIov = UnsafeMutablePointer<iovec>.allocate(capacity: 2)

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

    /// Reschedule the next readPackets based on current memory headroom.
    /// The signal loop: low avail → defer read → TCP backpressure to apps
    /// on-device → fewer new connections → Go goroutine churn drops →
    /// GC + FreeOSMemory drain RSS → avail recovers → throughput resumes.
    private func rescheduleReadPacketFlow() {
        let availBytes = os_proc_available_memory()
        let delayMs: Int
        if availBytes < 8 * 1_048_576 {
            delayMs = 200
        } else if availBytes < 15 * 1_048_576 {
            delayMs = 50
        } else {
            delayMs = 0
        }
        if delayMs == 0 {
            startReadingFromPacketFlow()
        } else {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .milliseconds(delayMs)
            ) { [weak self] in
                self?.startReadingFromPacketFlow()
            }
        }
    }

    /// packetFlow → tun2socks (always forward, never drop)
    private func startReadingFromPacketFlow() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self, self.isRelayRunning else { return }

            guard let iov = self.txIov else { return }
            for (i, packet) in packets.enumerated() {
                let protoNum = protocols[i] as! Int32
                let afHeader = (protoNum == AF_INET6) ? Self.afInet6Header : Self.afInet4Header
                let totalLen = 4 + packet.count
                let written = packet.withUnsafeBytes { packetPtr -> Int in
                    guard let packetBase = packetPtr.baseAddress else { return -1 }
                    return afHeader.withUnsafeBytes { headerPtr -> Int in
                        guard let headerBase = headerPtr.baseAddress else { return -1 }
                        iov[0] = iovec(iov_base: UnsafeMutableRawPointer(mutating: headerBase), iov_len: 4)
                        iov[1] = iovec(iov_base: UnsafeMutableRawPointer(mutating: packetBase), iov_len: packet.count)
                        return writev(self.appSideFd, iov, 2)
                    }
                }
                if written == totalLen { self.packetsSent += 1 }
                else { self.packetsDropped += 1 }
            }
            self.rescheduleReadPacketFlow()
        }
    }

    // MARK: - Memory Pressure

    /// Subscribe to iOS memory-pressure events and ask Go to return heap
    /// pages on warning/critical. Without this call into the runtime,
    /// Go's GC frees memory internally but RSS stays at peak and iOS
    /// sees it for jetsam decisions.
    private func startMemoryPressureMonitor() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = source.data
            let level = event.contains(.critical) ? "critical" : "warning"
            let before = self.getMemoryMB()
            LibXrayLibXrayFreeOSMemory()
            let after = self.getMemoryMB()
            self.fileLog("MEMPRESSURE: \(level) — FreeOSMemory \(String(format: "%.1f", before.used))→\(String(format: "%.1f", after.used))MB avail \(String(format: "%.1f", before.avail))→\(String(format: "%.1f", after.avail))MB")
            self.flushLog()
        }
        memPressureSource = source
        source.resume()
    }

    /// tun2socks → packetFlow (always forward, never drop)
    private func startReadingFromTun2Socks() {
        let source = DispatchSource.makeReadSource(fileDescriptor: appSideFd, queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self = self, self.isRelayRunning, let buf = self.readBuf else { return }

            var batchPackets: [Data] = []
            var batchProtos: [NSNumber] = []
            batchPackets.reserveCapacity(32)
            batchProtos.reserveCapacity(32)

            while true {
                let n = read(self.appSideFd, buf, self.readBufSize)
                if n <= 4 { break }

                let af = UInt32(buf[0]) << 24 | UInt32(buf[1]) << 16 | UInt32(buf[2]) << 8 | UInt32(buf[3])
                let proto: NSNumber = (af == 30) ? NSNumber(value: AF_INET6) : NSNumber(value: AF_INET)
                // Copy into a fresh Data — writePackets is async and may retain
                // the Data past the next read() call.
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
                // tunnel.log.prev first — that's the crashed-session history
                // that's most interesting for forensics. tunnel.log is the
                // current live session.
                for logFile in ["tunnel.log.prev", "tunnel.log", "antidpi-debug.log", "xray-core.log"] {
                    let path = containerURL.appendingPathComponent("Logs/\(logFile)").path
                    if let data = FileManager.default.contents(atPath: path),
                       let text = String(data: data, encoding: .utf8), !text.isEmpty {
                        let header = logFile == "xray-core.log"
                            ? "=== \(logFile.uppercased()) (UTC) ==="
                            : "=== \(logFile.uppercased()) ==="
                        allLogs += header + "\n" + String(text.suffix(10000)) + "\n"
                    }
                }
            }
            completionHandler?(allLogs.data(using: .utf8))
            return
        }
        completionHandler?(nil)
    }

    // MARK: - Network Change Detection

    private func startNetworkMonitor() {
        // Diagnostic-only. Path flicker on cellular/Wi-Fi under load used to
        // trigger restartXray(), which tore down live REALITY sessions in the
        // middle of traffic bursts — a major contributor to tunnel death.
        // xray itself recovers from transient connectivity via TCP retries;
        // a full xray restart is worse than any brief stall.
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
                self.fileLog("Network changed: \(self.currentNetworkPath) → \(pathKey) (no restart)")
                self.currentNetworkPath = pathKey
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
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
        memPressureSource?.cancel(); memPressureSource = nil
        pathMonitor?.cancel(); pathMonitor = nil
        readSource?.cancel(); readSource = nil

        if appSideFd >= 0 { close(appSideFd); appSideFd = -1 }
        if tunSideFd >= 0 { close(tunSideFd); tunSideFd = -1 }
        readBuf?.deallocate(); readBuf = nil
        txIov?.deallocate(); txIov = nil

        hev_socks5_tunnel_quit()
        _ = LibXrayStopXray()
        fileLog("xray stopped")

        flushLog()
        logTimer?.cancel(); logTimer = nil
        logFileHandle?.closeFile()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completionHandler() }
    }
}
