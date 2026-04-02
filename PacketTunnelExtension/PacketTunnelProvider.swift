import NetworkExtension
import os.log

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var isTunnelRunning = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log(.info, "PacketTunnelProvider: Starting tunnel")

        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = protocolConfig.providerConfiguration,
              let configJSON = providerConfig["configJSON"] as? String,
              let datDir = providerConfig["datDir"] as? String,
              let mphCachePath = providerConfig["mphCachePath"] as? String else {
            os_log(.error, "PacketTunnelProvider: Missing provider configuration")
            completionHandler(NSError(domain: "PacketTunnelProvider", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "Missing VPN configuration"]))
            return
        }

        let socksPort = providerConfig["socksPort"] as? Int ?? 3080

        // Create directories
        try? FileManager.default.createDirectory(atPath: datDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: mphCachePath, withIntermediateDirectories: true)

        // Start Xray via LibXray
        let requestDict: [String: Any] = [
            "datDir": datDir,
            "mphCachePath": mphCachePath,
            "configJSON": configJSON
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestDict) else {
            completionHandler(NSError(domain: "PacketTunnelProvider", code: -2,
                                      userInfo: [NSLocalizedDescriptionKey: "Failed to serialize config"]))
            return
        }

        let base64String = jsonData.base64EncodedString()
        let responseBase64 = LibXrayRunXrayFromJSON(base64String)

        // Parse response
        guard let responseData = Data(base64Encoded: responseBase64),
              let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let success = response["success"] as? Bool, success else {
            let errorMsg = "Failed to start Xray"
            if let responseData = Data(base64Encoded: responseBase64),
               let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let err = response["error"] as? String {
                os_log(.error, "PacketTunnelProvider: Xray error: %@", err)
                completionHandler(NSError(domain: "PacketTunnelProvider", code: -3,
                                          userInfo: [NSLocalizedDescriptionKey: err]))
            } else {
                completionHandler(NSError(domain: "PacketTunnelProvider", code: -3,
                                          userInfo: [NSLocalizedDescriptionKey: errorMsg]))
            }
            return
        }

        os_log(.info, "PacketTunnelProvider: Xray started on SOCKS5 port %d", socksPort)

        // Configure TUN network settings
        let tunnelAddress = "198.18.0.1"
        let tunnelMask = "255.255.255.0"
        let dnsServer = "8.8.8.8"

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "254.1.1.1")
        settings.mtu = 1500

        let ipv4 = NEIPv4Settings(addresses: [tunnelAddress], subnetMasks: [tunnelMask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: [dnsServer])

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                os_log(.error, "PacketTunnelProvider: Failed to set network settings: %@", error.localizedDescription)
                completionHandler(error)
                return
            }

            os_log(.info, "PacketTunnelProvider: Network settings applied, starting tun2socks")

            // Start hev-socks5-tunnel in background
            DispatchQueue.global(qos: .userInitiated).async {
                self?.startTun2Socks(socksPort: socksPort, dnsServer: dnsServer)
            }

            self?.isTunnelRunning = true
            completionHandler(nil)
        }
    }

    private func startTun2Socks(socksPort: Int, dnsServer: String) {
        // hev-socks5-tunnel YAML config
        let config = """
        tunnel:
          name: tun0
          mtu: 1500
        socks5:
          address: "127.0.0.1"
          port: \(socksPort)
        dns:
          address: "\(dnsServer)"
          port: 53
        log_level: 2
        """

        guard let configData = config.data(using: .utf8) else {
            os_log(.error, "PacketTunnelProvider: Failed to create tun2socks config")
            return
        }

        let tunFd = self.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 ?? -1

        os_log(.info, "PacketTunnelProvider: Starting hev-socks5-tunnel with fd=%d", tunFd)

        configData.withUnsafeBytes { ptr in
            let basePtr = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let result = hev_socks5_tunnel_main_from_str(basePtr, UInt32(configData.count), tunFd)
            os_log(.info, "PacketTunnelProvider: hev-socks5-tunnel exited with code %d", result)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log(.info, "PacketTunnelProvider: Stopping tunnel")
        isTunnelRunning = false

        // Stop hev-socks5-tunnel
        hev_socks5_tunnel_quit()

        // Stop Xray
        let _ = LibXrayStopXray()

        completionHandler()
    }
}
