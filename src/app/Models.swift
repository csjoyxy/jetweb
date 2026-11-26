import Foundation
import UIKit

enum JWConstants {
    static let dataDir = "/var/mobile/Library/JetWeb"
    static let configPath = "/var/mobile/Library/JetWeb/config.json"
    static let pilotDir = "/var/mobile/Library/JetPilot"
    static let sharedPidPath = "/var/mobile/Library/JetPilot/webhub_pids.txt"

    static let maxSites = 8
    static let defaultBand = 85
    static let defaultMaxMB = 450

    static let appearanceInherit = "inherit"
    static let appearanceSystem = "system"
    static let appearanceLight = "light"
    static let appearanceDark = "dark"

    static let dataStoreDefault = "default"
}

enum JWAppearanceHelper {
    static func normalizeGlobal(_ raw: String?) -> String {
        guard let raw = raw else { return JWConstants.appearanceSystem }
        if raw == JWConstants.appearanceLight || raw == JWConstants.appearanceDark {
            return raw
        }
        return JWConstants.appearanceSystem
    }

    static func normalizeSite(_ raw: String?) -> String {
        guard let raw = raw else { return JWConstants.appearanceInherit }
        if raw == JWConstants.appearanceSystem || raw == JWConstants.appearanceLight || raw == JWConstants.appearanceDark {
            return raw
        }
        return JWConstants.appearanceInherit
    }

    static func label(for mode: String) -> String {
        switch mode {
        case JWConstants.appearanceLight: return "强制浅色"
        case JWConstants.appearanceDark: return "强制深色"
        case JWConstants.appearanceSystem: return "跟随系统"
        default: return "跟随全局"
        }
    }

    static func uiStyle(for resolvedMode: String, fallback: UIUserInterfaceStyle = .unspecified) -> UIUserInterfaceStyle {
        switch resolvedMode {
        case JWConstants.appearanceLight: return .light
        case JWConstants.appearanceDark: return .dark
        default: return fallback
        }
    }
}

enum JWDataStoreHelper {
    static func normalize(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.lowercased() != JWConstants.dataStoreDefault else {
            return JWConstants.dataStoreDefault
        }
        if let uuid = UUID(uuidString: raw),
           uuid.uuidString != "00000000-0000-0000-0000-000000000000" {
            return uuid.uuidString.uppercased()
        }
        return JWConstants.dataStoreDefault
    }

    static func isIsolated(_ raw: String?) -> Bool {
        return normalize(raw) != JWConstants.dataStoreDefault
    }

    static func label(for raw: String?) -> String {
        return isIsolated(raw) ? "独立账号空间" : "默认共享空间"
    }

    static func shortBadge(for raw: String?) -> String {
        let norm = normalize(raw)
        if norm == JWConstants.dataStoreDefault {
            return "默认共享"
        }
        return "独立账号(\(String(norm.prefix(6))))"
    }
}

enum JWURLHelper {
    static func normalize(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme, !scheme.isEmpty,
              let host = url.host, !host.isEmpty else {
            return ""
        }
        return trimmed
    }

    static func hostKey(_ urlStr: String) -> String {
        return URL(string: normalize(urlStr))?.host?.lowercased() ?? ""
    }

    static func shortFingerprint(_ hex: String) -> String {
        if hex.count < 16 { return hex }
        let start = hex.prefix(8)
        let end = hex.suffix(8)
        return "\(start)...\(end)"
    }
}

struct SiteItem: Identifiable, Equatable {
    var id: String
    var title: String
    var urlString: String
    var enabled: Bool
    var appearanceMode: String
    var dataStoreId: String

    init(
        id: String = UUID().uuidString,
        title: String = "",
        urlString: String = "",
        enabled: Bool = true,
        appearanceMode: String = JWConstants.appearanceInherit,
        dataStoreId: String = JWConstants.dataStoreDefault
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.enabled = enabled
        self.appearanceMode = JWAppearanceHelper.normalizeSite(appearanceMode)
        self.dataStoreId = JWDataStoreHelper.normalize(dataStoreId)
    }

    var isIsolatedStore: Bool {
        JWDataStoreHelper.isIsolated(dataStoreId)
    }

    static func fromDictionary(_ dict: [String: Any]) -> SiteItem? {
        guard let url = dict["url"] as? String, !url.isEmpty else { return nil }
        let sid = (dict["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
        let rawTitle = (dict["title"] as? String) ?? ""
        let enabled = (dict["enabled"] as? NSNumber)?.boolValue ?? (dict["enabled"] as? Bool) ?? true
        let appearance = JWAppearanceHelper.normalizeSite(dict["appearanceMode"] as? String)
        let dsId = JWDataStoreHelper.normalize(dict["dataStoreId"] as? String)
        return SiteItem(
            id: sid,
            title: rawTitle.isEmpty ? url : rawTitle,
            urlString: url,
            enabled: enabled,
            appearanceMode: appearance,
            dataStoreId: dsId
        )
    }

    func toDictionary() -> [String: Any] {
        return [
            "id": id.isEmpty ? UUID().uuidString : id,
            "title": title,
            "url": urlString,
            "enabled": enabled,
            "appearanceMode": JWAppearanceHelper.normalizeSite(appearanceMode),
            "dataStoreId": JWDataStoreHelper.normalize(dataStoreId)
        ]
    }
}

struct ProcStatus: Equatable {
    var pid: Int32
    var band: Int
    var footprintMB: Int
    var stateTag: String

    func displayBadge(targetBand: Int, maxMB: Int) -> String {
        if stateTag == "OVER_MEM" || (maxMB > 0 && footprintMB > maxMB) {
            return "OVER_MEM"
        }
        if stateTag == "FG" || band >= targetBand || band >= 100 {
            return "OK"
        }
        return stateTag
    }

    static func parseHelperOutput(_ output: String) -> [Int32: ProcStatus] {
        var map: [Int32: ProcStatus] = [:]
        guard !output.isEmpty else { return map }
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count < 2 { continue }
            let tag = parts[0]
            var pid: Int32 = 0
            var band: Int = -1
            var fp: Int = 0
            for kv in parts.dropFirst() {
                if kv.hasPrefix("pid="), let v = Int32(kv.dropFirst(4)) {
                    pid = v
                } else if kv.hasPrefix("after="), let v = Int(kv.dropFirst(6)) {
                    band = v
                } else if kv.hasPrefix("cur="), band < 0, let v = Int(kv.dropFirst(4)) {
                    band = v
                } else if kv.hasPrefix("fp="), let v = Int(kv.dropFirst(3)) {
                    fp = v
                }
            }
            if pid > 0 {
                map[pid] = ProcStatus(pid: pid, band: band, footprintMB: fp, stateTag: tag)
            }
        }
        return map
    }
}

final class AppConfig: ObservableObject {
    @Published var sites: [SiteItem] = []
    @Published var selectedSiteId: String = ""
    @Published var targetBand: Int = JWConstants.defaultBand
    @Published var maxMemoryMB: Int = JWConstants.defaultMaxMB
    @Published var dockCollapsed: Bool = false
    @Published var appearanceMode: String = JWConstants.appearanceSystem
    @Published var trustedCerts: [String: String] = [:]
    @Published var debugLoggingEnabled: Bool = true

    func effectiveAppearanceMode(for site: SiteItem?) -> String {
        if let site = site {
            let siteMode = JWAppearanceHelper.normalizeSite(site.appearanceMode)
            if siteMode != JWConstants.appearanceInherit {
                return siteMode
            }
        }
        return JWAppearanceHelper.normalizeGlobal(appearanceMode)
    }

    func hasExistingSite(matchingHostOf urlStr: String, excludingId: String? = nil) -> Bool {
        let host = JWURLHelper.hostKey(urlStr)
        guard !host.isEmpty else { return false }
        return sites.contains { item in
            if let ex = excludingId, item.id == ex { return false }
            return JWURLHelper.hostKey(item.urlString) == host
        }
    }

    static func effectiveDir() -> String {
        let fm = FileManager.default
        if (try? fm.createDirectory(
            atPath: JWConstants.dataDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )) != nil {
            return JWConstants.dataDir
        }
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
        return docs ?? NSTemporaryDirectory()
    }

    static func effectiveConfigPath() -> String {
        let dir = effectiveDir()
        if dir == JWConstants.dataDir {
            return JWConstants.configPath
        }
        return (dir as NSString).appendingPathComponent("config.json")
    }

    static func effectiveBgEpochPath() -> String {
        return (effectiveDir() as NSString).appendingPathComponent("bg_epoch.txt")
    }

    static func effectiveFallbackDataStoresDir() -> String {
        return (effectiveDir() as NSString).appendingPathComponent("DataStores")
    }

    static func load() -> AppConfig {
        let cfg = AppConfig()
        let path = effectiveConfigPath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !data.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return cfg
        }

        if let rawSites = root["sites"] as? [[String: Any]] {
            for obj in rawSites {
                if cfg.sites.count >= JWConstants.maxSites { break }
                if let item = SiteItem.fromDictionary(obj) {
                    cfg.sites.append(item)
                }
            }
        }
        if let sel = root["selectedSiteId"] as? String {
            cfg.selectedSiteId = sel
        }
        if let b = (root["targetBand"] as? NSNumber)?.intValue ?? (root["targetBand"] as? Int),
           (30...95).contains(b) {
            cfg.targetBand = b
        }
        if let m = (root["maxMemoryMB"] as? NSNumber)?.intValue ?? (root["maxMemoryMB"] as? Int),
           (150...1200).contains(m) {
            cfg.maxMemoryMB = m
        }
        if let dc = (root["dockCollapsed"] as? NSNumber)?.boolValue ?? (root["dockCollapsed"] as? Bool) {
            cfg.dockCollapsed = dc
        }
        if let am = root["appearanceMode"] as? String {
            cfg.appearanceMode = JWAppearanceHelper.normalizeGlobal(am)
        }
        if let rawCerts = root["trustedCerts"] as? [String: Any] {
            for (k, v) in rawCerts {
                if let strVal = v as? String {
                    let host = k.lowercased()
                    let fp = strVal.uppercased()
                    if !host.isEmpty && fp.count >= 32 {
                        cfg.trustedCerts[host] = fp
                    }
                }
            }
        }
        if let dl = (root["debugLoggingEnabled"] as? NSNumber)?.boolValue ?? (root["debugLoggingEnabled"] as? Bool) {
            cfg.debugLoggingEnabled = dl
        }
        return cfg
    }

    @discardableResult
    func save() -> Bool {
        let siteDicts = sites.map { $0.toDictionary() }
        let root: [String: Any] = [
            "sites": siteDicts,
            "selectedSiteId": selectedSiteId,
            "targetBand": targetBand,
            "maxMemoryMB": maxMemoryMB,
            "dockCollapsed": dockCollapsed,
            "appearanceMode": JWAppearanceHelper.normalizeGlobal(appearanceMode),
            "trustedCerts": trustedCerts,
            "debugLoggingEnabled": debugLoggingEnabled
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) else {
            return false
        }
        let path = AppConfig.effectiveConfigPath()
        do {
            try json.write(to: URL(fileURLWithPath: path), options: [.atomic])
            return true
        } catch {
            return false
        }
    }
}
