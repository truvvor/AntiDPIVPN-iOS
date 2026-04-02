import Foundation

class XrayService: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var version: String = "Unknown"
    @Published var errorMessage: String? = nil
    @Published var trafficUp: Int64 = 0
    @Published var trafficDown: Int64 = 0

    private let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    private let libraryPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].path

    init() {
        updateVersion()
    }

    func startVPN(with config: String) -> Result<Void, XrayError> {
        // Prepare directories
        let datDir = (documentsPath as NSString).appendingPathComponent("xray_dat")
        let mphCachePath = (libraryPath as NSString).appendingPathComponent("xray_cache")

        do {
            try FileManager.default.createDirectory(atPath: datDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: mphCachePath, withIntermediateDirectories: true)
        } catch {
            return .failure(.failedToCreateDirectories(error.localizedDescription))
        }

        // Prepare request JSON
        let requestDict: [String: Any] = [
            "datDir": datDir,
            "mphCachePath": mphCachePath,
            "configJSON": config
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return .failure(.failedToSerializeJSON)
        }

        guard let base64Text = jsonString.data(using: .utf8)?.base64EncodedString() else {
            return .failure(.failedToEncodeBase64)
        }

        // Call LibXray function
        let responseBase64 = LibXrayRunXrayFromJSON(base64Text)

        guard let responseData = Data(base64Encoded: responseBase64),
              let responseString = String(data: responseData, encoding: .utf8),
              let responseDictData = responseString.data(using: .utf8),
              let responseDict = try? JSONSerialization.jsonObject(with: responseDictData) as? [String: Any]
        else {
            return .failure(.failedToDecodeResponse)
        }

        if let success = responseDict["success"] as? Bool, success {
            DispatchQueue.main.async {
                self.isRunning = true
                self.errorMessage = nil
            }
            return .success(())
        } else {
            let message = (responseDict["message"] as? String) ?? "Unknown error"
            DispatchQueue.main.async {
                self.errorMessage = message
            }
            return .failure(.xrayError(message))
        }
    }

    func stopVPN() -> Result<Void, XrayError> {
        let responseBase64 = LibXrayStopXray()

        guard let responseData = Data(base64Encoded: responseBase64),
              let responseString = String(data: responseData, encoding: .utf8),
              let responseDictData = responseString.data(using: .utf8),
              let responseDict = try? JSONSerialization.jsonObject(with: responseDictData) as? [String: Any]
        else {
            return .failure(.failedToDecodeResponse)
        }

        if let success = responseDict["success"] as? Bool, success {
            DispatchQueue.main.async {
                self.isRunning = false
                self.errorMessage = nil
            }
            return .success(())
        } else {
            let message = (responseDict["message"] as? String) ?? "Unknown error"
            return .failure(.xrayError(message))
        }
    }

    func refreshState() {
        DispatchQueue.main.async {
            self.isRunning = LibXrayGetXrayState()
        }
    }

    private func updateVersion() {
        DispatchQueue.global(qos: .background).async {
            let version = LibXrayXrayVersion()
            DispatchQueue.main.async {
                self.version = version
            }
        }
    }
}

enum XrayError: LocalizedError {
    case failedToCreateDirectories(String)
    case failedToSerializeJSON
    case failedToEncodeBase64
    case failedToDecodeResponse
    case xrayError(String)

    var errorDescription: String? {
        switch self {
        case .failedToCreateDirectories(let details):
            return "Failed to create directories: \(details)"
        case .failedToSerializeJSON:
            return "Failed to serialize configuration JSON"
        case .failedToEncodeBase64:
            return "Failed to encode configuration to base64"
        case .failedToDecodeResponse:
            return "Failed to decode response from Xray"
        case .xrayError(let message):
            return "Xray error: \(message)"
        }
    }
}
