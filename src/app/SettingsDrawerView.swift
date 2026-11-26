import SwiftUI
import UIKit

final class HubRuntimeState: ObservableObject {
    @Published var liveStatuses: [Int32: ProcStatus] = [:]
    @Published var webPIDsBySiteId: [String: Int32] = [:]
    @Published var terminatedSiteIds: Set<String> = []
    @Published var helperBannerText: String = ""

    var onSyncStructure: ((String?) -> Void)?
    var onUpdateAppearance: (() -> Void)?
    var onUpdateTrustedCerts: (() -> Void)?
    var onApplyProtectionNow: (() -> Void)?
    var onRefreshLiveStatus: (() -> Void)?
    var onReloadSite: ((String) -> Void)?
    var onClearSiteData: ((String) -> Void)?
    var onClearAllWebsiteData: (() -> Void)?
    var buildDiagnosticHeader: (() -> String)?
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

    var body: some View {
        NavigationView {
            List {
                liveProcessSection
                sitesSection
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
                        Image(systemName: "plus")
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

    private var liveProcessSection: some View {
        Section(
            header: Text("实时进程与保活档位"),
            footer: Text(
                runtime.helperBannerText.isEmpty
                ? "切标签或退后台时，JetWeb 会以断言级优先级将主进程与各标签 WebContent 锁入目标档位并抬高非活跃内存上限，防白屏重刷。"
                : runtime.helperBannerText
            )
        ) {
            HStack {
                Text("JetWeb 主进程 (PID \(hostPid))")
                    .font(.subheadline)
                Spacer()
                if let st = runtime.liveStatuses[hostPid], st.band >= 0 {
                    let note = st.band >= 100 ? " (前台)" : (st.band >= config.targetBand ? " (已保活)" : "")
                    Text("档位 \(st.band)\(note) · \(st.footprintMB) MB")
                        .font(.footnote.monospacedDigit())
                        .foregroundColor((st.band >= config.targetBand || st.band >= 100) ? .green : .secondary)
                } else {
                    Text("读取中 / 需 TrollStore 安装")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            ForEach(config.sites) { site in
                HStack {
                    Text("\(site.title) · 渲染进程")
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer()
                    siteStatusView(for: site)
                }
            }

            Button {
                runtime.onApplyProtectionNow?()
            } label: {
                HStack {
                    Spacer()
                    Label("立即刷新并重设保活档位", systemImage: "bolt.shield")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func siteStatusView(for site: SiteItem) -> some View {
        let wpid = runtime.webPIDsBySiteId[site.id] ?? 0
        if !site.enabled {
            Text("已暂停")
                .font(.footnote)
                .foregroundColor(Color(UIColor.tertiaryLabel))
        } else if wpid <= 0 {
            if runtime.terminatedSiteIds.contains(site.id) {
                Text("已被回收（切回自动恢复）")
                    .font(.footnote)
                    .foregroundColor(.orange)
            } else {
                Text("待加载")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } else if let st = runtime.liveStatuses[wpid], st.band >= 0 {
            let badge = st.displayBadge(targetBand: config.targetBand, maxMB: config.maxMemoryMB)
            let overMem = (badge == "OVER_MEM")
            let note: String = {
                if overMem { return " (超内存限额)" }
                if st.band >= 100 { return " (前台)" }
                if st.band >= config.targetBand { return " (已保活)" }
                return ""
            }()
            Text("PID \(wpid) · 档位 \(st.band)\(note) · \(st.footprintMB) MB")
                .font(.footnote.monospacedDigit())
                .foregroundColor(overMem ? .orange : (badge == "OK" ? .green : .secondary))
        } else {
            Text("PID \(wpid)")
                .font(.footnote.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    private var sitesSection: some View {
        Section(
            header: Text("常驻 WebApp 与多账号空间 (\(config.sites.count)/\(JWConstants.maxSites))"),
            footer: Text("点击站点可修改网址、切换「独立账号空间」（同网站登录多个账号互不串号）或一键复制新账号分身。")
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
                    HStack(spacing: 10) {
                        NavigationLink(
                            destination: SiteDetailView(
                                siteId: site.id,
                                config: config,
                                runtime: runtime
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(site.title)
                                    .font(.body.weight(.medium))
                                    .foregroundColor(.primary)
                                Text(site.urlString)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(site.isIsolatedStore ? "独立账号" : "默认共享")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            (site.isIsolatedStore ? Color.blue : Color.secondary)
                                                .opacity(0.15)
                                        )
                                        .foregroundColor(site.isIsolatedStore ? .blue : .secondary)
                                        .cornerRadius(4)

                                    let mode = JWAppearanceHelper.normalizeSite(site.appearanceMode)
                                    if mode != JWConstants.appearanceInherit {
                                        Text(JWAppearanceHelper.label(for: mode))
                                            .font(.system(size: 10.5, weight: .medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.purple.opacity(0.14))
                                            .foregroundColor(site.isIsolatedStore ? .purple : .purple)
                                            .cornerRadius(4)
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
                                    config.save()
                                    runtime.onSyncStructure?(nil)
                                }
                            }
                        ))
                        .labelsHidden()
                    }
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

    private var policyAndToolsSection: some View {
        Section(
            header: Text("外观、证书、保活与诊断"),
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

            Picker("后台保活目标档位", selection: Binding(
                get: { config.targetBand },
                set: { newBand in
                    config.targetBand = newBand
                    config.save()
                    runtime.onApplyProtectionNow?()
                }
            )) {
                Text("75 档").tag(75)
                Text("80 档").tag(80)
                Text("85 档（推荐）").tag(85)
                Text("90 档").tag(90)
                Text("95 档").tag(95)
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

                Section(header: Text("单站点外观模式")) {
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
            dataStoreId: dsId
        )
        config.sites.append(item)
        config.selectedSiteId = item.id
        config.save()
        JWLog("STORE", "Added site=\(item.title) isolated=\(useIsolatedStore)")
        runtime.onSyncStructure?(item.id)
        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - Site Detail & Multi-Account Editor View

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

                Section(
                    header: Text("多账号与数据空间"),
                    footer: Text("「独立账号空间」拥有专属持久 Cookie、LocalStorage 与 IndexedDB，重启手机也不会丢登录态。若此前添加的同网站标签共用了旧账号，点击下方切换为独立空间即可登录新账号。")
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
                            config.save()
                            JWLog("STORE", "Rotated isolated store for site=\(site.title)")
                            runtime.onSyncStructure?(site.id)
                            alertMessage = "已为此标签分配全新独立账号空间并重新加载。"
                        }
                        Button("切回默认共享空间") {
                            config.sites[idx].dataStoreId = JWConstants.dataStoreDefault
                            config.save()
                            JWLog("STORE", "Switched site=\(site.title) to default store")
                            runtime.onSyncStructure?(site.id)
                            alertMessage = "已切回默认共享空间。"
                        }
                    } else {
                        Button("切换为独立账号空间（不与原账号串号）") {
                            config.sites[idx].dataStoreId = UUID().uuidString
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
                    header: Text("显示与操作"),
                    footer: Text("遇到深色模式下输入框白底白字时，可单独设为「强制浅色」。")
                ) {
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
                        Button("重新加载此站点") {
                            runtime.onReloadSite?(site.id)
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                }
            } else {
                Text("该站点已被移除")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("站点与账号设置")
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
            dataStoreId: UUID().uuidString
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
            return line.contains("[JETSAM]") || line.contains("[BG]") || line.contains("[BG-GUARD]") || line.contains("[FG]") || line.contains("[MEM-WARN]") || line.contains("[BOOT]")
        case .web:
            return line.contains("[WEBKIT]") || line.contains("[NAV]") || line.contains("[NAV-FAIL]") || line.contains("[TERM]") || line.contains("[JS-ERR]")
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
