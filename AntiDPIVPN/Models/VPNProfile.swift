import Foundation

struct VPNProfile: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String = "Default Profile"
    var serverAddress: String = "77.90.8.199"
    var serverPort: Int = 20443
    var uuid: String = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

    // REALITY settings
    var realityPublicKey: String = "PxiMzZMXrYDmutuMmOBxzS0IGCn8UL0ywmbt1TA241c"
    var realityShortId: String = "abcd1234"
    var realityServerName: String = "www.google.com"
    var realityFingerprint: String = "chrome"

    // Anti-DPI settings
    var antiDPISettings: AntiDPISettings = AntiDPISettings()

    // Metadata
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, name, serverAddress, serverPort, uuid
        case realityPublicKey, realityShortId, realityServerName, realityFingerprint
        case antiDPISettings, createdAt, updatedAt
    }
}
