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
    static let defaultBgNotifyMinutes = 15
    static let defaultIdleHibernateMinutes = 30
    static let allowedIdleHibernateMinutes = [0, 10, 20, 30, 60]
    static let minSiteBand = 30
    static let maxSiteBand = 92

    static let bandPresetCore = 88
    static let bandPresetFrequent = 80
    static let bandPresetSecondary = 70
    static let bandPresetDisposable = 35

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

    static func sanitizePersistedURL(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "about:blank",
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty else {
            return ""
        }
        return trimmed
    }
}

enum JWPriorityHelper {
    /// 0 means follow global targetBand; otherwise clamped to [30, 92].
    static func normalizeCustomBand(_ raw: Int?) -> Int {
        guard let raw = raw, raw > 0 else { return 0 }
        return min(JWConstants.maxSiteBand, max(JWConstants.minSiteBand, raw))
    }

    static func clampSiteBand(_ band: Int) -> Int {
        return min(JWConstants.maxSiteBand, max(JWConstants.minSiteBand, band))
    }

    static func tierDescription(customBand: Int, globalBand: Int) -> String {
        let norm = normalizeCustomBand(customBand)
        if norm == 0 {
            let eff = clampSiteBand(globalBand)
            return "跟随全局 (\(eff)档)"
        }
        switch norm {
        case JWConstants.bandPresetCore:
            return "核心常驻 (\(norm)档)"
        case JWConstants.bandPresetFrequent:
            return "常用保活 (\(norm)档)"
        case JWConstants.bandPresetSecondary:
            return "次要备选 (\(norm)档)"
        case JWConstants.bandPresetDisposable:
            return "随用随清 (\(norm)档)"
        default:
            return "自定义 (\(norm)档)"
        }
    }

    static func shortBadge(customBand: Int, globalBand: Int) -> String {
        let norm = normalizeCustomBand(customBand)
        if norm == 0 {
            return "\(clampSiteBand(globalBand))档"
        }
        return "\(norm)档·专属"
    }
}

struct SiteItem: Identifiable, Equatable {
    var id: String
    var title: String
    var urlString: String
    var enabled: Bool
    var appearanceMode: String
    var dataStoreId: String
    /// 0 = 跟随全局默认档位；30...92 = 单站点专属进程档位
    var customBand: Int
    /// true = 已休眠释放内存（底栏保留标签与登录态，点击即唤醒）
    var hibernated: Bool
    /// true = 接收该站点新对话/回复完成通知
    var notifyEnabled: Bool
    /// true = 免自动休眠白名单（不受全局闲置倒计时影响）
    var autoHibernateExempt: Bool
    /// 持久化的上次停留对话/子页面地址（重启或休眠唤醒后精准恢复）
    var lastKnownURL: String

    init(
        id: String = UUID().uuidString,
        title: String = "",
        urlString: String = "",
        enabled: Bool = true,
        appearanceMode: String = JWConstants.appearanceInherit,
        dataStoreId: String = JWConstants.dataStoreDefault,
        customBand: Int = 0,
        hibernated: Bool = false,
        notifyEnabled: Bool = true,
        autoHibernateExempt: Bool = false,
        lastKnownURL: String = ""
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.enabled = enabled
        self.appearanceMode = JWAppearanceHelper.normalizeSite(appearanceMode)
        self.dataStoreId = JWDataStoreHelper.normalize(dataStoreId)
        self.customBand = JWPriorityHelper.normalizeCustomBand(customBand)
        self.hibernated = hibernated
        self.notifyEnabled = notifyEnabled
        self.autoHibernateExempt = autoHibernateExempt
        self.lastKnownURL = JWURLHelper.sanitizePersistedURL(lastKnownURL)
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
        let rawBand = (dict["customBand"] as? NSNumber)?.intValue ?? (dict["customBand"] as? Int) ?? 0
        let hibernated = (dict["hibernated"] as? NSNumber)?.boolValue ?? (dict["hibernated"] as? Bool) ?? false
        let notifyEnabled = (dict["notifyEnabled"] as? NSNumber)?.boolValue ?? (dict["notifyEnabled"] as? Bool) ?? true
        let autoHibernateExempt = (dict["autoHibernateExempt"] as? NSNumber)?.boolValue ?? (dict["autoHibernateExempt"] as? Bool) ?? false
        let lastKnownURL = JWURLHelper.sanitizePersistedURL(dict["lastKnownURL"] as? String)
        return SiteItem(
            id: sid,
            title: rawTitle.isEmpty ? url : rawTitle,
            urlString: url,
            enabled: enabled,
            appearanceMode: appearance,
            dataStoreId: dsId,
            customBand: rawBand,
            hibernated: hibernated,
            notifyEnabled: notifyEnabled,
            autoHibernateExempt: autoHibernateExempt,
            lastKnownURL: lastKnownURL
        )
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id.isEmpty ? UUID().uuidString : id,
            "title": title,
            "url": urlString,
            "enabled": enabled,
            "appearanceMode": JWAppearanceHelper.normalizeSite(appearanceMode),
            "dataStoreId": JWDataStoreHelper.normalize(dataStoreId),
            "customBand": JWPriorityHelper.normalizeCustomBand(customBand),
            "hibernated": hibernated,
            "notifyEnabled": notifyEnabled,
            "autoHibernateExempt": autoHibernateExempt
        ]
        let cleanLast = JWURLHelper.sanitizePersistedURL(lastKnownURL)
        if !cleanLast.isEmpty {
            dict["lastKnownURL"] = cleanLast
        }
        return dict
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
    @Published var notificationsEnabled: Bool = true
    /// 0 = 仅前台跨标签通知（退后台不保活）；5 / 15 / 30 / 60 = 退后台等信护航分钟数
    @Published var bgNotifyGuardMinutes: Int = JWConstants.defaultBgNotifyMinutes
    /// 退后台期间收到新消息弹完通知后，缓冲约 1 分钟自动停止后台连线省电
    @Published var bgAutoSleepAfterNotify: Bool = true
    /// 0 = 关闭自动休眠；10 / 20 / 30 / 60 = 后台标签静置超过该分钟数自动休眠释放内存
    @Published var idleHibernateMinutes: Int = JWConstants.defaultIdleHibernateMinutes

    func hasAwakeNotifySite() -> Bool {
        guard notificationsEnabled else { return false }
        return sites.contains { $0.enabled && !$0.hibernated && $0.notifyEnabled }
    }

    func effectiveSiteBand(for site: SiteItem) -> Int {
        let norm = JWPriorityHelper.normalizeCustomBand(site.customBand)
        if norm > 0 {
            return norm
        }
        return JWPriorityHelper.clampSiteBand(targetBand)
    }

    /// Computes automatic guardian bands so Networking/GPU (+1, max 94) and Host (+2, max 95)
    /// always sit above the highest awake site band, preventing parent/socket kills before secondary tabs.
    func computedGuardianBands() -> (auxBand: Int, hostBand: Int) {
        let awakeSites = sites.filter { $0.enabled && !$0.hibernated }
        let maxSite: Int
        if let m = awakeSites.map({ effectiveSiteBand(for: $0) }).max() {
            maxSite = m
        } else {
            maxSite = JWPriorityHelper.clampSiteBand(targetBand)
        }
        let aux = min(94, maxSite + 1)
        let host = min(95, max(targetBand, maxSite + 2))
        return (aux, host)
    }

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
        if let ne = (root["notificationsEnabled"] as? NSNumber)?.boolValue ?? (root["notificationsEnabled"] as? Bool) {
            cfg.notificationsEnabled = ne
        }
        if let bm = (root["bgNotifyGuardMinutes"] as? NSNumber)?.intValue ?? (root["bgNotifyGuardMinutes"] as? Int),
           [0, 5, 15, 30, 60].contains(bm) {
            cfg.bgNotifyGuardMinutes = bm
        }
        if let aslp = (root["bgAutoSleepAfterNotify"] as? NSNumber)?.boolValue ?? (root["bgAutoSleepAfterNotify"] as? Bool) {
            cfg.bgAutoSleepAfterNotify = aslp
        }
        if let im = (root["idleHibernateMinutes"] as? NSNumber)?.intValue ?? (root["idleHibernateMinutes"] as? Int),
           JWConstants.allowedIdleHibernateMinutes.contains(im) {
            cfg.idleHibernateMinutes = im
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
            "debugLoggingEnabled": debugLoggingEnabled,
            "notificationsEnabled": notificationsEnabled,
            "bgNotifyGuardMinutes": bgNotifyGuardMinutes,
            "bgAutoSleepAfterNotify": bgAutoSleepAfterNotify,
            "idleHibernateMinutes": idleHibernateMinutes
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
