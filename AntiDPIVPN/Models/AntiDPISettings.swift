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

    // === Adaptive Anti-DPI ===
    // Automatically adjusts concurrency, bandwidth, and mux settings
    // to evade DPI detection. Reduces params on disconnects, increases
    // when connection is stable for extended periods.
    var adaptiveEnabled: Bool = true

    // Max concurrent TCP connections (mux concurrency)
    // Lower = stealthier but slower
    var maxConcurrency: Int = 4

    // Bandwidth limit in KB/s (0 = unlimited)
    // Lower = harder for DPI to detect as VPN
    var bandwidthLimitKBs: Int = 0  // 0 = unlimited, in KB/s

    enum CodingKeys: String, CodingKey {
        case enabled
        case scatterEnabled, scatterMinBytes, scatterMaxBytes
        case heartbeatEnabled, heartbeatMinInterval, heartbeatMaxInterval
        case randomRecordSizes
        case headerPaddingEnabled, headerPaddingMinBytes, headerPaddingMaxBytes
        case adaptiveEnabled, maxConcurrency, bandwidthLimitKBs
    }
}
