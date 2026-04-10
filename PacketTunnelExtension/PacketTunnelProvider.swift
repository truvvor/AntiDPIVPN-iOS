import NetworkExtension
import os.log

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

    /// Check if a string is an IPv6 address
    private func isIPv6Address(_ address: String) -> Bool {
        return address.contains(":")
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log(.info, "PacketTunnelProvider: Starting tunnel (build 12)")
        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = protocolConfig.providerConfiguration,
              let configJSON = providerConfig["configJSON"] as? String else {
            completionHandler(NSError(domain: "PTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing VPN configuration"]))
            return
        }
        let socksPort = providerConfig["socksPort"] as? Int ?? 3080
        let serverAddress = providerConfig["serverAddress"] as? String ?? ""
        os_log(.info, "PacketTunnelProvider: socksPort=%d serverAddress=%{public}@", socksPort, serverAddress)
        let extDocsDir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let extLibDir = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let datDir = extDocsDir + "/xray_dat"
        let mphCachePath = extLibDir + "/xray_cache"
        try? FileManager.default.createDirectory(atPath: datDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: mphCachePath, withIntermediateDirectories: true)
        let requestDict: [String: Any] = ["datDir": datDir, "mphCachePath": mphCachePath, "configJSON": configJSON]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestDict) else {
            completionHandler(NSError(domain: "PTP", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize config"]))
            return
        }
        let base64String = jsonData.base64EncodedString()
        os_log(.info, "PacketTunnelProvider: Starting Xray...")
        let responseBase64 = LibXrayRunXrayFromJSON(base64String)
        if let responseData = Data(base64Encoded: responseBase64),
           let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            let success = response["success"] as? Bool ?? false
            let errMsg = response["error"] as? String ?? "unknown"
            os_log(.info, "PacketTunnelProvider: Xray response: success=%d error=%{public}@", success, errMsg)
            if !success {
                completionHandler(NSError(domain: "PTP", code: -3, userInfo: [NSLocalizedDescriptionKey: "Xray: \(errMsg)"]))
                return
            }
        } else {
            completionHandler(NSError(domain: "PTP", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Xray response"]))
            return
        }
        os_log(.info, "PacketTunnelProvider: Xray started on SOCKS5 port %d", socksPort)

        // Use a dummy IPv4 address for tunnelRemoteAddress if server is IPv6
        let tunnelRemote: String
        if serverAddress.isEmpty {
            tunnelRemote = "254.1.1.1"
        } else if isIPv6Address(serverAddress) {
            tunnelRemote = "254.1.1.1"
        } else {
            tunnelRemote = serverAddress
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelRemote)
        settings.mtu = 1500

        // IPv4 settings — always needed for tunnel interface
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        if !serverAddress.isEmpty && !isIPv6Address(serverAddress) {
            ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: serverAddress, subnetMask: "255.255.255.255")]
        }
        settings.ipv4Settings = ipv4

        // IPv6 settings — needed for IPv6 server exclusion and full IPv6 tunnel
        let ipv6 = NEIPv6Settings(addresses: ["fd00::1"], networkPrefixLengths: [128])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        if !serverAddress.isEmpty && isIPv6Address(serverAddress) {
            os_log(.info, "PacketTunnelProvider: Adding IPv6 excluded route for %{public}@", serverAddress)
            ipv6.excludedRoutes = [NEIPv6Route(destinationAddress: serverAddress, networkPrefixLength: 128)]
        }
        settings.ipv6Settings = ipv6

        settings.dnsSettings = NEDNSSettings(servers: ["8.8.8.8", "2001:4860:4860::8888"])

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                os_log(.error, "PacketTunnelProvider: setTunnelNetworkSettings failed: %{public}@", error.localizedDescription)
                completionHandler(error)
                return
            }
            os_log(.info, "PacketTunnelProvider: Network settings applied (IPv4+IPv6), starting tun2socks")
            self?.startTun2Socks(socksPort: socksPort)
            self?.isTunnelRunning = true
            completionHandler(nil)
        }
    }

    private func startTun2Socks(socksPort: Int) {
        var fds: [Int32] = [0, 0]
        let ret = socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds)
        guard ret == 0 else { os_log(.error, "PacketTunnelProvider: socketpair failed errno=%d", errno); return }
        tunSideFd = fds[0]; appSideFd = fds[1]
        var bufSize: Int32 = 2 * 1024 * 1024
        setsockopt(tunSideFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(tunSideFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(appSideFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(appSideFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(appSideFd, F_GETFL)
        fcntl(appSideFd, F_SETFL, flags | O_NONBLOCK)
        os_log(.info, "PacketTunnelProvider: socketpair tunFd=%d appFd=%d (non-blocking)", tunSideFd, appSideFd)
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
          log-level: debug
        """
        os_log(.info, "PacketTunnelProvider: Starting hev-socks5-tunnel with fd=%d", tunSideFd)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let configData = config.data(using: .utf8) else { return }
            configData.withUnsafeBytes { ptr in
                let basePtr = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let result = hev_socks5_tunnel_main_from_str(basePtr, UInt32(configData.count), self.tunSideFd)
                os_log(.info, "PacketTunnelProvider: hev-socks5-tunnel exited code=%d", result)
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
                framedPacket.withUnsafeBytes { ptr in
                    guard let base = ptr.baseAddress else { return }
                    let _ = write(self.appSideFd, base, framedPacket.count)
                }
                self.packetCount += 1
            }
            if self.packetCount % 200 == 0 && self.packetCount > 0 {
                os_log(.info, "PacketTunnelProvider: stats sent=%lu recv=%lu", self.packetCount, self.relayedBackCount)
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
        source.setCancelHandler { os_log(.info, "PacketTunnelProvider: dispatch source cancelled") }
        readSource = source
        source.resume()
        os_log(.info, "PacketTunnelProvider: dispatch source started")
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log(.info, "PacketTunnelProvider: Stopping tunnel reason=%d", reason.rawValue)
        os_log(.info, "PacketTunnelProvider: final stats sent=%lu recv=%lu", packetCount, relayedBackCount)
        isTunnelRunning = false; isRelayRunning = false
        readSource?.cancel(); readSource = nil
        if appSideFd >= 0 { close(appSideFd); appSideFd = -1 }
        if tunSideFd >= 0 { close(tunSideFd); tunSideFd = -1 }
        hev_socks5_tunnel_quit()
        let _ = LibXrayStopXray()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completionHandler() }
    }
}
