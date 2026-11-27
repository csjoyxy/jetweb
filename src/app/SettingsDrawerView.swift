import SwiftUI
import UIKit

final class HubRuntimeState: ObservableObject {
    @Published var liveStatuses: [Int32: ProcStatus] = [:]
    @Published var webPIDsBySiteId: [String: Int32] = [:]
    @Published var terminatedSiteIds: Set<String> = []
    @Published var detachedSiteIds: Set<String> = []
    @Published var isTrimmingMemory: Bool = false
    @Published var helperBannerText: String = ""
    @Published var systemLockdownEnabled: Bool = false
    @Published var lockdownBypassDetected: Bool = false
    @Published var processLockdownExempted: Bool = false
    @Published var dataContainerPath: String = ""

    var onSyncStructure: ((String?) -> Void)?
    var onSetHibernated: ((String, Bool) -> Void)?
    var onUpdateAppearance: (() -> Void)?
    var onUpdateTrustedCerts: (() -> Void)?
    var onApplyProtectionNow: (() -> Void)?
    var onTrimMemoryNow: (() -> Void)?
    var onMemoryPolicyChanged: (() -> Void)?
    var onRefreshLiveStatus: (() -> Void)?
    var onReloadSite: ((String) -> Void)?
    var onClearSiteData: ((String) -> Void)?
    var onClearAllWebsiteData: (() -> Void)?
    var onSendTestNotification: (() -> Void)?
    var onNotificationPolicyChanged: (() -> Void)?
    var onIdleHibernatePolicyChanged: (() -> Void)?
    var onLockdownPolicyChanged: (() -> Void)?
    var buildDiagnosticHeader: (() -> String)?
}

// MARK: - Reusable Per-Site Priority Editor (Presets + Custom 30~92 Input)

private enum SiteBandPresetChoice: String {
    case followGlobal = "global"
    case core88 = "88"
    case frequent80 = "80"
    case secondary70 = "70"
    case disposable35 = "35"
    case custom = "custom"

    static func from(customBand: Int) -> SiteBandPresetChoice {
        let norm = JWPriorityHelper.normalizeCustomBand(customBand)
        switch norm {
        case 0: return .followGlobal
        case JWConstants.bandPresetCore: return .core88
        case JWConstants.bandPresetFrequent: return .frequent80
        case JWConstants.bandPresetSecondary: return .secondary70
        case JWConstants.bandPresetDisposable: return .disposable35
        default: return .custom
        }
    }
}

struct SitePriorityEditorSection: View {
    @Binding var customBand: Int
    let globalBand: Int
    var onChanged: (() -> Void)? = nil

    @State private var choice: SiteBandPresetChoice = .followGlobal
    @State private var customText: String = "82"
    @State private var didInit: Bool = false

    private var clampedGlobal: Int {
        JWPriorityHelper.clampSiteBand(globalBand)
    }

    var body: some View {
        Section(
            header: Text("进程保活等级（主次先后顺序）"),
            footer: Text("iOS 内存紧张时严格从低档位往高档位回收。单站点范围 30~92 档；网络/GPU 与 JetWeb 主进程会自动压阵在最高标签之上 (+1/+2 档，上限 95)，防止主容器先被杀。")
        ) {
            Picker("保活分档", selection: Binding(
                get: { choice },
                set: { newChoice in
                    choice = newChoice
                    applyChoice(newChoice)
                }
            )) {
                Text("跟随全局默认（\(clampedGlobal) 档）").tag(SiteBandPresetChoice.followGlobal)
                Text("🔥 核心常驻（88 档 · 最后回收）").tag(SiteBandPresetChoice.core88)
                Text("⭐️ 常用保活（80 档 · 高优常驻）").tag(SiteBandPresetChoice.frequent80)
                Text("📌 次要备选（70 档 · 优先让路）").tag(SiteBandPresetChoice.secondary70)
                Text("🍃 随用随清（35 档 · 内存紧先清）").tag(SiteBandPresetChoice.disposable35)
                Text("🎛 自定义精确档位（30 ~ 92）").tag(SiteBandPresetChoice.custom)
            }

            if choice == .custom {
                HStack {
                    Text("自定义档位 (30~92)")
                        .font(.subheadline)
                    Spacer()
                    TextField("30~92", text: $customText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospacedDigit().weight(.semibold))
                        .frame(width: 72)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color(UIColor.tertiarySystemFill))
                        .cornerRadius(6)
                        .onChange(of: customText) { val in
                            let digits = val.filter { $0.isNumber }
                            if digits != val {
                                customText = digits
                            }
                            if let n = Int(digits), (JWConstants.minSiteBand...JWConstants.maxSiteBand).contains(n) {
                                if customBand != n {
                                    customBand = n
                                    onChanged?()
                                }
                            }
                        }
                }

                Stepper(
                    value: Binding(
                        get: {
                            let cur = JWPriorityHelper.normalizeCustomBand(customBand)
                            return cur > 0 ? cur : clampedGlobal
                        },
                        set: { newVal in
                            let clamped = JWPriorityHelper.clampSiteBand(newVal)
                            customBand = clamped
                            customText = "\(clamped)"
                            onChanged?()
                        }
                    ),
                    in: JWConstants.minSiteBand...JWConstants.maxSiteBand
                ) {
                    let eff = JWPriorityHelper.normalizeCustomBand(customBand) > 0
                        ? JWPriorityHelper.normalizeCustomBand(customBand)
                        : clampedGlobal
                    Text("步进微调：当前生效 \(eff) 档")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            if !didInit {
                syncFromBinding()
                didInit = true
            }
        }
        .onChange(of: customBand) { _ in
            let expected = SiteBandPresetChoice.from(customBand: customBand)
            if choice != .custom || customBand == 0 {
                choice = expected
            }
            if customBand > 0 && customText != "\(customBand)" {
                customText = "\(customBand)"
            }
        }
    }

    private func syncFromBinding() {
        choice = SiteBandPresetChoice.from(customBand: customBand)
        let norm = JWPriorityHelper.normalizeCustomBand(customBand)
        customText = "\(norm > 0 ? norm : clampedGlobal)"
    }

    private func applyChoice(_ c: SiteBandPresetChoice) {
        switch c {
        case .followGlobal:
            customBand = 0
        case .core88:
            customBand = JWConstants.bandPresetCore
            customText = "\(JWConstants.bandPresetCore)"
        case .frequent80:
            customBand = JWConstants.bandPresetFrequent
            customText = "\(JWConstants.bandPresetFrequent)"
        case .secondary70:
            customBand = JWConstants.bandPresetSecondary
            customText = "\(JWConstants.bandPresetSecondary)"
        case .disposable35:
            customBand = JWConstants.bandPresetDisposable
            customText = "\(JWConstants.bandPresetDisposable)"
        case .custom:
            let cur = JWPriorityHelper.normalizeCustomBand(customBand)
            let initial = cur > 0 ? cur : clampedGlobal
            customBand = initial
            customText = "\(initial)"
        }
        onChanged?()
    }
}

// MARK: - Settings Root Drawer (SwiftUI)

struct SettingsDrawerView: View {
    @ObservedObject var config: AppConfig
    @ObservedObject var runtime: HubRuntimeState
    var onClose: () -> Void

    @State private var showingAddSheet = false
    @State private var showingClearAllAlert = false
    @State private var showingLimitAlert = false

    private let hostPid: Int32 = getpid()

    private var totalLiveMemoryMB: Int {
        var sum = max(0, runtime.liveStatuses[hostPid]?.footprintMB ?? 0)
        for site in config.sites where site.enabled && !site.hibernated {
            let pid = runtime.webPIDsBySiteId[site.id] ?? 0
            if pid > 0, let st = runtime.liveStatuses[pid] {
                sum += max(0, st.footprintMB)
            }
        }
        return sum
    }

    private var awakeTabCount: Int {
        config.sites.filter { $0.enabled && !$0.hibernated }.count
    }

    private var hibernatedTabCount: Int {
        config.sites.filter { $0.enabled && $0.hibernated }.count
    }

    var body: some View {
        NavigationView {
            List {
                glassDashboardSection
                sitesSection
                lockdownSection
                memoryManagementSection
                notificationSection
                policyAndToolsSection
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("常驻工作台设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") {
                        onClose()
                    }
                    .font(.body.weight(.semibold))
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        if config.sites.count >= JWConstants.maxSites {
                            showingLimitAlert = true
                        } else {
                            showingAddSheet = true
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    EditButton()
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddSiteSheet(config: config, runtime: runtime)
            }
            .alert(isPresented: $showingClearAllAlert) {
                Alert(
                    title: Text("清理全部缓存与登录态？"),
                    message: Text("将清除默认共享空间及所有独立账号空间的 Cookie、LocalStorage 与离线缓存，需重新登录。"),
                    primaryButton: .destructive(Text("确认清理")) {
                        runtime.onClearAllWebsiteData?()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            runtime.onApplyProtectionNow?()
        }
        .alert(isPresented: $showingLimitAlert) {
            Alert(
                title: Text("已达上限"),
                message: Text("为保护 iPhone 4GB 内存，最多同时配置 \(JWConstants.maxSites) 个常驻站点。"),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var glassDashboardSection: some View {
        let guardian = config.computedGuardianBands()
        let hostSt = runtime.liveStatuses[hostPid]
        let hostOK = (hostSt?.band ?? -1) >= guardian.hostBand || (hostSt?.band ?? -1) >= 100

        return Section(
            footer: Text(
                runtime.helperBannerText.isEmpty
                ? "各标签按专属档位分级保活（主容器压阵 \(guardian.hostBand) 档 · 网络/GPU \(guardian.auxBand) 档）；支持不重载「无损内存瘦身」与长按休眠释放内存。"
                : runtime.helperBannerText
            )
        ) {
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.16, green: 0.48, blue: 0.96).opacity(0.18),
                        Color(red: 0.36, green: 0.28, blue: 0.90).opacity(0.14),
                        Color(red: 0.08, green: 0.66, blue: 0.62).opacity(0.12)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            Color(red: 0.16, green: 0.50, blue: 0.98),
                                            Color(red: 0.32, green: 0.28, blue: 0.90)
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 38, height: 38)
                            Image(systemName: "bolt.shield.fill")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundColor(.white)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("JetWeb 护航仪表盘")
                                .font(.system(size: 15.5, weight: .bold))
                                .foregroundColor(.primary)
                            if let st = hostSt, st.band >= 0 {
                                Text("主容器 PID \(hostPid) · \(st.band >= 100 ? "前台活跃(目标\(guardian.hostBand)档)" : "实测 \(st.band) 档") · \(st.footprintMB) MB")
                                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                                    .foregroundColor(hostOK ? Color(JWGlassPalette.foreground(for: .emerald)) : .secondary)
                            } else {
                                Text("读取内核状态中 / 需 TrollStore 安装")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer(minLength: 4)

                        HStack(spacing: 6) {
                            Button {
                                runtime.onTrimMemoryNow?()
                            } label: {
                                HStack(spacing: 3.5) {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 11, weight: .bold))
                                    Text(runtime.isTrimmingMemory ? "瘦身中" : "瘦身")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(Color(JWGlassPalette.chipFill(for: .teal)))
                                .foregroundColor(Color(JWGlassPalette.foreground(for: .teal)))
                                .clipShape(Capsule())
                            }
                            .disabled(runtime.isTrimmingMemory)
                            .buttonStyle(PlainButtonStyle())

                            Button {
                                runtime.onApplyProtectionNow?()
                            } label: {
                                HStack(spacing: 3.5) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("提档")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.16))
                                .foregroundColor(.accentColor)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }

                    HStack(spacing: 8) {
                        dashboardMetricTile(
                            symbol: "square.stack.3d.up.fill",
                            tint: Color(JWGlassPalette.foreground(for: .cobalt)),
                            label: "标签状态",
                            value: "\(awakeTabCount) 活 · \(hibernatedTabCount) 眠"
                        )
                        dashboardMetricTile(
                            symbol: "memorychip",
                            tint: Color(JWGlassPalette.foreground(for: totalLiveMemoryMB > 1100 ? .amber : .emerald)),
                            label: "总内存占用",
                            value: "\(totalLiveMemoryMB) MB"
                        )
                        dashboardMetricTile(
                            symbol: config.notificationsEnabled ? "bell.badge.fill" : "bell.slash.fill",
                            tint: Color(JWGlassPalette.foreground(for: .teal)),
                            label: "后台等信",
                            value: !config.notificationsEnabled
                                ? "已关闭"
                                : (config.bgNotifyGuardMinutes == 0 ? "仅前台" : "\(config.bgNotifyGuardMinutes) 分钟")
                        )
                    }

                    if !config.sites.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(config.sites) { site in
                                dashboardSiteTelemetryRow(for: site)
                            }
                        }
                        .padding(10)
                        .background(Color(UIColor.systemBackground).opacity(0.62))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(15)
                .background(.ultraThinMaterial)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.32), lineWidth: 0.8)
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    private func dashboardMetricTile(symbol: String, tint: Color, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(tint)
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground).opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func dashboardSiteTelemetryRow(for site: SiteItem) -> some View {
        let effBand = config.effectiveSiteBand(for: site)
        let wpid = runtime.webPIDsBySiteId[site.id] ?? 0
        let st = (wpid > 0) ? runtime.liveStatuses[wpid] : nil
        let mb = st?.footprintMB ?? 0
        let ratio = min(1.0, max(0.0, Double(mb) / Double(max(200, config.maxMemoryMB))))

        VStack(spacing: 5) {
            HStack(spacing: 8) {
                siteSquircleBadge(title: site.title, size: 22, fontSize: 10.5, dimmed: !site.enabled || site.hibernated)
                Text(site.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(site.enabled ? .primary : .secondary)
                    .lineLimit(1)
                Spacer()
                siteStatusView(for: site)
            }

            if site.enabled && !site.hibernated && mb > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.16))
                            .frame(height: 4)
                        Capsule()
                            .fill(Color(JWGlassPalette.foreground(for: mb > config.maxMemoryMB ? .amber : (effBand >= 85 ? .cobalt : .emerald))))
                            .frame(width: max(6, geo.size.width * CGFloat(ratio)), height: 4)
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private func siteSquircleBadge(title: String, size: CGFloat, fontSize: CGFloat, dimmed: Bool) -> some View {
        let pair = JWSitePalette.gradientPair(for: title)
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Color(pair.top), Color(pair.bottom)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(JWSitePalette.initialText(for: title))
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? 0.55 : 1.0)
    }

    @ViewBuilder
    private func siteStatusView(for site: SiteItem) -> some View {
        let effBand = config.effectiveSiteBand(for: site)
        let wpid = runtime.webPIDsBySiteId[site.id] ?? 0
        if !site.enabled {
            Text("已隐藏")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(UIColor.tertiaryLabel))
        } else if site.hibernated {
            HStack(spacing: 3) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 9.5, weight: .bold))
                Text("休眠 · 0 MB")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .foregroundColor(Color(JWGlassPalette.foreground(for: .indigo)))
        } else if wpid <= 0 {
            if runtime.terminatedSiteIds.contains(site.id) {
                Text("待恢复")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(JWGlassPalette.foreground(for: .amber)))
            } else {
                Text("目标 \(effBand) 档")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
            }
        } else if let st = runtime.liveStatuses[wpid], st.band >= 0 {
            let badge = st.displayBadge(targetBand: effBand, maxMB: config.maxMemoryMB)
            let overMem = (badge == "OVER_MEM")
            let isDetached = runtime.detachedSiteIds.contains(site.id)
            let summaryText: String = {
                if overMem {
                    return "\(st.band)档(超限) · \(st.footprintMB) MB"
                }
                if st.band >= 100 {
                    return "前台(目标\(effBand)) · \(st.footprintMB) MB"
                }
                if st.band >= effBand {
                    return "\(st.band)档(\(isDetached ? "离屏" : "保活")) · \(st.footprintMB) MB"
                }
                return "\(st.band)/\(effBand)档 · \(st.footprintMB) MB"
            }()
            let statusColor: Color = overMem
                ? Color(JWGlassPalette.foreground(for: .amber))
                : (badge == "OK" ? Color(JWGlassPalette.foreground(for: .emerald)) : .secondary)
            Text(summaryText)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(statusColor)
        } else {
            Text("PID \(wpid)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    private func bandRole(for effBand: Int) -> JWGlassPalette.SemanticRole {
        if effBand >= 86 { return .amber }
        if effBand >= 75 { return .cobalt }
        return .neutral
    }

    private var sitesSection: some View {
        Section(
            header: Text("常驻 WebApp、专属档位与多账号 (\(config.sites.count)/\(JWConstants.maxSites))"),
            footer: Text("点击站点可单独设置保活档位（30~92 区分主次）、切换独立账号空间或休眠释放内存。")
        ) {
            if config.sites.isEmpty {
                Button {
                    showingAddSheet = true
                } label: {
                    HStack {
                        Spacer()
                        Label("点击添加第一个常驻 WebApp", systemImage: "plus.circle.fill")
                        Spacer()
                    }
                }
            } else {
                ForEach(config.sites) { site in
                    let effBand = config.effectiveSiteBand(for: site)
                    HStack(spacing: 11) {
                        NavigationLink(
                            destination: SiteDetailView(
                                siteId: site.id,
                                config: config,
                                runtime: runtime
                            )
                        ) {
                            HStack(spacing: 11) {
                                siteSquircleBadge(
                                    title: site.title,
                                    size: 36,
                                    fontSize: 15,
                                    dimmed: !site.enabled || site.hibernated
                                )

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(site.title)
                                        .font(.system(size: 15.5, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Text(site.urlString)
                                        .font(.system(size: 11.5))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)

                                    HStack(spacing: 5) {
                                        miniTagPill(
                                            symbol: "bolt.shield.fill",
                                            text: JWPriorityHelper.shortBadge(customBand: site.customBand, globalBand: config.targetBand),
                                            role: bandRole(for: effBand)
                                        )

                                        miniTagPill(
                                            symbol: site.isIsolatedStore ? "lock.fill" : "person.2.fill",
                                            text: site.isIsolatedStore ? "独立空间" : "共享",
                                            role: site.isIsolatedStore ? .teal : .neutral
                                        )

                                        if site.enabled && site.hibernated {
                                            miniTagPill(symbol: "moon.zzz.fill", text: "已休眠", role: .indigo)
                                        } else if site.enabled && runtime.detachedSiteIds.contains(site.id) {
                                            miniTagPill(symbol: "sparkles", text: "离屏省显存", role: .teal)
                                        } else if config.notificationsEnabled && site.notifyEnabled && site.enabled {
                                            miniTagPill(symbol: "bell.fill", text: "通知", role: .cobalt)
                                        }

                                        if site.enabled && site.autoHibernateExempt {
                                            miniTagPill(symbol: "pin.fill", text: "免休眠", role: .amber)
                                        }

                                        let siteLDM = JWLockdownHelper.normalizeSite(site.lockdownMode)
                                        if siteLDM == JWConstants.siteLockdownExempt {
                                            miniTagPill(symbol: "bolt.fill", text: "豁免锁定", role: .emerald)
                                        } else if siteLDM == JWConstants.siteLockdownEnforce {
                                            miniTagPill(symbol: "exclamationmark.shield.fill", text: "锁定隔离", role: .amber)
                                        }
                                    }
                                }
                            }
                        }

                        Toggle("", isOn: Binding(
                            get: {
                                config.sites.first(where: { $0.id == site.id })?.enabled ?? false
                            },
                            set: { newVal in
                                if let i = config.sites.firstIndex(where: { $0.id == site.id }) {
                                    config.sites[i].enabled = newVal
                                    if newVal {
                                        config.sites[i].hibernated = false
                                    }
                                    config.save()
                                    runtime.onSyncStructure?(nil)
                                }
                            }
                        ))
                        .labelsHidden()
                    }
                    .padding(.vertical, 2)
                }
                .onMove { source, destination in
                    config.sites.move(fromOffsets: source, toOffset: destination)
                    config.save()
                    runtime.onSyncStructure?(nil)
                }
                .onDelete { offsets in
                    config.sites.remove(atOffsets: offsets)
                    config.save()
                    runtime.onSyncStructure?(nil)
                }
            }
        }
    }

    private func miniTagPill(symbol: String, text: String, role: JWGlassPalette.SemanticRole) -> some View {
        HStack(spacing: 2.5) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Color(JWGlassPalette.chipFill(for: role)))
        .foregroundColor(Color(JWGlassPalette.foreground(for: role)))
        .clipShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
    }

    private var lockdownSection: some View {
        let globalLocked = config.effectiveGlobalLockdownEnabled(
            systemLockdownEnabled: runtime.systemLockdownEnabled,
            bypassIgnored: runtime.lockdownBypassDetected
        )
        return Section(
            header: Text("锁定模式豁免与 LockdownBypass 联动"),
            footer: Text("自动修复 no-sandbox 下 WebKit 无法识别容器白名单的问题，实时监听 LockdownBypass 开关通知热切换，无需杀后台。信任的常驻站点豁免后完整启用 JIT、WebAssembly、WebGL 与自定义图标字体；也可在单站点设置中单独对高危外站强制开启锁定隔离。")
        ) {
            HStack(spacing: 8) {
                Image(systemName: globalLocked ? "exclamationmark.shield.fill" : "bolt.shield.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(JWGlassPalette.foreground(for: globalLocked ? .amber : .emerald)))
                Text("当前默认引擎")
                Spacer()
                Text(globalLocked ? "锁定防护中（禁 JIT/Wasm）" : "已豁免（JIT / Wasm / 图标满血）")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Color(JWGlassPalette.foreground(for: globalLocked ? .amber : .emerald)))
            }

            HStack {
                Text("系统锁定模式 / 白名单")
                    .font(.subheadline)
                Spacer()
                let sysText = runtime.systemLockdownEnabled ? "系统已开启" : "系统未开启"
                let bypassText = runtime.lockdownBypassDetected ? "白名单已命中 ✓" : "白名单未开"
                Text("\(sysText) · \(bypassText)")
                    .font(.footnote.weight(.medium))
                    .foregroundColor(runtime.lockdownBypassDetected ? Color(JWGlassPalette.foreground(for: .teal)) : .secondary)
            }

            Picker("锁定模式全局策略", selection: Binding(
                get: { JWLockdownHelper.normalizeGlobal(config.lockdownPolicy) },
                set: { newMode in
                    config.lockdownPolicy = JWLockdownHelper.normalizeGlobal(newMode)
                    config.save()
                    runtime.onLockdownPolicyChanged?()
                }
            )) {
                Text("自动联动 LockdownBypass 白名单").tag(JWConstants.lockdownAuto)
                Text("⚡️ 始终豁免（满血运行）").tag(JWConstants.lockdownExempt)
                Text("🔒 强制开启锁定模式").tag(JWConstants.lockdownEnforce)
            }
        }
    }

    private var memoryManagementSection: some View {
        Section(
            header: Text("主动内存释放、自动休眠与防杀自救"),
            footer: Text("三级阶梯省内存：① 闲置 45 秒移出窗口树释放合成显存（切回 0ms 不重载）；② 超水位或退后台前自动「无损内存脱水」清理位图与脏页；③ 闲置超 10~60 分钟自动休眠清零至 0 MB（自动豁免流式输出中、未读新消息及「📌 免自动休眠」白名单标签，唤醒后精准恢复原对话页）。")
        ) {
            Button {
                runtime.onTrimMemoryNow?()
            } label: {
                HStack {
                    Label(
                        runtime.isTrimmingMemory ? "正在无损内存脱水…" : "一键无损内存瘦身（不重载）",
                        systemImage: "wand.and.stars"
                    )
                    .foregroundColor(Color(JWGlassPalette.foreground(for: .teal)))
                    Spacer()
                    if totalLiveMemoryMB > 0 {
                        Text("\(totalLiveMemoryMB) MB")
                            .font(.footnote.monospacedDigit().weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .disabled(runtime.isTrimmingMemory)

            Toggle("自动无损内存脱水（超软水位 / 退后台前）", isOn: Binding(
                get: { config.autoMemoryTrimEnabled },
                set: { newVal in
                    config.autoMemoryTrimEnabled = newVal
                    config.save()
                    runtime.onMemoryPolicyChanged?()
                }
            ))

            Picker("闲置后台标签离屏省显存", selection: Binding(
                get: { config.idleDetachSeconds },
                set: { newSec in
                    config.idleDetachSeconds = newSec
                    config.save()
                    runtime.onMemoryPolicyChanged?()
                }
            )) {
                Text("关闭（始终挂载窗口树）").tag(0)
                Text("闲置 30 秒后（激进省显存）").tag(30)
                Text("闲置 45 秒后（均衡推荐）").tag(45)
                Text("闲置 90 秒后").tag(90)
                Text("闲置 3 分钟后").tag(180)
            }

            Picker("闲置标签自动休眠（清零内存）", selection: Binding(
                get: { config.idleHibernateMinutes },
                set: { newMin in
                    config.idleHibernateMinutes = newMin
                    config.save()
                    runtime.onIdleHibernatePolicyChanged?()
                }
            )) {
                Text("关闭（一直常驻）").tag(0)
                Text("10 分钟未看自动休眠").tag(10)
                Text("20 分钟未看自动休眠").tag(20)
                Text("30 分钟（均衡推荐）").tag(30)
                Text("60 分钟未看自动休眠").tag(60)
            }

            Toggle("极端内存告警自动休眠低档次要标签", isOn: Binding(
                get: { config.autoHibernateOnCriticalMemory },
                set: { newVal in
                    config.autoHibernateOnCriticalMemory = newVal
                    config.save()
                    runtime.onMemoryPolicyChanged?()
                }
            ))
        }
    }

    private var notificationSection: some View {
        Section(
            header: Text("智能新消息通知与省电护航"),
            footer: Text("开启「智能按需护航」后，仅当你刚发出提问或 AI 正在生成回复中途切后台时才开启静音等信护航；普通浏览切走或锁屏会直接移交锁档冻结（0 耗电且网页照常驻留内存不重刷）。如有需要被动接收他人主动发信的群聊站点，可关闭按需护航改为每次退后台均监听。")
        ) {
            Toggle("开启新对话 / 回复系统通知", isOn: Binding(
                get: { config.notificationsEnabled },
                set: { newVal in
                    config.notificationsEnabled = newVal
                    config.save()
                    runtime.onNotificationPolicyChanged?()
                }
            ))

            if config.notificationsEnabled {
                Picker("退后台等信护航时长", selection: Binding(
                    get: { config.bgNotifyGuardMinutes },
                    set: { newMin in
                        config.bgNotifyGuardMinutes = newMin
                        config.save()
                        runtime.onNotificationPolicyChanged?()
                    }
                )) {
                    Text("仅前台跨标签通知（退后台即睡）").tag(0)
                    Text("5 分钟（短任务省电）").tag(5)
                    Text("15 分钟（均衡推荐）").tag(15)
                    Text("30 分钟（长任务护航）").tag(30)
                    Text("60 分钟").tag(60)
                }

                if config.bgNotifyGuardMinutes > 0 {
                    Toggle("智能按需护航（仅提问 / 回复中保活，极省电）", isOn: Binding(
                        get: { config.bgSmartNotifyOnly },
                        set: { newVal in
                            config.bgSmartNotifyOnly = newVal
                            config.save()
                            runtime.onNotificationPolicyChanged?()
                        }
                    ))

                    Toggle("收到通知后 1 分钟自动休眠省电", isOn: Binding(
                        get: { config.bgAutoSleepAfterNotify },
                        set: { newVal in
                            config.bgAutoSleepAfterNotify = newVal
                            config.save()
                            runtime.onNotificationPolicyChanged?()
                        }
                    ))
                }

                Button {
                    runtime.onSendTestNotification?()
                } label: {
                    Label("发送一条测试通知（检验系统横幅与声音）", systemImage: "bell.badge.fill")
                }
            }
        }
    }

    private var policyAndToolsSection: some View {
        Section(
            header: Text("全局默认策略与诊断"),
            footer: Text("JetWeb v\(JWBridgeVersion()) (\(JWBridgeGitCommit())) · Swift (UIKit + SwiftUI) + C Root Helper · 单标签超内存上限自动退回 30 档保护 4GB 内存")
        ) {
            Picker("全局外观模式", selection: Binding(
                get: { JWAppearanceHelper.normalizeGlobal(config.appearanceMode) },
                set: { newMode in
                    config.appearanceMode = newMode
                    config.save()
                    runtime.onUpdateAppearance?()
                }
            )) {
                Text("跟随系统").tag(JWConstants.appearanceSystem)
                Text("强制浅色").tag(JWConstants.appearanceLight)
                Text("强制深色").tag(JWConstants.appearanceDark)
            }

            NavigationLink(destination: TrustedCertsView(config: config, runtime: runtime)) {
                HStack {
                    Text("已信任的自签名证书")
                    Spacer()
                    Text(config.trustedCerts.isEmpty ? "无" : "\(config.trustedCerts.count) 个域名")
                        .foregroundColor(.secondary)
                }
            }

            Picker("全局默认保活档位", selection: Binding(
                get: { config.targetBand },
                set: { newBand in
                    config.targetBand = newBand
                    config.save()
                    runtime.onApplyProtectionNow?()
                }
            )) {
                Text("70 档").tag(70)
                Text("75 档").tag(75)
                Text("80 档（推荐）").tag(80)
                Text("85 档").tag(85)
                Text("90 档").tag(90)
            }

            Picker("单网页内存安全上限", selection: Binding(
                get: { config.maxMemoryMB },
                set: { newMax in
                    config.maxMemoryMB = newMax
                    config.save()
                    runtime.onApplyProtectionNow?()
                }
            )) {
                Text("300 MB").tag(300)
                Text("450 MB（推荐）").tag(450)
                Text("600 MB").tag(600)
                Text("800 MB").tag(800)
            }

            NavigationLink(destination: DiagnosticLogView(config: config, runtime: runtime)) {
                HStack {
                    Label("运行与诊断日志", systemImage: "doc.text.magnifyingglass")
                    Spacer()
                    Text(config.debugLoggingEnabled ? "记录中" : "已关闭")
                        .foregroundColor(config.debugLoggingEnabled ? .green : .secondary)
                }
            }

            Button {
                showingClearAllAlert = true
            } label: {
                Text("清理全部网页缓存与登录态")
                    .foregroundColor(.red)
            }
        }
    }
}

// MARK: - Add Site Sheet

struct AddSiteSheet: View {
    @ObservedObject var config: AppConfig
    @ObservedObject var runtime: HubRuntimeState
    @Environment(\.presentationMode) private var presentationMode

    @State private var title: String = ""
    @State private var urlInput: String = ""
    @State private var useIsolatedStore: Bool = true
    @State private var userTouchedStoreToggle: Bool = false
    @State private var customBand: Int = 0
    @State private var notifyEnabled: Bool = true
    @State private var autoHibernateExempt: Bool = false
    @State private var lockdownMode: String = JWConstants.siteLockdownInherit
    @State private var appearanceMode: String = JWConstants.appearanceInherit
    @State private var showingInvalidURLAlert = false

    private var duplicateHostDetected: Bool {
        config.hasExistingSite(matchingHostOf: urlInput)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("站点信息"), footer: Text("网址仅保存在手机本地 config.json，不会上传。")) {
                    TextField("名称（留空则自动使用域名）", text: $title)
                    TextField("网址（如 https://muse.ai 或内网地址）", text: $urlInput)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onChange(of: urlInput) { newVal in
                            if !userTouchedStoreToggle && config.hasExistingSite(matchingHostOf: newVal) {
                                useIsolatedStore = true
                            }
                        }
                }

                SitePriorityEditorSection(
                    customBand: $customBand,
                    globalBand: config.targetBand
                )

                Section(
                    header: Text("账号与登录态隔离"),
                    footer: Text(
                        duplicateHostDetected
                        ? "检测到列表中已有相同域名的站点：开启「独立账号空间」可登录另一个不同账号，互不串号。"
                        : "开启「独立账号空间」可为该标签分配独立持久的 Cookie 与 LocalStorage 容器；若需与其他默认标签共用 SSO 登录可关闭。"
                    )
                ) {
                    Toggle("使用独立账号空间（同站多号不串号）", isOn: Binding(
                        get: { useIsolatedStore },
                        set: { val in
                            userTouchedStoreToggle = true
                            useIsolatedStore = val
                        }
                    ))
                }

                Section(header: Text("通知、免休眠、锁定防护与外观")) {
                    Toggle("🔔 接收此站点新消息通知", isOn: $notifyEnabled)
                    Toggle("📌 免自动休眠（常驻白名单）", isOn: $autoHibernateExempt)
                    Picker("锁定模式策略", selection: $lockdownMode) {
                        Text("跟随全局").tag(JWConstants.siteLockdownInherit)
                        Text("⚡️ 信任豁免（满血运行）").tag(JWConstants.siteLockdownExempt)
                        Text("🔒 强制锁定（高危外站隔离）").tag(JWConstants.siteLockdownEnforce)
                    }
                    Picker("外观模式", selection: $appearanceMode) {
                        Text("跟随全局").tag(JWConstants.appearanceInherit)
                        Text("跟随系统").tag(JWConstants.appearanceSystem)
                        Text("强制浅色").tag(JWConstants.appearanceLight)
                        Text("强制深色").tag(JWConstants.appearanceDark)
                    }
                }
            }
            .navigationTitle("添加常驻 WebApp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        saveNewSite()
                    }
                    .font(.body.weight(.semibold))
                }
            }
            .alert(isPresented: $showingInvalidURLAlert) {
                Alert(
                    title: Text("网址无效"),
                    message: Text("请输入合法的 http:// 或 https:// 网址"),
                    dismissButton: .default(Text("好"))
                )
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func saveNewSite() {
        let normURL = JWURLHelper.normalize(urlInput)
        guard !normURL.isEmpty else {
            showingInvalidURLAlert = true
            return
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle: String
        if !cleanTitle.isEmpty {
            finalTitle = cleanTitle
        } else {
            finalTitle = URL(string: normURL)?.host ?? normURL
        }
        let dsId = useIsolatedStore ? UUID().uuidString : JWConstants.dataStoreDefault
        let item = SiteItem(
            title: finalTitle,
            urlString: normURL,
            enabled: true,
            appearanceMode: appearanceMode,
            dataStoreId: dsId,
            customBand: customBand,
            hibernated: false,
            notifyEnabled: notifyEnabled,
            autoHibernateExempt: autoHibernateExempt,
            lockdownMode: lockdownMode
        )
        config.sites.append(item)
        config.selectedSiteId = item.id
        config.save()
        JWLog("STORE", "Added site=\(item.title) isolated=\(useIsolatedStore) customBand=\(item.customBand) notify=\(notifyEnabled) exempt=\(autoHibernateExempt) lockdown=\(lockdownMode)")
        runtime.onSyncStructure?(item.id)
        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - Site Detail, Priority & Multi-Account Editor View

struct SiteDetailView: View {
    let siteId: String
    @ObservedObject var config: AppConfig
    @ObservedObject var runtime: HubRuntimeState
    @Environment(\.presentationMode) private var presentationMode

    @State private var draftTitle: String = ""
    @State private var draftURL: String = ""
    @State private var loadedInitial = false
    @State private var alertMessage: String?

    private var siteIndex: Int? {
        config.sites.firstIndex(where: { $0.id == siteId })
    }

    var body: some View {
        Form {
            if let idx = siteIndex {
                let site = config.sites[idx]

                Section(header: Text("基本配置")) {
                    TextField("站点名称", text: $draftTitle)
                    TextField("站点网址", text: $draftURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    Button("保存名称与网址修改") {
                        saveTitleAndURL(at: idx)
                    }
                }

                SitePriorityEditorSection(
                    customBand: Binding(
                        get: {
                            guard let i = siteIndex else { return 0 }
                            return config.sites[i].customBand
                        },
                        set: { newBand in
                            guard let i = siteIndex else { return }
                            config.sites[i].customBand = JWPriorityHelper.normalizeCustomBand(newBand)
                            config.save()
                        }
                    ),
                    globalBand: config.targetBand,
                    onChanged: {
                        runtime.onApplyProtectionNow?()
                    }
                )

                Section(
                    header: Text("多账号与数据空间"),
                    footer: Text("「独立账号空间」拥有专属持久 Cookie、LocalStorage 与 IndexedDB，重启手机也不会丢登录态。")
                ) {
                    HStack {
                        Text("当前空间")
                        Spacer()
                        Text(JWDataStoreHelper.shortBadge(for: site.dataStoreId))
                            .foregroundColor(site.isIsolatedStore ? .blue : .secondary)
                    }

                    if site.isIsolatedStore {
                        Button("重置为全新独立账号空间（换登另一新号）") {
                            config.sites[idx].dataStoreId = UUID().uuidString
                            config.sites[idx].hibernated = false
                            config.sites[idx].lastKnownURL = ""
                            config.save()
                            JWLog("STORE", "Rotated isolated store for site=\(site.title)")
                            runtime.onSyncStructure?(site.id)
                            alertMessage = "已为此标签分配全新独立账号空间并重新加载。"
                        }
                        Button("切回默认共享空间") {
                            config.sites[idx].dataStoreId = JWConstants.dataStoreDefault
                            config.sites[idx].hibernated = false
                            config.sites[idx].lastKnownURL = ""
                            config.save()
                            JWLog("STORE", "Switched site=\(site.title) to default store")
                            runtime.onSyncStructure?(site.id)
                            alertMessage = "已切回默认共享空间。"
                        }
                    } else {
                        Button("切换为独立账号空间（不与原账号串号）") {
                            config.sites[idx].dataStoreId = UUID().uuidString
                            config.sites[idx].hibernated = false
                            config.sites[idx].lastKnownURL = ""
                            config.save()
                            JWLog("STORE", "Switched site=\(site.title) to isolated store")
                            runtime.onSyncStructure?(site.id)
                            alertMessage = "已切换为独立账号空间，现在可直接登录另一个账号！"
                        }
                    }

                    Button {
                        cloneAsNewAccount(from: site)
                    } label: {
                        Label("一键复制为新账号分身标签", systemImage: "person.2.badge.plus")
                    }

                    Button {
                        runtime.onClearSiteData?(site.id)
                        alertMessage = "已清理该标签的登录态与站点缓存。"
                    } label: {
                        Text("退出并清理此标签登录态")
                            .foregroundColor(.red)
                    }
                }

                Section(
                    header: Text("通知、内存释放、锁定防护与外观"),
                    footer: Text("信任的常驻站点豁免后完整启用 JIT / Wasm 与图标字体；若访问不信任外站，可单独为此标签开启「🔒 强制锁定」隔离防护。")
                ) {
                    Toggle("🔔 接收此站点新消息通知", isOn: Binding(
                        get: { config.sites[idx].notifyEnabled },
                        set: { newVal in
                            config.sites[idx].notifyEnabled = newVal
                            config.save()
                            runtime.onNotificationPolicyChanged?()
                        }
                    ))

                    Toggle("📌 免自动休眠（常驻白名单）", isOn: Binding(
                        get: { config.sites[idx].autoHibernateExempt },
                        set: { newVal in
                            config.sites[idx].autoHibernateExempt = newVal
                            config.save()
                            runtime.onIdleHibernatePolicyChanged?()
                        }
                    ))

                    Picker("锁定模式策略", selection: Binding(
                        get: { JWLockdownHelper.normalizeSite(config.sites[idx].lockdownMode) },
                        set: { newMode in
                            config.sites[idx].lockdownMode = JWLockdownHelper.normalizeSite(newMode)
                            config.save()
                            runtime.onLockdownPolicyChanged?()
                        }
                    )) {
                        Text("跟随全局").tag(JWConstants.siteLockdownInherit)
                        Text("⚡️ 信任豁免（满血运行）").tag(JWConstants.siteLockdownExempt)
                        Text("🔒 强制锁定（高危外站隔离）").tag(JWConstants.siteLockdownEnforce)
                    }

                    Picker("外观模式", selection: Binding(
                        get: { JWAppearanceHelper.normalizeSite(config.sites[idx].appearanceMode) },
                        set: { newMode in
                            config.sites[idx].appearanceMode = newMode
                            config.save()
                            runtime.onUpdateAppearance?()
                        }
                    )) {
                        Text("跟随全局").tag(JWConstants.appearanceInherit)
                        Text("跟随系统").tag(JWConstants.appearanceSystem)
                        Text("强制浅色").tag(JWConstants.appearanceLight)
                        Text("强制深色").tag(JWConstants.appearanceDark)
                    }

                    if site.enabled {
                        if site.hibernated {
                            Button {
                                runtime.onSetHibernated?(site.id, false)
                                presentationMode.wrappedValue.dismiss()
                            } label: {
                                Label("⚡️ 唤醒并打开此标签", systemImage: "bolt.fill")
                            }
                        } else {
                            Button {
                                runtime.onSetHibernated?(site.id, true)
                                alertMessage = "已休眠「\(site.title)」并释放渲染内存。"
                            } label: {
                                Label("🌙 休眠此标签（释放内存，保留登录态）", systemImage: "moon.zzz.fill")
                                    .foregroundColor(.purple)
                            }
                            Button("重新加载此站点") {
                                runtime.onReloadSite?(site.id)
                                presentationMode.wrappedValue.dismiss()
                            }
                        }
                    }
                }
            } else {
                Text("该站点已被移除")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("站点、档位与账号")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !loadedInitial, let idx = siteIndex {
                draftTitle = config.sites[idx].title
                draftURL = config.sites[idx].urlString
                loadedInitial = true
            }
        }
        .alert(isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Alert(
                title: Text("提示"),
                message: Text(alertMessage ?? ""),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private func saveTitleAndURL(at idx: Int) {
        let normURL = JWURLHelper.normalize(draftURL)
        guard !normURL.isEmpty else {
            alertMessage = "请输入合法的 http:// 或 https:// 网址"
            return
        }
        let cleanTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = cleanTitle.isEmpty ? (URL(string: normURL)?.host ?? normURL) : cleanTitle
        let urlChanged = (config.sites[idx].urlString != normURL)
        config.sites[idx].title = finalTitle
        config.sites[idx].urlString = normURL
        if urlChanged {
            config.sites[idx].lastKnownURL = ""
        }
        config.save()
        runtime.onSyncStructure?(nil)
        if urlChanged {
            runtime.onReloadSite?(config.sites[idx].id)
        }
        alertMessage = "已保存修改"
    }

    private func cloneAsNewAccount(from site: SiteItem) {
        guard config.sites.count < JWConstants.maxSites else {
            alertMessage = "最多同时配置 \(JWConstants.maxSites) 个常驻站点。"
            return
        }
        let sameCount = config.sites.filter { $0.urlString == site.urlString }.count + 1
        let clone = SiteItem(
            title: "\(site.title) #\(sameCount)",
            urlString: site.urlString,
            enabled: true,
            appearanceMode: site.appearanceMode,
            dataStoreId: UUID().uuidString,
            customBand: site.customBand,
            hibernated: false,
            notifyEnabled: site.notifyEnabled,
            autoHibernateExempt: site.autoHibernateExempt,
            lockdownMode: site.lockdownMode
        )
        config.sites.append(clone)
        config.selectedSiteId = clone.id
        config.save()
        JWLog("STORE", "Cloned isolated site=\(clone.title) from settings")
        runtime.onSyncStructure?(clone.id)
        alertMessage = "已创建独立分身「\(clone.title)」，互不共用登录态！"
    }
}

// MARK: - Trusted Self-Signed Certificates View

struct TrustedCertsView: View {
    @ObservedObject var config: AppConfig
    @ObservedObject var runtime: HubRuntimeState

    private var sortedHosts: [String] {
        config.trustedCerts.keys.sorted()
    }

    var body: some View {
        List {
            if sortedHosts.isEmpty {
                Section {
                    Text("暂无已信任的自签名证书。访问使用自签名证书的内网 HTTPS 站点时，会在弹窗中询问是否按域名永久信任。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 6)
                }
            } else {
                Section(header: Text("已信任域名（左滑或点击可撤销）")) {
                    ForEach(sortedHosts, id: \.self) { host in
                        let fp = config.trustedCerts[host] ?? ""
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(host)
                                    .font(.body.weight(.medium))
                                Text("SHA-256: \(JWURLHelper.shortFingerprint(fp))")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("撤销") {
                                revokeHost(host)
                            }
                            .foregroundColor(.red)
                            .font(.subheadline)
                        }
                    }
                    .onDelete { offsets in
                        let hosts = sortedHosts
                        for i in offsets where i < hosts.count {
                            config.trustedCerts.removeValue(forKey: hosts[i])
                        }
                        config.save()
                        runtime.onUpdateTrustedCerts?()
                    }
                }

                Section {
                    Button("清除全部已信任证书") {
                        config.trustedCerts.removeAll()
                        config.save()
                        runtime.onUpdateTrustedCerts?()
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("已信任自签名证书")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func revokeHost(_ host: String) {
        config.trustedCerts.removeValue(forKey: host)
        config.save()
        runtime.onUpdateTrustedCerts?()
    }
}

// MARK: - Diagnostic Log Viewer (SwiftUI)

enum LogFilterCategory: String, CaseIterable, Identifiable {
    case all = "全部"
    case jetsam = "保活后台"
    case web = "网页与报错"
    case auth = "认证与空间"

    var id: String { rawValue }

    func matches(line: String) -> Bool {
        switch self {
        case .all:
            return true
        case .jetsam:
            return line.contains("[JETSAM]") || line.contains("[LOCKDOWN]") || line.contains("[MEM-TRIM]") || line.contains("[HIBERNATE]") || line.contains("[NOTIFY]") || line.contains("[BG]") || line.contains("[BG-GUARD]") || line.contains("[FG]") || line.contains("[MEM-WARN]") || line.contains("[BOOT]")
        case .web:
            return line.contains("[WEBKIT]") || line.contains("[LOCKDOWN]") || line.contains("[NAV]") || line.contains("[NAV-FAIL]") || line.contains("[TERM]") || line.contains("[JS-ERR]")
        case .auth:
            return line.contains("[AUTH]") || line.contains("[STORE]") || line.contains("[DATA]")
        }
    }
}

struct DiagnosticLogView: View {
    @ObservedObject var config: AppConfig
    @ObservedObject var runtime: HubRuntimeState

    @State private var rawLogText: String = ""
    @State private var filter: LogFilterCategory = .all
    @State private var copiedFeedback: Bool = false

    private var filteredLines: [String] {
        let lines = rawLogText.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.filter { filter.matches(line: $0) }
    }

    private var headerText: String {
        runtime.buildDiagnosticHeader?() ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Toggle("记录运行与调试日志", isOn: Binding(
                        get: { config.debugLoggingEnabled },
                        set: { enabled in
                            config.debugLoggingEnabled = enabled
                            config.save()
                            JWLogger.shared.setEnabled(enabled)
                            if enabled {
                                JWLog("LOG", "Debug logging enabled by user")
                                reloadLogs()
                            }
                        }
                    ))
                    .font(.subheadline.weight(.medium))
                }

                Picker("日志筛选", selection: $filter) {
                    ForEach(LogFilterCategory.allCases) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())

                HStack(spacing: 10) {
                    Button {
                        copyFullReport()
                    } label: {
                        Label(copiedFeedback ? "已复制诊断报告" : "复制诊断报告", systemImage: copiedFeedback ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Color.blue.opacity(0.14))
                            .foregroundColor(.blue)
                            .cornerRadius(8)
                    }

                    Button {
                        shareFullReport()
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(UIColor.tertiarySystemFill))
                            .foregroundColor(.primary)
                            .cornerRadius(8)
                    }

                    Button {
                        runtime.onRefreshLiveStatus?()
                        reloadLogs()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                            .padding(8)
                            .background(Color(UIColor.tertiarySystemFill))
                            .foregroundColor(.primary)
                            .cornerRadius(8)
                    }

                    Button {
                        JWLogger.shared.clearLogs {
                            reloadLogs()
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.footnote.weight(.semibold))
                            .padding(8)
                            .background(Color.red.opacity(0.12))
                            .foregroundColor(.red)
                            .cornerRadius(8)
                    }
                }
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemGroupedBackground))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !headerText.isEmpty {
                            Text(headerText)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(8)
                        }

                        if filteredLines.isEmpty {
                            Text("暂无匹配日志（退后台、切标签、证书校验、进程回收或报错均会自动记录在此）")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .padding(.vertical, 24)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            ForEach(Array(filteredLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                                    .foregroundColor(colorForLogLine(line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                        Color.clear.frame(height: 1).id("LOG_BOTTOM")
                    }
                    .padding(12)
                }
                .onChange(of: rawLogText) { _ in
                    proxy.scrollTo("LOG_BOTTOM", anchor: .bottom)
                }
            }
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle("运行与诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            runtime.onRefreshLiveStatus?()
            reloadLogs()
        }
    }

    private func colorForLogLine(_ line: String) -> Color {
        if line.contains("[TERM]") || line.contains("[NAV-FAIL]") || line.contains("[MEM-WARN]") || line.contains("ERR") || line.contains("GONE") {
            return .red
        }
        if line.contains("OVER") || line.contains("[JS-ERR]") {
            return .orange
        }
        if line.contains("[LOCKDOWN]") {
            return Color(JWGlassPalette.foreground(for: .cobalt))
        }
        if line.contains("[MEM-TRIM]") || line.contains("[HIBERNATE]") {
            return Color(JWGlassPalette.foreground(for: .teal))
        }
        if line.contains("[BG-GUARD]") || line.contains("[JETSAM]") {
            return .green
        }
        return .primary
    }

    private func reloadLogs() {
        JWLogger.shared.readCombinedLogs { text in
            self.rawLogText = text
        }
    }

    private func buildFullReportString() -> String {
        let bodyText = filteredLines.joined(separator: "\n")
        return headerText + "\n" + bodyText + "\n"
    }

    private func copyFullReport() {
        UIPasteboard.general.string = buildFullReportString()
        copiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            copiedFeedback = false
        }
    }

    private func shareFullReport() {
        let report = buildFullReportString()
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jetweb-diag.log")
        try? report.data(using: .utf8)?.write(to: tempURL, options: [.atomic])
        let items: [Any] = FileManager.default.fileExists(atPath: tempURL.path) ? [tempURL] : [report]
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let allWindows = scenes.flatMap { $0.windows }
        if let win = allWindows.first(where: { $0.isKeyWindow }) ?? allWindows.first,
           let root = win.rootViewController {
            presentFromTop(root: root, controller: av)
        }
    }

    private func presentFromTop(root: UIViewController, controller: UIViewController) {
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        if let pop = controller.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}

struct StandaloneDiagnosticLogSheet: View {
    @ObservedObject var config: AppConfig
    @ObservedObject var runtime: HubRuntimeState
    var onClose: () -> Void

    var body: some View {
        NavigationView {
            DiagnosticLogView(config: config, runtime: runtime)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("关闭") {
                            onClose()
                        }
                        .font(.body.weight(.semibold))
                    }
                }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
