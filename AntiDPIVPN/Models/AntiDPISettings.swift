import Foundation

struct AntiDPISettings: Codable {
    // Master toggle
    var enabled: Bool = false

    // Scatter settings
    var scatterEnabled: Bool = true
    var scatterMinBytes: Int = 64
    var scatterMaxBytes: Int = 256

    // Heartbeat settings
    var heartbeatEnabled: Bool = true
    var heartbeatMinInterval: Int = 10
    var heartbeatMaxInterval: Int = 30

    // Random record sizes
    var randomRecordSizes: Bool = true

    // Header padding settings
    var headerPaddingEnabled: Bool = true
    var headerPaddingMinBytes: Int = 16
    var headerPaddingMaxBytes: Int = 64

    enum CodingKeys: String, CodingKey {
        case enabled
        case scatterEnabled, scatterMinBytes, scatterMaxBytes
        case heartbeatEnabled, heartbeatMinInterval, heartbeatMaxInterval
        case randomRecordSizes
        case headerPaddingEnabled, headerPaddingMinBytes, headerPaddingMaxBytes
    }
}
