import Foundation
import os.log

/// Manages geosite.dat and geoip.dat files required for geo-based routing rules.
/// Downloads from GitHub on first use, cached in the shared app group container.
class GeoDataManager {
    static let shared = GeoDataManager()

    private let geositeURL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    private let geoipURL = "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.truvvor.secureconnect")
    }

    private var datDir: URL? {
        sharedContainerURL?.appendingPathComponent("xray_dat")
    }

    /// Check if geo data files exist.
    var hasGeoData: Bool {
        guard let dir = datDir else { return false }
        let geositePath = dir.appendingPathComponent("geosite.dat").path
        let geoipPath = dir.appendingPathComponent("geoip.dat").path
        return FileManager.default.fileExists(atPath: geositePath)
            && FileManager.default.fileExists(atPath: geoipPath)
    }

    /// Check if a RouteConfig requires geo data files.
    func needsGeoData(for config: RouteConfig) -> Bool {
        config.rules.contains { $0.type == .geosite || $0.type == .geoip }
    }

    /// Ensure geo data files are present. Downloads if missing.
    func ensureGeoData(progress: @escaping (String) -> Void, completion: @escaping (Error?) -> Void) {
        guard let dir = datDir else {
            completion(NSError(domain: "GeoData", code: -1, userInfo: [NSLocalizedDescriptionKey: "No shared container"]))
            return
        }

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if hasGeoData {
            completion(nil)
            return
        }

        let group = DispatchGroup()
        var downloadError: Error?

        let files: [(String, String)] = [
            ("geosite.dat", geositeURL),
            ("geoip.dat", geoipURL)
        ]

        for (filename, urlString) in files {
            let destPath = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: destPath.path) { continue }

            group.enter()
            progress("Downloading \(filename)...")
            os_log(.info, "GeoData: downloading %{public}@", filename)

            guard let url = URL(string: urlString) else {
                group.leave()
                continue
            }

            URLSession.shared.downloadTask(with: url) { tempURL, response, error in
                defer { group.leave() }
                if let error = error {
                    os_log(.error, "GeoData: download failed for %{public}@: %{public}@", filename, error.localizedDescription)
                    downloadError = error
                    return
                }
                guard let tempURL = tempURL else { return }
                do {
                    if FileManager.default.fileExists(atPath: destPath.path) {
                        try FileManager.default.removeItem(at: destPath)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destPath)
                    os_log(.info, "GeoData: %{public}@ saved (%d bytes)", filename,
                           (try? FileManager.default.attributesOfItem(atPath: destPath.path)[.size] as? Int) ?? 0)
                } catch {
                    os_log(.error, "GeoData: save failed for %{public}@: %{public}@", filename, error.localizedDescription)
                    downloadError = error
                }
            }.resume()
        }

        group.notify(queue: .main) {
            completion(downloadError)
        }
    }
}
