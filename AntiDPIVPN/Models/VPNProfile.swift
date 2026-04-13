import Foundation

struct VPNProfile: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String = ""
    var serverAddress: String = ""
    var serverPort: Int = 443
    var uuid: String = ""

    // REALITY settings
    var realityPublicKey: String = ""
    var realityShortId: String = ""
    var realityServerName: String = ""
    var realityFingerprint: String = "chrome"

    // NFS Encryption key (separate from REALITY key, used for anti-DPI)
    var nfsPublicKey: String = ""

    // Anti-DPI settings
    var antiDPISettings: AntiDPISettings = AntiDPISettings()

    // DNS settings (empty = use defaults 8.8.8.8 + 2001:4860:4860::8888)
    var dnsServers: [String] = []

    // Metadata
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, name, serverAddress, serverPort, uuid
        case realityPublicKey, realityShortId, realityServerName, realityFingerprint
        case nfsPublicKey
        case antiDPISettings, dnsServers, createdAt, updatedAt
    }

    var effectiveDNS: [String] {
        dnsServers.isEmpty ? ["8.8.8.8", "2001:4860:4860::8888"] : dnsServers
    }
}
