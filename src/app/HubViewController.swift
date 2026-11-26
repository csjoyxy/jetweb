import UIKit
import SwiftUI
import WebKit
import Security

// MARK: - Thread-Safe One-Shot WebKit Completion Guards

final class AuthChallengeGuard {
    private let lock = NSLock()
    private var handler: ((URLSession.AuthChallengeDisposition, URLCredential?) -> Void)?

    init(_ handler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.handler = handler
    }

    func invoke(_ disposition: URLSession.AuthChallengeDisposition, credential: URLCredential? = nil) {
        var block: ((URLSession.AuthChallengeDisposition, URLCredential?) -> Void)?
        lock.lock()
        block = handler
        handler = nil
        lock.unlock()
        block?(disposition, credential)
    }

    deinit {
        invoke(.cancelAuthenticationChallenge, credential: nil)
    }
}

final class JSAlertGuard {
    private var handler: (() -> Void)?
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func invoke() {
        let b = handler
        handler = nil
        b?()
    }
    deinit { invoke() }
}

final class JSConfirmGuard {
    private var handler: ((Bool) -> Void)?
    init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
    func invoke(_ result: Bool) {
        let b = handler
        handler = nil
        b?(result)
    }
    deinit { invoke(false) }
}

final class JSPromptGuard {
    private var handler: ((String?) -> Void)?
    init(_ handler: @escaping (String?) -> Void) { self.handler = handler }
    func invoke(_ text: String?) {
        let b = handler
        handler = nil
        b?(text)
    }
    deinit { invoke(nil) }
}

private final class PendingTrustItem {
    let serverTrust: SecTrust
    let guardObj: AuthChallengeGuard
    weak var webView: WKWebView?

    init(serverTrust: SecTrust, guardObj: AuthChallengeGuard, webView: WKWebView?) {
        self.serverTrust = serverTrust
        self.guardObj = guardObj
        self.webView = webView
    }

    func resolve(accept: Bool) {
        if accept {
            let cred = JWBridgeCredentialForAcceptedTrust(serverTrust)
            guardObj.invoke(.useCredential, credential: cred)
        } else {
            guardObj.invoke(.cancelAuthenticationChallenge, credential: nil)
        }
    }
}

private final class PendingBasicAuthItem {
    let guardObj: AuthChallengeGuard
    weak var webView: WKWebView?

    init(guardObj: AuthChallengeGuard, webView: WKWebView?) {
        self.guardObj = guardObj
        self.webView = webView
    }

    func resolve(credential: URLCredential?) {
        if let cred = credential {
            guardObj.invoke(.useCredential, credential: cred)
        } else {
            guardObj.invoke(.cancelAuthenticationChallenge, credential: nil)
        }
    }
}

// MARK: - Bottom Dock Tab Pill Control

final class SitePillControl: UIControl {
    var siteId: String = ""
    var onLongPress: ((SitePillControl) -> Void)?
    private let dotView = UIView()
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 15
        layer.cornerCurve = .continuous

        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.layer.cornerRadius = 3.5
        dotView.isUserInteractionEnabled = false
        addSubview(dotView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isUserInteractionEnabled = false
        addSubview(titleLabel)

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = 0.42
        addGestureRecognizer(lp)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(lessThanOrEqualToConstant: 176),
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 7),
            dotView.heightAnchor.constraint(equalToConstant: 7),
            titleLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        if gr.state == .began {
            onLongPress?(self)
        }
    }

    func configure(title: String, active: Bool, aliveState: String, isolated: Bool, hibernated: Bool = false, customBand: Int = 0) {
        let baseTitle = title.isEmpty ? "网页" : title
        var display = hibernated ? "🌙 \(baseTitle)" : baseTitle
        if isolated {
            display += " · 独"
        }
        if customBand > 0 {
            display += " · \(customBand)"
        }
        titleLabel.text = display
        alpha = hibernated ? (active ? 0.92 : 0.65) : 1.0

        if active {
            backgroundColor = hibernated ? .systemIndigo : .systemBlue
            titleLabel.textColor = .white
        } else {
            backgroundColor = UIColor.secondarySystemFill.withAlphaComponent(0.85)
            titleLabel.textColor = hibernated ? .secondaryLabel : .label
        }

        if hibernated {
            dotView.backgroundColor = active
                ? UIColor(red: 0.85, green: 0.78, blue: 1.0, alpha: 1.0)
                : .systemIndigo
        } else if aliveState == "OK" || aliveState == "FG" {
            dotView.backgroundColor = active
                ? UIColor(red: 0.35, green: 1.0, blue: 0.55, alpha: 1.0)
                : .systemGreen
        } else if aliveState == "OVER_MEM" {
            dotView.backgroundColor = .systemOrange
        } else {
            dotView.backgroundColor = active
                ? UIColor(white: 1.0, alpha: 0.65)
                : .tertiaryLabel
        }
    }
}

// MARK: - Main Multi-WebView Hub View Controller (UIKit)

final class HubViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private let config = AppConfig.load()
    private let runtime = HubRuntimeState()

    private var webViews: [String: WKWebView] = [:]
    private var webViewStoreIds: [String: String] = [:]
    private var customDataStores: [String: WKWebsiteDataStore] = [:]
    private var knownIsolatedStoreIds: Set<String> = []
    private var errorOverlays: [String: ErrorOverlayView] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]
    private var urlObservations: [String: NSKeyValueObservation] = [:]
    private var lastKnownURLBySiteId: [String: String] = [:]

    private var terminatedSiteIds: Set<String> = [] {
        didSet { runtime.terminatedSiteIds = terminatedSiteIds }
    }
    private var lastProcStatuses: [Int32: ProcStatus] = [:] {
        didSet { runtime.liveStatuses = lastProcStatuses }
    }
    private var lastLoggedApplyDigest: String = ""

    private let protectQueue = DispatchQueue(label: "com.lili.jetweb.protect")
    private let trustEvalQueue = DispatchQueue(label: "com.lili.jetweb.trust")
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var bgEpoch: UInt = 1
    private var fgProtectTimer: Timer?
    private var tabSwitchSeq: UInt = 0

    private var sessionTrustedCerts: [String: String] = [:]
    private var sessionBasicAuth: [String: URLCredential] = [:]
    private var pendingTrustQueues: [String: [PendingTrustItem]] = [:]
    private var pendingBasicAuthQueues: [String: [PendingBasicAuthItem]] = [:]
    private var authPromptQueue: [() -> Void] = []
    private var isPresentingAuthAlert: Bool = false
    private var lastRejectedAuthBySiteId: [String: (title: String, detail: String)] = [:]

    private let webContainerView = UIView()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let emptyStateView = UIView()
    private let hibernatedStateView = UIView()
    private let hibernatedTitleLabel = UILabel()
    private let hibernatedSubLabel = UILabel()

    private var dockBar: UIVisualEffectView!
    private let tabsScrollView = UIScrollView()
    private let tabsStackView = UIStackView()
    private var webBottomToDockConstraint: NSLayoutConstraint!
    private var webBottomToViewConstraint: NSLayoutConstraint!

    private var floatingPill: UIVisualEffectView!
    private let floatingLabel = UILabel()
    private var floatingTrailingConstraint: NSLayoutConstraint!
    private var floatingBottomConstraint: NSLayoutConstraint!

    deinit {
        fgProtectTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        for sid in Array(webViews.keys) {
            teardownWebView(forSiteId: sid)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        JWLogger.shared.setEnabled(config.debugLoggingEnabled)
        let ramMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        JWLog("BOOT", "JetWeb v\(JWBridgeVersion()) (\(JWBridgeGitCommit())) Swift launched | iOS \(UIDevice.current.systemVersion) | RAM=\(ramMB)MB | hostPID=\(getpid()) | sites=\(config.sites.count)")

        writeBgEpochToken(bgEpoch)
        bindRuntimeCallbacks()

        protectQueue.async {
            var code: Int32 = -1
            _ = JWBridgeRunJetWebCtl(["--probe"], &code)
            JWLog("BOOT", "jetwebctl --probe exitCode=\(code)")
        }

        setupLayout()
        syncWebViewsWithConfig(preferredSelectId: nil)
        applyAppearanceStyles()
        applyDockCollapsedState(animated: false)
        startForegroundProtectTimer()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidReceiveMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if let prev = previousTraitCollection,
           traitCollection.hasDifferentColorAppearance(comparedTo: prev) {
            applyAppearanceStyles()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        clampFloatingPillPosition()
    }

    private func bindRuntimeCallbacks() {
        runtime.onSyncStructure = { [weak self] selectId in
            guard let self = self else { return }
            if let selectId = selectId, !selectId.isEmpty {
                self.config.selectedSiteId = selectId
                self.config.save()
            }
            self.syncWebViewsWithConfig(preferredSelectId: selectId)
            self.applyDockCollapsedState(animated: false)
        }
        runtime.onSetHibernated = { [weak self] siteId, hibernated in
            self?.setSiteHibernated(siteId: siteId, hibernated: hibernated)
        }
        runtime.onUpdateAppearance = { [weak self] in
            self?.applyAppearanceStyles()
            self?.rebuildTabPills()
        }
        runtime.onUpdateTrustedCerts = { [weak self] in
            guard let self = self else { return }
            for host in Array(self.sessionTrustedCerts.keys) {
                if self.config.trustedCerts[host] == nil {
                    self.sessionTrustedCerts.removeValue(forKey: host)
                }
            }
        }
        runtime.onApplyProtectionNow = { [weak self] in
            guard let self = self else { return }
            self.scheduleApplyProtectionAsync { [weak self] summary in
                self?.runtime.helperBannerText = summary
                self?.queryLiveStatusesAsync()
            }
        }
        runtime.onRefreshLiveStatus = { [weak self] in
            self?.queryLiveStatusesAsync()
        }
        runtime.onReloadSite = { [weak self] siteId in
            self?.reloadSiteFromHomeOrCurrent(siteId: siteId, forceHome: true)
        }
        runtime.onClearSiteData = { [weak self] siteId in
            self?.clearDataForSite(siteId: siteId)
        }
        runtime.onClearAllWebsiteData = { [weak self] in
            self?.clearAllWebsiteData()
        }
        runtime.buildDiagnosticHeader = { [weak self] in
            self?.buildDiagnosticHeaderText() ?? ""
        }
    }

    // MARK: - UIKit Layout (Instant-Switch Web Container + Blur Dock + Floating Pill)

    private func makeIconButton(symbol: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        btn.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
        btn.tintColor = .label
        btn.addTarget(self, action: action, for: .touchUpInside)
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 36),
            btn.heightAnchor.constraint(equalToConstant: 36)
        ])
        return btn
    }

    private func setupLayout() {
        webContainerView.translatesAutoresizingMaskIntoConstraints = false
        webContainerView.backgroundColor = .systemBackground
        view.addSubview(webContainerView)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = .systemBlue
        progressView.isHidden = true
        view.addSubview(progressView)

        dockBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        dockBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dockBar)

        let topLine = UIView()
        topLine.translatesAutoresizingMaskIntoConstraints = false
        topLine.backgroundColor = .separator
        dockBar.contentView.addSubview(topLine)

        let barRow = UIView()
        barRow.translatesAutoresizingMaskIntoConstraints = false
        dockBar.contentView.addSubview(barRow)

        tabsScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabsScrollView.showsHorizontalScrollIndicator = false
        tabsScrollView.showsVerticalScrollIndicator = false
        tabsScrollView.contentInsetAdjustmentBehavior = .never
        barRow.addSubview(tabsScrollView)

        tabsStackView.translatesAutoresizingMaskIntoConstraints = false
        tabsStackView.axis = .horizontal
        tabsStackView.spacing = 8
        tabsStackView.alignment = .center
        tabsScrollView.addSubview(tabsStackView)

        let reloadBtn = makeIconButton(symbol: "arrow.clockwise", action: #selector(reloadCurrentSite))
        let settingsBtn = makeIconButton(symbol: "slider.horizontal.3", action: #selector(openManageSheet))
        let collapseBtn = makeIconButton(symbol: "arrow.down.right.and.arrow.up.left", action: #selector(collapseDockTapped))

        let rightTools = UIStackView(arrangedSubviews: [reloadBtn, settingsBtn, collapseBtn])
        rightTools.translatesAutoresizingMaskIntoConstraints = false
        rightTools.axis = .horizontal
        rightTools.spacing = 2
        rightTools.alignment = .center
        barRow.addSubview(rightTools)

        webBottomToDockConstraint = webContainerView.bottomAnchor.constraint(equalTo: dockBar.topAnchor)
        webBottomToViewConstraint = webContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        NSLayoutConstraint.activate([
            webContainerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webBottomToDockConstraint,

            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2.0),

            dockBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dockBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dockBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            topLine.topAnchor.constraint(equalTo: dockBar.contentView.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: dockBar.contentView.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: dockBar.contentView.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 0.5),

            barRow.topAnchor.constraint(equalTo: dockBar.contentView.topAnchor),
            barRow.leadingAnchor.constraint(equalTo: dockBar.contentView.leadingAnchor, constant: 10),
            barRow.trailingAnchor.constraint(equalTo: dockBar.contentView.trailingAnchor, constant: -8),
            barRow.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            barRow.heightAnchor.constraint(equalToConstant: 44),

            rightTools.trailingAnchor.constraint(equalTo: barRow.trailingAnchor),
            rightTools.centerYAnchor.constraint(equalTo: barRow.centerYAnchor),

            tabsScrollView.leadingAnchor.constraint(equalTo: barRow.leadingAnchor),
            tabsScrollView.trailingAnchor.constraint(equalTo: rightTools.leadingAnchor, constant: -6),
            tabsScrollView.topAnchor.constraint(equalTo: barRow.topAnchor),
            tabsScrollView.bottomAnchor.constraint(equalTo: barRow.bottomAnchor),

            tabsStackView.leadingAnchor.constraint(equalTo: tabsScrollView.contentLayoutGuide.leadingAnchor),
            tabsStackView.trailingAnchor.constraint(equalTo: tabsScrollView.contentLayoutGuide.trailingAnchor),
            tabsStackView.topAnchor.constraint(equalTo: tabsScrollView.contentLayoutGuide.topAnchor),
            tabsStackView.bottomAnchor.constraint(equalTo: tabsScrollView.contentLayoutGuide.bottomAnchor),
            tabsStackView.heightAnchor.constraint(equalTo: tabsScrollView.frameLayoutGuide.heightAnchor)
        ])

        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        webContainerView.addSubview(emptyStateView)

        let emptyTitle = UILabel()
        emptyTitle.translatesAutoresizingMaskIntoConstraints = false
        emptyTitle.text = "JetWeb 多合一常驻容器"
        emptyTitle.font = .systemFont(ofSize: 20, weight: .bold)
        emptyTitle.textAlignment = .center
        emptyStateView.addSubview(emptyTitle)

        let emptySub = UILabel()
        emptySub.translatesAutoresizingMaskIntoConstraints = false
        emptySub.text = "把常用的桌面级 WebApp 放进同一容器：\n秒切不白屏、同站多账号独立空间、分档保活与一键休眠"
        emptySub.font = .systemFont(ofSize: 14)
        emptySub.textColor = .secondaryLabel
        emptySub.numberOfLines = 0
        emptySub.textAlignment = .center
        emptyStateView.addSubview(emptySub)

        let addFirstBtn = UIButton(type: .system)
        addFirstBtn.translatesAutoresizingMaskIntoConstraints = false
        var btnCfg = UIButton.Configuration.filled()
        btnCfg.title = "添加第一个常驻 WebApp"
        btnCfg.cornerStyle = .capsule
        btnCfg.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 22, bottom: 11, trailing: 22)
        addFirstBtn.configuration = btnCfg
        addFirstBtn.addTarget(self, action: #selector(openManageSheet), for: .touchUpInside)
        emptyStateView.addSubview(addFirstBtn)

        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: webContainerView.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: webContainerView.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: webContainerView.leadingAnchor, constant: 28),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: webContainerView.trailingAnchor, constant: -28),

            emptyTitle.topAnchor.constraint(equalTo: emptyStateView.topAnchor),
            emptyTitle.leadingAnchor.constraint(equalTo: emptyStateView.leadingAnchor),
            emptyTitle.trailingAnchor.constraint(equalTo: emptyStateView.trailingAnchor),

            emptySub.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 10),
            emptySub.leadingAnchor.constraint(equalTo: emptyStateView.leadingAnchor),
            emptySub.trailingAnchor.constraint(equalTo: emptyStateView.trailingAnchor),

            addFirstBtn.topAnchor.constraint(equalTo: emptySub.bottomAnchor, constant: 20),
            addFirstBtn.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            addFirstBtn.bottomAnchor.constraint(equalTo: emptyStateView.bottomAnchor)
        ])

        hibernatedStateView.translatesAutoresizingMaskIntoConstraints = false
        hibernatedStateView.isHidden = true
        webContainerView.addSubview(hibernatedStateView)

        hibernatedTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        hibernatedTitleLabel.text = "🌙 标签已休眠"
        hibernatedTitleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        hibernatedTitleLabel.numberOfLines = 2
        hibernatedTitleLabel.textAlignment = .center
        hibernatedStateView.addSubview(hibernatedTitleLabel)

        hibernatedSubLabel.translatesAutoresizingMaskIntoConstraints = false
        hibernatedSubLabel.text = "已销毁该标签的网页进程并释放全部运行内存（0 MB）。\n账号 Cookie 与本地登录态完整保留，随时可一键唤醒。"
        hibernatedSubLabel.font = .systemFont(ofSize: 14)
        hibernatedSubLabel.textColor = .secondaryLabel
        hibernatedSubLabel.numberOfLines = 0
        hibernatedSubLabel.textAlignment = .center
        hibernatedStateView.addSubview(hibernatedSubLabel)

        let wakeBtn = UIButton(type: .system)
        wakeBtn.translatesAutoresizingMaskIntoConstraints = false
        var wakeCfg = UIButton.Configuration.filled()
        wakeCfg.title = "⚡️ 立即唤醒并加载网页"
        wakeCfg.baseBackgroundColor = .systemIndigo
        wakeCfg.cornerStyle = .capsule
        wakeCfg.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 24, bottom: 11, trailing: 24)
        wakeBtn.configuration = wakeCfg
        wakeBtn.addTarget(self, action: #selector(wakeSelectedSiteTapped), for: .touchUpInside)
        hibernatedStateView.addSubview(wakeBtn)

        let hibManageBtn = UIButton(type: .system)
        hibManageBtn.translatesAutoresizingMaskIntoConstraints = false
        hibManageBtn.setTitle("打开工作台设置", for: .normal)
        hibManageBtn.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        hibManageBtn.addTarget(self, action: #selector(openManageSheet), for: .touchUpInside)
        hibernatedStateView.addSubview(hibManageBtn)

        NSLayoutConstraint.activate([
            hibernatedStateView.centerXAnchor.constraint(equalTo: webContainerView.centerXAnchor),
            hibernatedStateView.centerYAnchor.constraint(equalTo: webContainerView.centerYAnchor),
            hibernatedStateView.leadingAnchor.constraint(greaterThanOrEqualTo: webContainerView.leadingAnchor, constant: 28),
            hibernatedStateView.trailingAnchor.constraint(lessThanOrEqualTo: webContainerView.trailingAnchor, constant: -28),

            hibernatedTitleLabel.topAnchor.constraint(equalTo: hibernatedStateView.topAnchor),
            hibernatedTitleLabel.leadingAnchor.constraint(equalTo: hibernatedStateView.leadingAnchor),
            hibernatedTitleLabel.trailingAnchor.constraint(equalTo: hibernatedStateView.trailingAnchor),

            hibernatedSubLabel.topAnchor.constraint(equalTo: hibernatedTitleLabel.bottomAnchor, constant: 10),
            hibernatedSubLabel.leadingAnchor.constraint(equalTo: hibernatedStateView.leadingAnchor),
            hibernatedSubLabel.trailingAnchor.constraint(equalTo: hibernatedStateView.trailingAnchor),

            wakeBtn.topAnchor.constraint(equalTo: hibernatedSubLabel.bottomAnchor, constant: 20),
            wakeBtn.centerXAnchor.constraint(equalTo: hibernatedStateView.centerXAnchor),

            hibManageBtn.topAnchor.constraint(equalTo: wakeBtn.bottomAnchor, constant: 12),
            hibManageBtn.centerXAnchor.constraint(equalTo: hibernatedStateView.centerXAnchor),
            hibManageBtn.bottomAnchor.constraint(equalTo: hibernatedStateView.bottomAnchor)
        ])

        floatingPill = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        floatingPill.translatesAutoresizingMaskIntoConstraints = false
        floatingPill.layer.cornerRadius = 17
        floatingPill.layer.cornerCurve = .continuous
        floatingPill.clipsToBounds = true
        floatingPill.layer.borderWidth = 0.5
        floatingPill.layer.borderColor = UIColor.separator.withAlphaComponent(0.5).cgColor
        floatingPill.isHidden = true
        view.addSubview(floatingPill)

        floatingLabel.translatesAutoresizingMaskIntoConstraints = false
        floatingLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        floatingLabel.textColor = .label
        floatingLabel.lineBreakMode = .byTruncatingTail
        floatingLabel.text = "◉ 展开"
        floatingPill.contentView.addSubview(floatingLabel)

        floatingTrailingConstraint = floatingPill.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14)
        floatingBottomConstraint = floatingPill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18)

        NSLayoutConstraint.activate([
            floatingTrailingConstraint,
            floatingBottomConstraint,
            floatingPill.heightAnchor.constraint(equalToConstant: 34),
            floatingPill.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            floatingLabel.leadingAnchor.constraint(equalTo: floatingPill.contentView.leadingAnchor, constant: 12),
            floatingLabel.trailingAnchor.constraint(equalTo: floatingPill.contentView.trailingAnchor, constant: -12),
            floatingLabel.centerYAnchor.constraint(equalTo: floatingPill.contentView.centerYAnchor)
        ])

        let tapExpand = UITapGestureRecognizer(target: self, action: #selector(expandDockTapped))
        floatingPill.addGestureRecognizer(tapExpand)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(floatingPillLongPressed(_:)))
        longPress.minimumPressDuration = 0.4
        floatingPill.addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(floatingPillPanned(_:)))
        floatingPill.addGestureRecognizer(pan)
    }

    private func clampFloatingPillPosition() {
        let w = view.bounds.width
        let h = view.bounds.height
        guard w > 120 && h > 160 else { return }
        let minTrailing = -(w - 100)
        let minBottom = -(h - 120)
        floatingTrailingConstraint.constant = min(-8, max(minTrailing, floatingTrailingConstraint.constant))
        floatingBottomConstraint.constant = min(-8, max(minBottom, floatingBottomConstraint.constant))
    }

    // MARK: - Appearance Styles

    private func resolvedAppearanceStyle(for site: SiteItem) -> UIUserInterfaceStyle {
        let mode = config.effectiveAppearanceMode(for: site)
        let sysStyle = view.window?.traitCollection.userInterfaceStyle ?? UIScreen.main.traitCollection.userInterfaceStyle
        let fallback: UIUserInterfaceStyle = (sysStyle == .dark) ? .dark : .light
        return JWAppearanceHelper.uiStyle(for: mode, fallback: fallback)
    }

    private func applyAppearanceStyle(to webView: WKWebView, for site: SiteItem) {
        let targetStyle = resolvedAppearanceStyle(for: site)
        let changed = (webView.overrideUserInterfaceStyle != targetStyle)
        webView.overrideUserInterfaceStyle = targetStyle
        errorOverlays[site.id]?.overrideUserInterfaceStyle = targetStyle
        if changed {
            webView.evaluateJavaScript(
                "if(window.__jwRecheckInputs)window.__jwRecheckInputs();",
                in: nil,
                in: .defaultClient,
                completionHandler: nil
            )
        }
    }

    private func applyAppearanceStyles() {
        let globalMode = JWAppearanceHelper.normalizeGlobal(config.appearanceMode)
        overrideUserInterfaceStyle = JWAppearanceHelper.uiStyle(for: globalMode, fallback: .unspecified)
        if let presented = presentedViewController {
            presented.overrideUserInterfaceStyle = JWAppearanceHelper.uiStyle(for: globalMode, fallback: .unspecified)
        }
        for site in enabledSites() {
            if let wv = webViews[site.id] {
                applyAppearanceStyle(to: wv, for: site)
            }
        }
    }

    // MARK: - Multi-Instance WebView & Isolated WKWebsiteDataStore Management

    private func enabledSites() -> [SiteItem] {
        return config.sites.filter { $0.enabled }
    }

    private func awakeSites() -> [SiteItem] {
        return config.sites.filter { $0.enabled && !$0.hibernated }
    }

    private func site(forId siteId: String) -> SiteItem? {
        return config.sites.first(where: { $0.id == siteId })
    }

    private func siteId(for webView: WKWebView?) -> String? {
        guard let webView = webView else { return nil }
        return webViews.first(where: { $0.value === webView })?.key
    }

    private func clearBasicAuth(forStoreId storeId: String) {
        let prefix = JWDataStoreHelper.normalize(storeId) + "|"
        for k in Array(sessionBasicAuth.keys) where k.hasPrefix(prefix) {
            sessionBasicAuth.removeValue(forKey: k)
        }
    }

    private func websiteDataStore(for site: SiteItem) -> WKWebsiteDataStore {
        let dsId = JWDataStoreHelper.normalize(site.dataStoreId)
        guard JWDataStoreHelper.isIsolated(dsId) else {
            return .default()
        }
        knownIsolatedStoreIds.insert(dsId)
        if let cached = customDataStores[dsId] {
            return cached
        }
        let created = JWBridgeCreateIsolatedDataStore(dsId, AppConfig.effectiveFallbackDataStoresDir())
        customDataStores[dsId] = created
        return created
    }

    private func createWebView(for site: SiteItem) -> WKWebView {
        let normStoreId = JWDataStoreHelper.normalize(site.dataStoreId)
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = websiteDataStore(for: site)
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.userContentController.addUserScript(WebScripts.compatPolyfillScript())
        cfg.userContentController.addUserScript(WebScripts.inputContrastFixScript())
        cfg.userContentController.addUserScript(WebScripts.diagnosticJSErrorScript())
        cfg.userContentController.add(WeakScriptMessageProxy(target: self), name: "jwDiag")

        let wv = WKWebView(frame: webContainerView.bounds, configuration: cfg)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4 Mobile/15E148 Safari/604.1"

        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(handlePullToRefresh(_:)), for: .valueChanged)
        wv.scrollView.refreshControl = rc

        let capturedId = site.id
        progressObservations[capturedId] = wv.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            guard let self = self, webView === self.webViews[self.config.selectedSiteId] else { return }
            let p = Float(webView.estimatedProgress)
            self.progressView.isHidden = (p >= 1.0 || p <= 0.01)
            self.progressView.setProgress(p, animated: true)
        }
        urlObservations[capturedId] = wv.observe(\.url, options: [.new]) { [weak self] webView, _ in
            guard let self = self,
                  let curURL = webView.url,
                  let scheme = curURL.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https") else { return }
            self.lastKnownURLBySiteId[capturedId] = curURL.absoluteString
        }

        webContainerView.insertSubview(wv, belowSubview: emptyStateView)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: webContainerView.topAnchor),
            wv.leadingAnchor.constraint(equalTo: webContainerView.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: webContainerView.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: webContainerView.bottomAnchor)
        ])

        let overlay = ErrorOverlayView(frame: .zero)
        overlay.onRetry = { [weak self] in
            self?.reloadSiteFromHomeOrCurrent(siteId: capturedId, forceHome: false)
        }
        overlay.onGoHome = { [weak self] in
            self?.reloadSiteFromHomeOrCurrent(siteId: capturedId, forceHome: true)
        }
        wv.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: wv.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: wv.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: wv.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: wv.bottomAnchor)
        ])
        errorOverlays[capturedId] = overlay
        webViewStoreIds[capturedId] = normStoreId

        applyAppearanceStyle(to: wv, for: site)

        let shortStore = JWDataStoreHelper.isIsolated(normStoreId) ? String(normStoreId.prefix(8)) : "default"
        let effBand = config.effectiveSiteBand(for: site)
        JWLog("WEBKIT", "Create WebView site=\(site.title) store=\(shortStore) band=\(effBand) appearance=\(site.appearanceMode)")

        let initialURLStr = lastKnownURLBySiteId[site.id] ?? site.urlString
        if let url = URL(string: initialURLStr) {
            wv.load(URLRequest(url: url))
        } else if let homeURL = URL(string: site.urlString) {
            wv.load(URLRequest(url: homeURL))
        }
        return wv
    }

    private func teardownWebView(forSiteId siteId: String) {
        guard let old = webViews[siteId] else { return }
        old.stopLoading()
        old.configuration.userContentController.removeScriptMessageHandler(forName: "jwDiag")
        progressObservations.removeValue(forKey: siteId)?.invalidate()
        urlObservations.removeValue(forKey: siteId)?.invalidate()
        old.navigationDelegate = nil
        old.uiDelegate = nil
        old.removeFromSuperview()
        webViews.removeValue(forKey: siteId)
        webViewStoreIds.removeValue(forKey: siteId)
        errorOverlays.removeValue(forKey: siteId)
        terminatedSiteIds.remove(siteId)
        lastRejectedAuthBySiteId.removeValue(forKey: siteId)
    }

    private func refreshRuntimeWebPIDMap() {
        var map: [String: Int32] = [:]
        for (sid, wv) in webViews {
            let pid = JWBridgeWebViewContentPID(wv)
            if pid > 0 {
                map[sid] = pid
            }
        }
        runtime.webPIDsBySiteId = map
    }

    private func syncWebViewsWithConfig(preferredSelectId: String?) {
        let allConfiguredIds = Set(config.sites.map { $0.id })
        for savedSid in Array(lastKnownURLBySiteId.keys) where !allConfiguredIds.contains(savedSid) {
            lastKnownURLBySiteId.removeValue(forKey: savedSid)
        }

        var referencedIsoStores = Set<String>()
        for s in config.sites {
            let dsId = JWDataStoreHelper.normalize(s.dataStoreId)
            if JWDataStoreHelper.isIsolated(dsId) {
                referencedIsoStores.insert(dsId)
                knownIsolatedStoreIds.insert(dsId)
            }
        }

        let enabled = enabledSites()
        let awake = awakeSites()
        let awakeIds = Set(awake.map { $0.id })

        for s in awake {
            let desiredStoreId = JWDataStoreHelper.normalize(s.dataStoreId)
            if let currentStoreId = webViewStoreIds[s.id], currentStoreId != desiredStoreId {
                lastKnownURLBySiteId.removeValue(forKey: s.id)
                teardownWebView(forSiteId: s.id)
            }
            if webViews[s.id] == nil {
                webViews[s.id] = createWebView(for: s)
            }
        }

        for existingId in Array(webViews.keys) where !awakeIds.contains(existingId) {
            teardownWebView(forSiteId: existingId)
        }

        for knownId in Array(knownIsolatedStoreIds) where !referencedIsoStores.contains(knownId) {
            let retiredStore = customDataStores.removeValue(forKey: knownId)
            knownIsolatedStoreIds.remove(knownId)
            clearBasicAuth(forStoreId: knownId)
            JWLog("STORE", "Purging retired isolated dataStore=\(String(knownId.prefix(8)))")
            JWBridgePurgeIsolatedDataStore(knownId, AppConfig.effectiveFallbackDataStoresDir(), retiredStore)
        }

        if enabled.isEmpty {
            config.selectedSiteId = ""
            emptyStateView.isHidden = false
            hibernatedStateView.isHidden = true
            progressView.isHidden = true
            floatingLabel.text = "◉ 展开"
        } else {
            emptyStateView.isHidden = true
            if let preferred = preferredSelectId, enabled.contains(where: { $0.id == preferred }) {
                config.selectedSiteId = preferred
                config.save()
            } else if !enabled.contains(where: { $0.id == config.selectedSiteId }),
                      let next = awake.first ?? enabled.first {
                config.selectedSiteId = next.id
                config.save()
            }
            selectSite(byId: config.selectedSiteId, triggerWaves: false)
        }

        refreshRuntimeWebPIDMap()
        applyAppearanceStyles()
        rebuildTabPills()
        schedulePostStateChangeProtectionWaves()
    }

    private func hideErrorOverlay(forSiteId siteId: String) {
        guard !siteId.isEmpty else { return }
        errorOverlays[siteId]?.isHidden = true
        lastRejectedAuthBySiteId.removeValue(forKey: siteId)
    }

    private func showErrorOverlay(for webView: WKWebView, error: NSError?, customTitle: String?, customDetail: String?) {
        guard let sid = siteId(for: webView), let overlay = errorOverlays[sid] else { return }
        let s = site(forId: sid)
        var failedURL = (error?.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
            ?? (error?.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
            ?? webView.url?.absoluteString
            ?? ""
        if failedURL.isEmpty || failedURL == "about:blank" {
            failedURL = s?.urlString ?? ""
        }
        overlay.configure(
            error: error,
            failedURL: failedURL,
            homeURL: s?.urlString ?? "",
            customTitle: customTitle,
            customDetail: customDetail
        )
        overlay.isHidden = false
        webView.bringSubviewToFront(overlay)
    }

    private func reloadSiteFromHomeOrCurrent(siteId: String, forceHome: Bool) {
        guard !siteId.isEmpty else { return }
        if forceHome {
            lastKnownURLBySiteId.removeValue(forKey: siteId)
        }
        if let cur = site(forId: siteId), cur.hibernated {
            setSiteHibernated(siteId: siteId, hibernated: false)
            return
        }
        guard let wv = webViews[siteId] else { return }
        let failedURL = errorOverlays[siteId]?.failedURLString ?? ""
        hideErrorOverlay(forSiteId: siteId)

        if !forceHome {
            let livePID = JWBridgeWebViewContentPID(wv)
            let remembered = lastKnownURLBySiteId[siteId] ?? ""
            let curStr = wv.url?.absoluteString ?? ""

            /*
             * When recovering from a terminated WebContent process (livePID <= 0) or when
             * SPA history.pushState changed the URL beyond the last full document load,
             * explicitly load `remembered` so SPA routes (e.g. /u/0/remote/<convId>) aren't
             * reset back to the root entry page by `wv.reload()`.
             */
            if !remembered.isEmpty,
               (livePID <= 0 || curStr.isEmpty || curStr == "about:blank" || curStr != remembered),
               let remURL = URL(string: remembered) {
                wv.load(URLRequest(url: remURL))
                return
            }
            if !curStr.isEmpty && curStr != "about:blank" {
                wv.reload()
                return
            }
            if !failedURL.isEmpty, let fu = URL(string: failedURL) {
                wv.load(URLRequest(url: fu))
                return
            }
        }

        if let homeStr = site(forId: siteId)?.urlString, let homeURL = URL(string: homeStr) {
            wv.load(URLRequest(url: homeURL))
        }
    }

    private func recoverWebViewIfTerminated(siteId: String) {
        guard !siteId.isEmpty, let wv = webViews[siteId] else { return }
        let hasVisibleError = !(errorOverlays[siteId]?.isHidden ?? true)
        let markedTerminated = terminatedSiteIds.contains(siteId)
        let missingProcess = (JWBridgeWebViewContentPID(wv) <= 0 && !wv.isLoading && !hasVisibleError)
        guard markedTerminated || missingProcess else { return }
        terminatedSiteIds.remove(siteId)
        JWLog("WEBKIT", "Auto-recovering siteId=\(siteId) (terminated=\(markedTerminated) missingPID=\(missingProcess))")
        reloadSiteFromHomeOrCurrent(siteId: siteId, forceHome: false)
    }

    private func selectSite(byId siteId: String, triggerWaves: Bool = true) {
        guard !siteId.isEmpty, let curSite = site(forId: siteId), curSite.enabled else { return }
        config.selectedSiteId = siteId
        config.save()

        if let targetWV = webViews[siteId], !curSite.hibernated {
            hibernatedStateView.isHidden = true
            for (sid, wv) in webViews {
                let isSel = (sid == siteId)
                wv.isHidden = !isSel
                wv.isUserInteractionEnabled = isSel
            }
            webContainerView.bringSubviewToFront(targetWV)
            let p = Float(targetWV.estimatedProgress)
            progressView.isHidden = (!targetWV.isLoading || p >= 1.0 || p <= 0.01)
            progressView.setProgress(p, animated: false)
            recoverWebViewIfTerminated(siteId: siteId)
            floatingLabel.text = "◉ \(curSite.title)"
        } else {
            for (_, wv) in webViews {
                wv.isHidden = true
                wv.isUserInteractionEnabled = false
            }
            progressView.isHidden = true
            let spaceLabel = JWDataStoreHelper.label(for: curSite.dataStoreId)
            let tierText = JWPriorityHelper.tierDescription(customBand: curSite.customBand, globalBand: config.targetBand)
            hibernatedTitleLabel.text = "🌙 \(curSite.title) 已休眠"
            hibernatedSubLabel.text = "已销毁该标签的网页进程并释放全部运行内存（0 MB）。\n登录空间（\(spaceLabel)）与保活预设（\(tierText)）完整保留。"
            hibernatedStateView.isHidden = false
            webContainerView.bringSubviewToFront(hibernatedStateView)
            floatingLabel.text = "🌙 \(curSite.title)"
        }

        if triggerWaves {
            rebuildTabPills()
            schedulePostStateChangeProtectionWaves()
        }
    }

    private func setSiteHibernated(siteId: String, hibernated: Bool) {
        guard let idx = config.sites.firstIndex(where: { $0.id == siteId }) else { return }
        let title = config.sites[idx].title

        if !hibernated {
            config.sites[idx].enabled = true
            config.sites[idx].hibernated = false
            config.selectedSiteId = siteId
            config.save()
            JWLog("HIBERNATE", "Waking site=\(title) and restoring WebView")
            syncWebViewsWithConfig(preferredSelectId: siteId)
            applyDockCollapsedState(animated: false)
            return
        }

        let prevPID = JWBridgeWebViewContentPID(webViews[siteId])
        let prevMB = (prevPID > 0) ? (lastProcStatuses[prevPID]?.footprintMB ?? 0) : 0
        config.sites[idx].hibernated = true

        var nextSelected = config.selectedSiteId
        if config.selectedSiteId == siteId {
            if let nextAwake = config.sites.first(where: { $0.enabled && !$0.hibernated }) {
                nextSelected = nextAwake.id
            } else {
                nextSelected = siteId
            }
        }
        config.selectedSiteId = nextSelected
        config.save()
        JWLog("HIBERNATE", "Hibernated site=\(title) prevPID=\(prevPID) freed~\(prevMB)MB")
        syncWebViewsWithConfig(preferredSelectId: nextSelected)
    }

    private func hibernateOtherSites(keepingSiteId: String) {
        var count = 0
        for i in config.sites.indices where config.sites[i].enabled {
            if config.sites[i].id == keepingSiteId {
                config.sites[i].hibernated = false
            } else if !config.sites[i].hibernated {
                config.sites[i].hibernated = true
                count += 1
            }
        }
        config.selectedSiteId = keepingSiteId
        config.save()
        JWLog("HIBERNATE", "Hibernated \(count) other tab(s), keeping siteId=\(keepingSiteId)")
        syncWebViewsWithConfig(preferredSelectId: keepingSiteId)
    }

    private func hibernateAllSites() {
        var count = 0
        for i in config.sites.indices where config.sites[i].enabled && !config.sites[i].hibernated {
            config.sites[i].hibernated = true
            count += 1
        }
        config.save()
        JWLog("HIBERNATE", "Hibernated ALL \(count) awake tab(s) to free WebContent memory")
        syncWebViewsWithConfig(preferredSelectId: config.selectedSiteId)
    }

    @objc private func wakeSelectedSiteTapped() {
        guard !config.selectedSiteId.isEmpty else { return }
        setSiteHibernated(siteId: config.selectedSiteId, hibernated: false)
    }

    private func confirmDeleteSite(_ targetSite: SiteItem) {
        let extraNote = targetSite.isIsolatedStore
            ? "删除后将永久移除该站点及其独立账号空间的登录态，不可撤销。"
            : "删除后将从工作台永久移除该站点。"
        let alert = UIAlertController(
            title: "彻底删除「\(targetSite.title)」？",
            message: "\(extraNote)\n（如只是暂时不用想释放内存，建议选择「🌙 休眠此标签」）",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "彻底删除", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            self.config.sites.removeAll { $0.id == targetSite.id }
            self.config.save()
            JWLog("SITE", "Deleted site=\(targetSite.title)")
            self.syncWebViewsWithConfig(preferredSelectId: nil)
            self.applyDockCollapsedState(animated: false)
        })
        present(alert, animated: true)
    }

    private func rebuildTabPills() {
        for sub in tabsStackView.arrangedSubviews {
            tabsStackView.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        let enabled = enabledSites()
        if enabled.isEmpty {
            let addPill = SitePillControl(frame: .zero)
            addPill.configure(title: "+ 添加站点", active: true, aliveState: "OK", isolated: false)
            addPill.addTarget(self, action: #selector(openManageSheet), for: .touchUpInside)
            tabsStackView.addArrangedSubview(addPill)
            return
        }

        for s in enabled {
            let pill = SitePillControl(frame: .zero)
            pill.siteId = s.id
            let wpid = JWBridgeWebViewContentPID(webViews[s.id])
            let effBand = config.effectiveSiteBand(for: s)
            let badge: String
            if !s.hibernated, wpid > 0, let st = lastProcStatuses[wpid] {
                badge = st.displayBadge(targetBand: effBand, maxMB: config.maxMemoryMB)
            } else {
                badge = ""
            }
            let active = (s.id == config.selectedSiteId)
            pill.configure(
                title: s.title,
                active: active,
                aliveState: badge,
                isolated: s.isIsolatedStore,
                hibernated: s.hibernated,
                customBand: JWPriorityHelper.normalizeCustomBand(s.customBand)
            )
            pill.addTarget(self, action: #selector(tabPillTapped(_:)), for: .touchUpInside)
            pill.onLongPress = { [weak self] pressedPill in
                self?.handleTabPillLongPress(pressedPill)
            }
            tabsStackView.addArrangedSubview(pill)
        }
    }

    // MARK: - Quick Tab Menu, Long-Press Close/Hibernate, Per-Site Priority & Multi-Account Actions

    @objc private func tabPillTapped(_ sender: SitePillControl) {
        guard let tappedSite = site(forId: sender.siteId) else { return }
        if tappedSite.hibernated {
            setSiteHibernated(siteId: tappedSite.id, hibernated: false)
            return
        }
        if sender.siteId == config.selectedSiteId {
            showCurrentSiteQuickMenu(sourceView: sender)
        } else {
            selectSite(byId: sender.siteId)
        }
    }

    private func handleTabPillLongPress(_ sender: SitePillControl) {
        guard let targetSite = site(forId: sender.siteId) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showTabLongPressMenu(for: targetSite, sourceView: sender)
    }

    private func configureCenteredPopover(_ sheet: UIAlertController, sourceView: UIView?) {
        guard let pop = sheet.popoverPresentationController else { return }
        if let sourceView = sourceView {
            pop.sourceView = sourceView
            pop.sourceRect = sourceView.bounds
        } else {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
    }

    private func showTabLongPressMenu(for targetSite: SiteItem, sourceView: UIView?) {
        let spaceLabel = JWDataStoreHelper.label(for: targetSite.dataStoreId)
        let tierText = JWPriorityHelper.tierDescription(customBand: targetSite.customBand, globalBand: config.targetBand)
        let wpid = JWBridgeWebViewContentPID(webViews[targetSite.id])
        let st = (wpid > 0) ? lastProcStatuses[wpid] : nil

        let statusDesc: String
        if targetSite.hibernated {
            statusDesc = "状态：🌙 已休眠（占用 0 MB · 登录态已保留）\n保活等级：\(tierText) · \(spaceLabel)"
        } else if let st = st {
            statusDesc = "运行占用：\(st.footprintMB) MB（当前 \(st.band) 档）\n保活等级：\(tierText) · \(spaceLabel)"
        } else {
            statusDesc = "保活等级：\(tierText) · \(spaceLabel)"
        }

        let sheet = UIAlertController(
            title: targetSite.title,
            message: statusDesc,
            preferredStyle: .actionSheet
        )

        if targetSite.hibernated {
            sheet.addAction(UIAlertAction(title: "⚡️ 唤醒并打开此标签", style: .default) { [weak self] _ in
                self?.setSiteHibernated(siteId: targetSite.id, hibernated: false)
            })
        } else {
            sheet.addAction(UIAlertAction(title: "🌙 休眠此标签（释放内存，保留登录态）", style: .default) { [weak self] _ in
                self?.setSiteHibernated(siteId: targetSite.id, hibernated: true)
            })
        }

        let otherAwakeCount = awakeSites().filter { $0.id != targetSite.id }.count
        if otherAwakeCount > 0 {
            sheet.addAction(UIAlertAction(title: "🧹 休眠其他 \(otherAwakeCount) 个标签（仅留此标签）", style: .default) { [weak self] _ in
                self?.hibernateOtherSites(keepingSiteId: targetSite.id)
            })
        }

        if awakeSites().count >= 2 {
            sheet.addAction(UIAlertAction(title: "💤 全部标签休眠（释放全部网页内存）", style: .default) { [weak self] _ in
                self?.hibernateAllSites()
            })
        }

        sheet.addAction(UIAlertAction(title: "🎯 保活等级：\(tierText)", style: .default) { [weak self] _ in
            self?.showQuickPriorityPicker(for: targetSite, sourceView: sourceView)
        })

        sheet.addAction(UIAlertAction(title: "复制为独立新账号分身", style: .default) { [weak self] _ in
            self?.promptCloneIsolatedSite(from: targetSite)
        })

        sheet.addAction(UIAlertAction(title: "隐藏此标签（移出底栏，设置可恢复）", style: .default) { [weak self] _ in
            guard let self = self,
                  let idx = self.config.sites.firstIndex(where: { $0.id == targetSite.id }) else { return }
            self.config.sites[idx].enabled = false
            self.config.save()
            JWLog("SITE", "Hid site from dock site=\(targetSite.title)")
            self.syncWebViewsWithConfig(preferredSelectId: nil)
            self.applyDockCollapsedState(animated: false)
        })

        sheet.addAction(UIAlertAction(title: "彻底删除此站点…", style: .destructive) { [weak self] _ in
            self?.confirmDeleteSite(targetSite)
        })

        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        configureCenteredPopover(sheet, sourceView: sourceView)
        present(sheet, animated: true)
    }

    private func applyUpdatedSiteCustomBand(siteId: String, newCustomBand: Int) {
        guard let idx = config.sites.firstIndex(where: { $0.id == siteId }) else { return }
        let norm = JWPriorityHelper.normalizeCustomBand(newCustomBand)
        config.sites[idx].customBand = norm
        config.save()
        let eff = config.effectiveSiteBand(for: config.sites[idx])
        JWLog("PRIORITY", "Updated site=\(config.sites[idx].title) customBand=\(norm) effectiveBand=\(eff)")
        rebuildTabPills()
        scheduleApplyProtectionAsync { [weak self] summary in
            self?.runtime.helperBannerText = summary
            self?.queryLiveStatusesAsync()
        }
    }

    private func showQuickPriorityPicker(for site: SiteItem, sourceView: UIView?) {
        let curNorm = JWPriorityHelper.normalizeCustomBand(site.customBand)
        let clampedGlobal = JWPriorityHelper.clampSiteBand(config.targetBand)
        let sheet = UIAlertController(
            title: "\(site.title) · 进程保活等级",
            message: "iOS 内存吃紧时按档位从低到高依次回收（范围 30~92 档；网络与主进程自动压阵在最高标签之上 +1/+2 档）。",
            preferredStyle: .actionSheet
        )

        let presets: [(band: Int, title: String)] = [
            (0, "跟随全局默认（\(clampedGlobal) 档）"),
            (JWConstants.bandPresetCore, "🔥 核心常驻（88 档 · 最后回收）"),
            (JWConstants.bandPresetFrequent, "⭐️ 常用保活（80 档 · 高优常驻）"),
            (JWConstants.bandPresetSecondary, "📌 次要备选（70 档 · 优先让路）"),
            (JWConstants.bandPresetDisposable, "🍃 随用随清（35 档 · 内存紧先清）")
        ]

        for preset in presets {
            let prefix = (curNorm == preset.band) ? "✓ " : ""
            sheet.addAction(UIAlertAction(title: prefix + preset.title, style: .default) { [weak self] _ in
                self?.applyUpdatedSiteCustomBand(siteId: site.id, newCustomBand: preset.band)
            })
        }

        let isCustomOther = curNorm > 0 && !presets.contains(where: { $0.band == curNorm })
        let customPrefix = isCustomOther ? "✓ " : ""
        let customLabel = isCustomOther
            ? "🎛 自定义精确档位（当前 \(curNorm) 档，点击修改）"
            : "🎛 手动输入精确档位 (30 ~ 92)…"

        sheet.addAction(UIAlertAction(title: customPrefix + customLabel, style: .default) { [weak self] _ in
            self?.promptCustomBandInput(for: site)
        })

        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        configureCenteredPopover(sheet, sourceView: sourceView)
        present(sheet, animated: true)
    }

    private func promptCustomBandInput(for site: SiteItem) {
        let currentEff = config.effectiveSiteBand(for: site)
        let alert = UIAlertController(
            title: "自定义「\(site.title)」进程档位",
            message: "请输入 \(JWConstants.minSiteBand) ~ \(JWConstants.maxSiteBand) 之间的整数。数值越大优先级越高，越晚被系统清理（网络与主容器会自动保持在最高标签 +1/+2 档）。",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.placeholder = "30 ~ 92（如 82）"
            tf.text = "\(currentEff)"
            tf.keyboardType = .numberPad
            tf.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存并提档", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let rawText = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let digits = rawText.filter { $0.isNumber }
            guard let val = Int(digits) else { return }
            let clamped = JWPriorityHelper.clampSiteBand(val)
            self.applyUpdatedSiteCustomBand(siteId: site.id, newCustomBand: clamped)
        })
        present(alert, animated: true)
    }

    private func showQuickAppearancePicker(for site: SiteItem, sourceView: UIView?) {
        let sheet = UIAlertController(
            title: "\(site.title) · 外观模式",
            message: "遇到深色模式下输入框白底白字时，可切换为「强制浅色」立即生效。",
            preferredStyle: .actionSheet
        )
        let modes = [JWConstants.appearanceInherit, JWConstants.appearanceSystem, JWConstants.appearanceLight, JWConstants.appearanceDark]
        let cur = JWAppearanceHelper.normalizeSite(site.appearanceMode)
        for m in modes {
            let prefix = (m == cur) ? "✓ " : ""
            sheet.addAction(UIAlertAction(title: prefix + JWAppearanceHelper.label(for: m), style: .default) { [weak self] _ in
                guard let self = self,
                      let idx = self.config.sites.firstIndex(where: { $0.id == site.id }) else { return }
                self.config.sites[idx].appearanceMode = m
                self.config.save()
                self.applyAppearanceStyles()
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        configureCenteredPopover(sheet, sourceView: sourceView)
        present(sheet, animated: true)
    }

    private func showQuickAccountSpacePicker(for site: SiteItem, sourceView: UIView?) {
        let isIso = site.isIsolatedStore
        let sheet = UIAlertController(
            title: "\(site.title) · 账号空间",
            message: "切换为「独立账号空间」后，该标签拥有完全独立的 Cookie 与缓存，可同网站登录另一账号互不串号。",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(
            title: isIso ? "✓ 独立账号空间（当前使用）" : "切换为独立账号空间（可登录新账号）",
            style: .default
        ) { [weak self] _ in
            guard let self = self, !isIso,
                  let idx = self.config.sites.firstIndex(where: { $0.id == site.id }) else { return }
            self.config.sites[idx].dataStoreId = UUID().uuidString
            self.config.save()
            JWLog("STORE", "Quick-switched site=\(site.title) to isolated store")
            self.syncWebViewsWithConfig(preferredSelectId: site.id)
        })

        if isIso {
            sheet.addAction(UIAlertAction(title: "重置为全新独立账号空间（换另一新号）", style: .destructive) { [weak self] _ in
                guard let self = self,
                      let idx = self.config.sites.firstIndex(where: { $0.id == site.id }) else { return }
                self.config.sites[idx].dataStoreId = UUID().uuidString
                self.config.save()
                JWLog("STORE", "Rotated isolated store for site=\(site.title)")
                self.syncWebViewsWithConfig(preferredSelectId: site.id)
            })
        }

        sheet.addAction(UIAlertAction(
            title: !isIso ? "✓ 默认共享空间（当前使用）" : "切回默认共享空间（共用默认登录态）",
            style: .default
        ) { [weak self] _ in
            guard let self = self, isIso,
                  let idx = self.config.sites.firstIndex(where: { $0.id == site.id }) else { return }
            self.config.sites[idx].dataStoreId = JWConstants.dataStoreDefault
            self.config.save()
            JWLog("STORE", "Switched site=\(site.title) back to default store")
            self.syncWebViewsWithConfig(preferredSelectId: site.id)
        })

        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        configureCenteredPopover(sheet, sourceView: sourceView)
        present(sheet, animated: true)
    }

    private func promptCloneIsolatedSite(from site: SiteItem) {
        guard config.sites.count < JWConstants.maxSites else {
            let err = UIAlertController(
                title: "已达上限",
                message: "为保护 iPhone 4GB 内存，最多同时配置 \(JWConstants.maxSites) 个常驻标签。",
                preferredStyle: .alert
            )
            err.addAction(UIAlertAction(title: "好", style: .default))
            present(err, animated: true)
            return
        }

        let sameCount = config.sites.filter { $0.urlString == site.urlString }.count + 1
        let suggestTitle = "\(site.title) #\(sameCount)"

        let alert = UIAlertController(
            title: "复制为独立新账号分身",
            message: "新标签将分配独立持久的 Cookie 与 LocalStorage 空间，不会与原标签串号。",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.placeholder = "分身标签名称"
            tf.text = suggestTitle
            tf.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "创建并打开", style: .default) { [weak self, weak alert] _ in
            guard let self = self else { return }
            let raw = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let clone = SiteItem(
                title: raw.isEmpty ? suggestTitle : raw,
                urlString: site.urlString,
                enabled: true,
                appearanceMode: site.appearanceMode,
                dataStoreId: UUID().uuidString,
                customBand: site.customBand,
                hibernated: false
            )
            self.config.sites.append(clone)
            self.config.selectedSiteId = clone.id
            self.config.save()
            JWLog("STORE", "Cloned isolated site=\(clone.title)")
            self.syncWebViewsWithConfig(preferredSelectId: clone.id)
            self.applyDockCollapsedState(animated: false)
        })
        present(alert, animated: true)
    }

    private func showCurrentSiteQuickMenu(sourceView: UIView?) {
        guard let wv = webViews[config.selectedSiteId],
              let curSite = site(forId: config.selectedSiteId) else { return }
        let siteId = curSite.id
        let spaceLabel = JWDataStoreHelper.label(for: curSite.dataStoreId)
        let tierText = JWPriorityHelper.tierDescription(customBand: curSite.customBand, globalBand: config.targetBand)
        let sheet = UIAlertController(
            title: "\(curSite.title)（\(spaceLabel)）",
            message: wv.url?.absoluteString ?? curSite.urlString,
            preferredStyle: .actionSheet
        )
        if wv.canGoBack {
            sheet.addAction(UIAlertAction(title: "后退", style: .default) { _ in wv.goBack() })
        }
        if wv.canGoForward {
            sheet.addAction(UIAlertAction(title: "前进", style: .default) { _ in wv.goForward() })
        }
        sheet.addAction(UIAlertAction(title: "刷新当前页", style: .default) { [weak self] _ in
            self?.reloadSiteFromHomeOrCurrent(siteId: siteId, forceHome: false)
        })
        sheet.addAction(UIAlertAction(title: "回到初始首页", style: .default) { [weak self] _ in
            self?.reloadSiteFromHomeOrCurrent(siteId: siteId, forceHome: true)
        })
        sheet.addAction(UIAlertAction(title: "🌙 休眠此标签（释放内存，保留登录态）", style: .default) { [weak self] _ in
            self?.setSiteHibernated(siteId: siteId, hibernated: true)
        })
        sheet.addAction(UIAlertAction(title: "🎯 保活等级：\(tierText)", style: .default) { [weak self] _ in
            self?.showQuickPriorityPicker(for: curSite, sourceView: sourceView)
        })
        sheet.addAction(UIAlertAction(title: "复制为独立新账号分身", style: .default) { [weak self] _ in
            self?.promptCloneIsolatedSite(from: curSite)
        })
        sheet.addAction(UIAlertAction(title: "账号空间：\(spaceLabel)", style: .default) { [weak self] _ in
            self?.showQuickAccountSpacePicker(for: curSite, sourceView: sourceView)
        })
        sheet.addAction(UIAlertAction(title: "外观模式：\(JWAppearanceHelper.label(for: curSite.appearanceMode))", style: .default) { [weak self] _ in
            self?.showQuickAppearancePicker(for: curSite, sourceView: sourceView)
        })
        sheet.addAction(UIAlertAction(title: "复制当前网址", style: .default) { _ in
            UIPasteboard.general.string = wv.url?.absoluteString ?? curSite.urlString
        })
        sheet.addAction(UIAlertAction(title: "查看运行与诊断日志", style: .default) { [weak self] _ in
            self?.openLogViewerSheet()
        })
        sheet.addAction(UIAlertAction(title: "退出并清理此标签登录态", style: .destructive) { [weak self] _ in
            self?.clearDataForSite(siteId: siteId)
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        configureCenteredPopover(sheet, sourceView: sourceView)
        present(sheet, animated: true)
    }

    @objc private func collapseDockTapped() {
        config.dockCollapsed = true
        config.save()
        applyDockCollapsedState(animated: true)
    }

    @objc private func expandDockTapped() {
        config.dockCollapsed = false
        config.save()
        applyDockCollapsedState(animated: true)
    }

    private func applyDockCollapsedState(animated: Bool) {
        let collapsed = config.dockCollapsed && !enabledSites().isEmpty
        if collapsed {
            webBottomToDockConstraint.isActive = false
            webBottomToViewConstraint.isActive = true
        } else {
            webBottomToViewConstraint.isActive = false
            webBottomToDockConstraint.isActive = true
        }
        dockBar.isHidden = collapsed
        floatingPill.isHidden = !collapsed
        if animated {
            UIView.animate(withDuration: 0.2) {
                self.view.layoutIfNeeded()
            }
        }
    }

    @objc private func floatingPillLongPressed(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }
        let sheet = UIAlertController(title: "快速切换常驻 WebApp", message: nil, preferredStyle: .actionSheet)
        for s in enabledSites() {
            let selPrefix = (s.id == config.selectedSiteId) ? "✓ " : ""
            let hibPrefix = s.hibernated ? "🌙 " : ""
            let bandSuffix = s.customBand > 0 ? " (\(s.customBand)档)" : ""
            sheet.addAction(UIAlertAction(title: "\(selPrefix)\(hibPrefix)\(s.title)\(bandSuffix)", style: .default) { [weak self] _ in
                if s.hibernated {
                    self?.setSiteHibernated(siteId: s.id, hibernated: false)
                } else {
                    self?.selectSite(byId: s.id)
                }
            })
        }
        if let cur = site(forId: config.selectedSiteId), cur.enabled && !cur.hibernated {
            sheet.addAction(UIAlertAction(title: "🌙 休眠当前标签（释放内存）", style: .default) { [weak self] _ in
                self?.setSiteHibernated(siteId: cur.id, hibernated: true)
            })
        }
        sheet.addAction(UIAlertAction(title: "工作台设置", style: .default) { [weak self] _ in
            self?.openManageSheet()
        })
        sheet.addAction(UIAlertAction(title: "运行与诊断日志", style: .default) { [weak self] _ in
            self?.openLogViewerSheet()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        configureCenteredPopover(sheet, sourceView: floatingPill)
        present(sheet, animated: true)
    }

    @objc private func floatingPillPanned(_ pan: UIPanGestureRecognizer) {
        let delta = pan.translation(in: view)
        pan.setTranslation(.zero, in: view)
        floatingTrailingConstraint.constant += delta.x
        floatingBottomConstraint.constant += delta.y
        clampFloatingPillPosition()
    }

    @objc private func reloadCurrentSite() {
        reloadSiteFromHomeOrCurrent(siteId: config.selectedSiteId, forceHome: false)
    }

    @objc private func handlePullToRefresh(_ rc: UIRefreshControl) {
        for (sid, wv) in webViews where wv.scrollView.refreshControl === rc {
            reloadSiteFromHomeOrCurrent(siteId: sid, forceHome: false)
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            rc.endRefreshing()
        }
    }

    @objc private func openManageSheet() {
        refreshRuntimeWebPIDMap()
        let rootView = SettingsDrawerView(
            config: config,
            runtime: runtime,
            onClose: { [weak self] in
                self?.dismiss(animated: true)
            }
        )
        let host = UIHostingController(rootView: rootView)
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        let globalMode = JWAppearanceHelper.normalizeGlobal(config.appearanceMode)
        host.overrideUserInterfaceStyle = JWAppearanceHelper.uiStyle(for: globalMode, fallback: .unspecified)
        present(host, animated: true)
    }

    private func openLogViewerSheet() {
        refreshRuntimeWebPIDMap()
        let rootView = StandaloneDiagnosticLogSheet(
            config: config,
            runtime: runtime,
            onClose: { [weak self] in
                self?.dismiss(animated: true)
            }
        )
        let host = UIHostingController(rootView: rootView)
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        let globalMode = JWAppearanceHelper.normalizeGlobal(config.appearanceMode)
        host.overrideUserInterfaceStyle = JWAppearanceHelper.uiStyle(for: globalMode, fallback: .unspecified)
        present(host, animated: true)
    }

    // MARK: - Website Data Clearing & Diagnostic Header

    private func clearDataForSite(siteId: String) {
        guard let targetSite = site(forId: siteId) else { return }
        lastKnownURLBySiteId.removeValue(forKey: siteId)
        let shouldReload = !targetSite.hibernated
        let dsId = JWDataStoreHelper.normalize(targetSite.dataStoreId)
        clearBasicAuth(forStoreId: dsId)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let since = Date(timeIntervalSince1970: 0)

        if JWDataStoreHelper.isIsolated(dsId) {
            let store = customDataStores[dsId]
                ?? webViews[siteId]?.configuration.websiteDataStore
                ?? websiteDataStore(for: targetSite)
            JWLog("DATA", "Clearing isolated store for site=\(targetSite.title) store=\(String(dsId.prefix(8)))")
            store.removeData(ofTypes: types, modifiedSince: since) { [weak self] in
                if shouldReload {
                    self?.reloadSiteFromHomeOrCurrent(siteId: siteId, forceHome: true)
                }
            }
            return
        }

        let host = JWURLHelper.hostKey(targetSite.urlString)
        let parts = host.split(separator: ".")
        let rootDomain = parts.count >= 2 ? "\(parts[parts.count - 2]).\(parts[parts.count - 1])" : host
        JWLog("DATA", "Clearing default-store domain data for site=\(targetSite.title) domain=\(rootDomain)")

        let defStore = WKWebsiteDataStore.default()
        defStore.httpCookieStore.getAllCookies { [weak self] cookies in
            for c in cookies {
                let cd = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if !rootDomain.isEmpty && (cd == rootDomain || cd.hasSuffix("." + rootDomain) || host.hasSuffix(cd)) {
                    defStore.httpCookieStore.delete(c, completionHandler: nil)
                }
            }
            defStore.fetchDataRecords(ofTypes: types) { records in
                let matched = records.filter { rec in
                    let dn = rec.displayName.lowercased()
                    return !rootDomain.isEmpty && (dn == rootDomain || dn.contains(rootDomain) || host.contains(dn))
                }
                if !matched.isEmpty {
                    defStore.removeData(ofTypes: types, for: matched) {
                        if shouldReload {
                            self?.reloadSiteFromHomeOrCurrent(siteId: siteId, forceHome: true)
                        }
                    }
                } else if shouldReload {
                    self?.reloadSiteFromHomeOrCurrent(siteId: siteId, forceHome: true)
                }
            }
        }
    }

    private func clearAllWebsiteData() {
        sessionBasicAuth.removeAll()
        lastKnownURLBySiteId.removeAll()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let since = Date(timeIntervalSince1970: 0)
        var stores: [WKWebsiteDataStore] = [.default()]
        for s in config.sites where s.isIsolatedStore {
            let ds = websiteDataStore(for: s)
            if !stores.contains(where: { $0 === ds }) {
                stores.append(ds)
            }
        }
        for ds in customDataStores.values where !stores.contains(where: { $0 === ds }) {
            stores.append(ds)
        }
        JWLog("DATA", "Clearing ALL website data across \(stores.count) store(s)")

        let grp = DispatchGroup()
        for ds in stores {
            grp.enter()
            ds.removeData(ofTypes: types, modifiedSince: since) {
                grp.leave()
            }
        }
        grp.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            for sid in Array(self.webViews.keys) {
                self.reloadSiteFromHomeOrCurrent(siteId: sid, forceHome: true)
            }
        }
    }

    private func buildDiagnosticHeaderText() -> String {
        let dev = UIDevice.current
        let ramMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        let selfPid = getpid()
        let hostSt = lastProcStatuses[selfPid]
        let guardian = config.computedGuardianBands()

        var lines: [String] = []
        lines.append("=== JetWeb 诊断摘要 ===")
        lines.append("版本: v\(JWBridgeVersion()) (\(JWBridgeGitCommit())) | 系统: \(dev.systemName) \(dev.systemVersion) | 物理内存: \(ramMB) MB")
        lines.append("策略: 全局默认 \(config.targetBand) 档 (网络压阵 \(guardian.auxBand) 档 / 主容器 \(guardian.hostBand) 档) | 单页上限 \(config.maxMemoryMB) MB | 外观: \(config.appearanceMode) | 日志: \(config.debugLoggingEnabled ? "开启" : "关闭")")
        lines.append("主进程: PID \(selfPid) | 实测档位 \(hostSt?.band ?? -1) | 内存 \(hostSt?.footprintMB ?? 0) MB")

        for s in config.sites {
            let wv = webViews[s.id]
            let wpid = JWBridgeWebViewContentPID(wv)
            let npid = JWBridgeWebViewNetworkingPID(wv)
            let gpid = JWBridgeWebViewGPUPID(wv)
            let st = (wpid > 0) ? lastProcStatuses[wpid] : nil
            let stateLabel = !s.enabled ? "隐藏" : (s.hibernated ? "已休眠" : "运行中")
            let effBand = config.effectiveSiteBand(for: s)
            let bandLabel = s.customBand > 0 ? "专属\(effBand)档" : "默认\(effBand)档"
            let recMark = terminatedSiteIds.contains(s.id) ? " [曾被回收]" : ""
            lines.append("站点[\(stateLabel)]: \(s.title) | \(bandLabel) | \(JWDataStoreHelper.shortBadge(for: s.dataStoreId)) | WebPID=\(wpid) NetPID=\(npid) GPUPID=\(gpid) | 实测=\(st?.band ?? -1)档 内存=\(st?.footprintMB ?? 0)MB\(recMark)")
        }
        lines.append("======================")
        return lines.joined(separator: "\n")
    }

    // MARK: - Jetsam Protection Engine & Detached Background Guard

    private func writeBgEpochToken(_ epoch: UInt) {
        let path = AppConfig.effectiveBgEpochPath()
        guard !path.isEmpty else { return }
        let token = "\(epoch)\n"
        try? token.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func collectTargetPIDStringsOnMainThread() -> (
        queryPIDs: [String],
        applySpecs: [String],
        hostBand: Int,
        auxBand: Int,
        sharedSnapshot: String
    ) {
        let guardian = config.computedGuardianBands()
        var orderedPIDs: [Int32] = []
        var bandByPID: [Int32: Int] = [:]

        func recordPID(_ p: Int32, desiredBand: Int) {
            guard p > 0 else { return }
            if let existing = bandByPID[p] {
                if desiredBand > existing {
                    bandByPID[p] = desiredBand
                }
            } else {
                orderedPIDs.append(p)
                bandByPID[p] = desiredBand
            }
        }

        let selfPid = getpid()
        recordPID(selfPid, desiredBand: guardian.hostBand)

        var sharedLines = [
            "host_pid=\(selfPid) band=\(guardian.hostBand) default_site_band=\(config.targetBand) max_mb=\(config.maxMemoryMB)"
        ]
        var webMap: [String: Int32] = [:]

        for s in awakeSites() {
            let wv = webViews[s.id]
            let siteBand = config.effectiveSiteBand(for: s)
            let wpid = JWBridgeWebViewContentPID(wv)
            if wpid > 0 {
                recordPID(wpid, desiredBand: siteBand)
                webMap[s.id] = wpid
                sharedLines.append("webcontent_pid=\(wpid) site=\(s.id) band=\(siteBand)")
            }
            recordPID(JWBridgeWebViewProvisionalPID(wv), desiredBand: siteBand)
            recordPID(JWBridgeWebViewNetworkingPID(wv), desiredBand: guardian.auxBand)
            recordPID(JWBridgeWebViewGPUPID(wv), desiredBand: guardian.auxBand)
        }
        runtime.webPIDsBySiteId = webMap

        let queryPIDs = orderedPIDs.map { "\($0)" }
        let applySpecs = orderedPIDs.map { p in
            let b = bandByPID[p] ?? config.targetBand
            return "\(p):\(b)"
        }
        return (
            queryPIDs: queryPIDs,
            applySpecs: applySpecs,
            hostBand: guardian.hostBand,
            auxBand: guardian.auxBand,
            sharedSnapshot: sharedLines.joined(separator: "\n") + "\n"
        )
    }

    private static func writeSharedSnapshotOnBgQueue(_ text: String) {
        guard !text.isEmpty else { return }
        if FileManager.default.fileExists(atPath: JWConstants.pilotDir) {
            try? text.write(toFile: JWConstants.sharedPidPath, atomically: true, encoding: .utf8)
        }
    }

    private func startForegroundProtectTimer() {
        stopForegroundProtectTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            guard let self = self, UIApplication.shared.applicationState == .active else { return }
            self.scheduleApplyProtectionAsync(completion: nil)
        }
        timer.tolerance = 5.0
        fgProtectTimer = timer
    }

    private func stopForegroundProtectTimer() {
        fgProtectTimer?.invalidate()
        fgProtectTimer = nil
    }

    private func schedulePostStateChangeProtectionWaves() {
        tabSwitchSeq &+= 1
        let seq = tabSwitchSeq
        scheduleApplyProtectionAsync(completion: nil)

        for sec in [1.5, 5.0, 21.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self = self,
                      self.tabSwitchSeq == seq,
                      UIApplication.shared.applicationState == .active else { return }
                self.scheduleApplyProtectionAsync(completion: nil)
            }
        }
    }

    private func queryLiveStatusesAsync() {
        let collected = collectTargetPIDStringsOnMainThread()
        protectQueue.async { [weak self] in
            HubViewController.writeSharedSnapshotOnBgQueue(collected.sharedSnapshot)
            var args = ["--query"]
            args.append(contentsOf: collected.queryPIDs)
            var code: Int32 = -1
            let out = JWBridgeRunJetWebCtl(args, &code)
            let parsed = ProcStatus.parseHelperOutput(out)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !parsed.isEmpty {
                    self.lastProcStatuses = parsed
                    self.rebuildTabPills()
                }
            }
        }
    }

    private func scheduleApplyProtectionAsync(completion: ((String) -> Void)?) {
        let collected = collectTargetPIDStringsOnMainThread()
        let band = config.targetBand
        let maxMB = config.maxMemoryMB
        let hostBand = collected.hostBand

        protectQueue.async { [weak self] in
            HubViewController.writeSharedSnapshotOnBgQueue(collected.sharedSnapshot)
            var args = ["--apply", "\(band)", "\(maxMB)"]
            args.append(contentsOf: collected.applySpecs)

            var exitCode: Int32 = -1
            let out = JWBridgeRunJetWebCtl(args, &exitCode)
            let parsed = ProcStatus.parseHelperOutput(out)
            let compactOut = out.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " | ")

            let summary: String
            if exitCode == 0 {
                summary = "✓ 已同步分档保活（主容器 \(hostBand) 档 · 单页上限 \(maxMB) MB）"
            } else {
                summary = "提档助手返回码 \(exitCode)（请确认通过 TrollStore 安装）"
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                var digest = "rc=\(exitCode)"
                for k in parsed.keys.sorted() {
                    if let st = parsed[k] {
                        digest += ",\(st.pid):\(st.stateTag):\(st.band)"
                    }
                }
                if completion != nil || exitCode != 0 || digest != self.lastLoggedApplyDigest {
                    self.lastLoggedApplyDigest = digest
                    JWLog("JETSAM", "apply rc=\(exitCode) hostBand=\(hostBand) default=\(band) max=\(maxMB)MB -> \(compactOut.isEmpty ? "(empty)" : compactOut)")
                }
                if !parsed.isEmpty {
                    self.lastProcStatuses = parsed
                    self.rebuildTabPills()
                }
                completion?(summary)
            }
        }
    }

    @objc private func appDidEnterBackground() {
        stopForegroundProtectTimer()
        endBackgroundGuardTask()

        bgEpoch &+= 1
        let epoch = bgEpoch
        writeBgEpochToken(epoch)
        JWLog("BG", "DidEnterBackground epoch=\(epoch)")

        bgTask = UIApplication.shared.beginBackgroundTask(withName: "com.lili.jetweb.jetsamguard") { [weak self] in
            JWLog("BG", "UIBackgroundTask expired by system")
            self?.endBackgroundGuardTask()
        }

        scheduleApplyProtectionAsync(completion: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, self.bgEpoch == epoch else { return }
            let collected = self.collectTargetPIDStringsOnMainThread()
            let band = self.config.targetBand
            let maxMB = self.config.maxMemoryMB
            let epochPath = AppConfig.effectiveBgEpochPath()
            let logArg = self.config.debugLoggingEnabled ? JWLogger.logFilePath : "-"
            JWLog("BG", "Spawning detached --bg-guard epoch=\(epoch) specs=[\(collected.applySpecs.joined(separator: ","))]")

            self.protectQueue.async {
                HubViewController.writeSharedSnapshotOnBgQueue(collected.sharedSnapshot)
                JWBridgeSpawnDetachedBgGuard(band, maxMB, epochPath, epoch, logArg, collected.applySpecs)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self, self.bgEpoch == epoch else { return }
                JWLog("BG", "Releasing UIBackgroundTask so host suspends cleanly (epoch=\(epoch))")
                self.endBackgroundGuardTask()
            }
        }
    }

    @objc private func appWillEnterForeground() {
        bgEpoch &+= 1
        writeBgEpochToken(bgEpoch)
        endBackgroundGuardTask()
        JWLog("FG", "WillEnterForeground newEpoch=\(bgEpoch) terminatedCount=\(terminatedSiteIds.count)")
        applyAppearanceStyles()
        recoverWebViewIfTerminated(siteId: config.selectedSiteId)
        startForegroundProtectTimer()
        schedulePostStateChangeProtectionWaves()
    }

    @objc private func appDidReceiveMemoryWarning() {
        let hibCount = enabledSites().filter { $0.hibernated }.count
        let items = awakeSites().map { s -> String in
            let wpid = JWBridgeWebViewContentPID(webViews[s.id])
            let mb = (wpid > 0) ? (lastProcStatuses[wpid]?.footprintMB ?? 0) : 0
            let eff = config.effectiveSiteBand(for: s)
            return "\(s.title)(\(wpid):\(mb)MB@\(eff))"
        }
        JWLog("MEM-WARN", "System memory warning! awake=[\(items.joined(separator: ", "))] hibernated=\(hibCount)")
    }

    private func endBackgroundGuardTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    // MARK: - Auth Challenge Queue (Self-Signed TLS & Store-Scoped HTTP Basic Auth)

    private func topMostPresenter() -> UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController {
            top = next
        }
        return top
    }

    private func enqueueAuthPrompt(_ block: @escaping () -> Void) {
        authPromptQueue.append(block)
        drainAuthPromptQueue()
    }

    private func drainAuthPromptQueue() {
        guard !isPresentingAuthAlert, !authPromptQueue.isEmpty else { return }
        isPresentingAuthAlert = true
        let next = authPromptQueue.removeFirst()
        next()
    }

    private func presentAuthAlertSafely(_ alert: UIAlertController, retryLeft: Int, onCancel: @escaping () -> Void) {
        if view.window == nil {
            if retryLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.presentAuthAlertSafely(alert, retryLeft: retryLeft - 1, onCancel: onCancel)
                }
            } else {
                onCancel()
                isPresentingAuthAlert = false
                drainAuthPromptQueue()
            }
            return
        }
        let presenter = topMostPresenter()
        if presenter is UIAlertController || presenter.transitionCoordinator != nil {
            if retryLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.presentAuthAlertSafely(alert, retryLeft: retryLeft - 1, onCancel: onCancel)
                }
            } else {
                onCancel()
                isPresentingAuthAlert = false
                drainAuthPromptQueue()
            }
            return
        }
        presenter.present(alert, animated: true)
    }

    private func resolvePendingTrust(key: String, accept: Bool, rejectedHost: String) {
        guard let items = pendingTrustQueues.removeValue(forKey: key) else { return }
        for item in items {
            if !accept, let sid = siteId(for: item.webView) {
                lastRejectedAuthBySiteId[sid] = (
                    title: "已拒绝不受信任的证书",
                    detail: "已取消与 \(rejectedHost) 的安全连接。\n如需访问该自签名内网服务，请点击「重新加载」并在弹窗中选择信任。"
                )
            }
            item.resolve(accept: accept)
        }
    }

    private func resolvePendingBasicAuth(key: String, credential: URLCredential?, rejectedHost: String) {
        guard let items = pendingBasicAuthQueues.removeValue(forKey: key) else { return }
        for item in items {
            if credential == nil, let sid = siteId(for: item.webView) {
                lastRejectedAuthBySiteId[sid] = (
                    title: "身份验证已取消",
                    detail: "\(rejectedHost) 需要 HTTP 账号密码登录，请点击「重新加载」重新输入。"
                )
            }
            item.resolve(credential: credential)
        }
    }

    private func handleServerTrustChallenge(_ challenge: URLAuthenticationChallenge, webView: WKWebView, guardObj: AuthChallengeGuard) {
        let space = challenge.protectionSpace
        guard let serverTrust = space.serverTrust else {
            guardObj.invoke(.performDefaultHandling)
            return
        }
        let host = space.host.lowercased()
        let port = space.port

        trustEvalQueue.async { [weak self] in
            var cfErr: CFError?
            let systemTrusted = SecTrustEvaluateWithError(serverTrust, &cfErr)
            let evalReason = (cfErr as Error?)?.localizedDescription ?? ""

            if systemTrusted {
                DispatchQueue.main.async {
                    guardObj.invoke(.performDefaultHandling)
                }
                return
            }

            let info = JWBridgeExtractLeafCertInfo(serverTrust)
            let fingerprint = info["fingerprint"] ?? ""
            let subject = info["subject"] ?? ""
            let pendingItem = PendingTrustItem(serverTrust: serverTrust, guardObj: guardObj, webView: webView)

            DispatchQueue.main.async {
                guard let self = self else {
                    pendingItem.resolve(accept: false)
                    return
                }

                if !host.isEmpty && !fingerprint.isEmpty {
                    if self.config.trustedCerts[host] == fingerprint || self.sessionTrustedCerts[host] == fingerprint {
                        pendingItem.resolve(accept: true)
                        return
                    }
                }

                let trustKey = "\(host)|\(fingerprint)"
                if self.pendingTrustQueues[trustKey] != nil {
                    self.pendingTrustQueues[trustKey]?.append(pendingItem)
                    return
                }
                self.pendingTrustQueues[trustKey] = [pendingItem]

                let displayHost = (port > 0 && port != 443) ? "\(host):\(port)" : host
                JWLog("AUTH", "Untrusted TLS prompt host=\(displayHost) sha256=\(JWURLHelper.shortFingerprint(fingerprint))")

                self.enqueueAuthPrompt { [weak self] in
                    guard let self = self else { return }
                    if !host.isEmpty && !fingerprint.isEmpty &&
                        (self.config.trustedCerts[host] == fingerprint || self.sessionTrustedCerts[host] == fingerprint) {
                        self.resolvePendingTrust(key: trustKey, accept: true, rejectedHost: displayHost)
                        self.isPresentingAuthAlert = false
                        self.drainAuthPromptQueue()
                        return
                    }

                    var msg = "域名：\(displayHost.isEmpty ? "未知主机" : displayHost)"
                    if !subject.isEmpty { msg += "\n证书主体：\(subject)" }
                    if !fingerprint.isEmpty { msg += "\nSHA-256：\(JWURLHelper.shortFingerprint(fingerprint))" }
                    if !evalReason.isEmpty { msg += "\n校验详情：\(evalReason)" }
                    msg += "\n\n仅在你确认这是自建内网或受控服务时信任此证书。"

                    let alert = UIAlertController(title: "证书不受系统信任", message: msg, preferredStyle: .alert)
                    if !host.isEmpty && !fingerprint.isEmpty {
                        alert.addAction(UIAlertAction(title: "永久信任此域名", style: .default) { [weak self] _ in
                            guard let self = self else { return }
                            self.config.trustedCerts[host] = fingerprint
                            self.config.save()
                            JWLog("AUTH", "User permanently trusted TLS cert for host=\(host)")
                            self.resolvePendingTrust(key: trustKey, accept: true, rejectedHost: displayHost)
                            self.isPresentingAuthAlert = false
                            self.drainAuthPromptQueue()
                        })
                    }
                    alert.addAction(UIAlertAction(title: "仅本次信任", style: .default) { [weak self] _ in
                        guard let self = self else { return }
                        if !host.isEmpty && !fingerprint.isEmpty {
                            self.sessionTrustedCerts[host] = fingerprint
                        }
                        JWLog("AUTH", "User trusted TLS cert for session host=\(host)")
                        self.resolvePendingTrust(key: trustKey, accept: true, rejectedHost: displayHost)
                        self.isPresentingAuthAlert = false
                        self.drainAuthPromptQueue()
                    })
                    alert.addAction(UIAlertAction(title: "拒绝连接", style: .cancel) { [weak self] _ in
                        guard let self = self else { return }
                        JWLog("AUTH", "User rejected TLS cert for host=\(host)")
                        self.resolvePendingTrust(key: trustKey, accept: false, rejectedHost: displayHost)
                        self.isPresentingAuthAlert = false
                        self.drainAuthPromptQueue()
                    })

                    self.presentAuthAlertSafely(alert, retryLeft: 30) { [weak self] in
                        self?.resolvePendingTrust(key: trustKey, accept: false, rejectedHost: displayHost)
                    }
                }
            }
        }
    }

    private func handleBasicAuthChallenge(_ challenge: URLAuthenticationChallenge, webView: WKWebView, guardObj: AuthChallengeGuard) {
        let space = challenge.protectionSpace
        let host = space.host.lowercased()
        let port = space.port
        let realm = space.realm ?? ""
        let sid = siteId(for: webView)
        let curSite = sid.flatMap { site(forId: $0) }
        let storeKey = JWDataStoreHelper.normalize(curSite?.dataStoreId)
        let realmKey = "\(storeKey)|\(host):\(port):\(realm)"
        let displayHost = (port > 0 && port != 443 && port != 80) ? "\(host):\(port)" : host

        if challenge.previousFailureCount == 0, let cached = sessionBasicAuth[realmKey] {
            guardObj.invoke(.useCredential, credential: cached)
            return
        } else if challenge.previousFailureCount > 0 {
            sessionBasicAuth.removeValue(forKey: realmKey)
        }

        JWLog("AUTH", "BasicAuth prompt host=\(displayHost) store=\(JWDataStoreHelper.isIsolated(storeKey) ? "isolated" : "default") prevFail=\(challenge.previousFailureCount)")

        let pendingItem = PendingBasicAuthItem(guardObj: guardObj, webView: webView)
        if pendingBasicAuthQueues[realmKey] != nil {
            pendingBasicAuthQueues[realmKey]?.append(pendingItem)
            return
        }
        pendingBasicAuthQueues[realmKey] = [pendingItem]

        let prevFailures = challenge.previousFailureCount
        let proposedUser = challenge.proposedCredential?.user ?? ""
        let siteTitle = curSite?.title ?? ""

        enqueueAuthPrompt { [weak self] in
            guard let self = self else { return }
            if prevFailures == 0, let cached = self.sessionBasicAuth[realmKey] {
                self.resolvePendingBasicAuth(key: realmKey, credential: cached, rejectedHost: displayHost)
                self.isPresentingAuthAlert = false
                self.drainAuthPromptQueue()
                return
            }

            var msg = "站点：\(displayHost.isEmpty ? "未知主机" : displayHost)"
            if !siteTitle.isEmpty { msg += "（\(siteTitle)）" }
            if !realm.isEmpty { msg += "\n认证域：\(realm)" }
            if prevFailures > 0 { msg += "\n用户名或密码错误，请重试。" }

            let alert = UIAlertController(title: "需要身份验证", message: msg, preferredStyle: .alert)
            alert.addTextField { tf in
                tf.placeholder = "用户名"
                tf.text = proposedUser
                tf.autocapitalizationType = .none
                tf.autocorrectionType = .no
                tf.clearButtonMode = .whileEditing
            }
            alert.addTextField { tf in
                tf.placeholder = "密码"
                tf.isSecureTextEntry = true
                tf.clearButtonMode = .whileEditing
            }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
                guard let self = self else { return }
                self.resolvePendingBasicAuth(key: realmKey, credential: nil, rejectedHost: displayHost)
                self.isPresentingAuthAlert = false
                self.drainAuthPromptQueue()
            })
            alert.addAction(UIAlertAction(title: "登录", style: .default) { [weak self, weak alert] _ in
                guard let self = self else { return }
                let user = alert?.textFields?.first?.text ?? ""
                let pass = (alert?.textFields?.count ?? 0) > 1 ? (alert?.textFields?[1].text ?? "") : ""
                let cred = URLCredential(user: user, password: pass, persistence: .forSession)
                self.sessionBasicAuth[realmKey] = cred
                self.resolvePendingBasicAuth(key: realmKey, credential: cred, rejectedHost: displayHost)
                self.isPresentingAuthAlert = false
                self.drainAuthPromptQueue()
            })

            self.presentAuthAlertSafely(alert, retryLeft: 30) { [weak self] in
                self?.resolvePendingBasicAuth(key: realmKey, credential: nil, rejectedHost: displayHost)
            }
        }
    }

    // MARK: - WKScriptMessageHandler & WKNavigationDelegate & WKUIDelegate

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard config.debugLoggingEnabled,
              message.name == "jwDiag",
              let dict = message.body as? [String: Any] else { return }
        let kind = (dict["k"] as? String) ?? "err"
        var msg = (dict["m"] as? String) ?? ""
        guard !msg.isEmpty else { return }
        if msg.count > 220 {
            msg = String(msg.prefix(220)) + "..."
        }
        let title = siteId(for: message.webView).flatMap { site(forId: $0)?.title } ?? "?"
        JWLog("JS-ERR", "site=\(title) (\(kind)) \(msg)")
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let sid = siteId(for: webView) {
            hideErrorOverlay(forSiteId: sid)
        }
        refreshRuntimeWebPIDMap()
        scheduleApplyProtectionAsync(completion: nil)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let sid = siteId(for: webView) {
            terminatedSiteIds.remove(sid)
            hideErrorOverlay(forSiteId: sid)
            let sTitle = site(forId: sid)?.title ?? sid
            JWLog("NAV", "Commit site=\(sTitle) webPID=\(JWBridgeWebViewContentPID(webView)) netPID=\(JWBridgeWebViewNetworkingPID(webView)) url=\(JWLogger.maskURL(webView.url))")
        }
        refreshRuntimeWebPIDMap()
        schedulePostStateChangeProtectionWaves()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.scrollView.refreshControl?.endRefreshing()
        if let sid = siteId(for: webView) {
            terminatedSiteIds.remove(sid)
            hideErrorOverlay(forSiteId: sid)
        }
        if webView === webViews[config.selectedSiteId] {
            progressView.isHidden = true
        }
        webView.evaluateJavaScript(
            "if(window.__jwRecheckInputs)window.__jwRecheckInputs();",
            in: nil,
            in: .defaultClient,
            completionHandler: nil
        )
        refreshRuntimeWebPIDMap()
        schedulePostStateChangeProtectionWaves()
    }

    private static func shouldIgnoreNavigationError(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            return true
        }
        if error.domain == "WebKitErrorDomain" && (error.code == 102 || error.code == 204) {
            return true
        }
        return false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
        if webView === webViews[config.selectedSiteId] {
            progressView.isHidden = true
        }
        let nsErr = error as NSError
        guard !HubViewController.shouldIgnoreNavigationError(nsErr) else { return }
        let sTitle = siteId(for: webView).flatMap { site(forId: $0)?.title } ?? "?"
        JWLog("NAV-FAIL", "didFail site=\(sTitle) domain=\(nsErr.domain) code=\(nsErr.code) desc=\(nsErr.localizedDescription)")
        if webView.url == nil || webView.url?.absoluteString == "about:blank" || ErrorOverlayView.isSSLError(nsErr) {
            showErrorOverlay(for: webView, error: nsErr, customTitle: nil, customDetail: nil)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView.scrollView.refreshControl?.endRefreshing()
        if webView === webViews[config.selectedSiteId] {
            progressView.isHidden = true
        }
        let nsErr = error as NSError
        let sid = siteId(for: webView)
        let sTitle = sid.flatMap { site(forId: $0)?.title } ?? "?"

        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
            if let sid = sid,
               let rej = lastRejectedAuthBySiteId[sid],
               (webView.url == nil || webView.url?.absoluteString == "about:blank") {
                JWLog("AUTH", "Showing rejected auth/cert overlay for site=\(sTitle)")
                showErrorOverlay(for: webView, error: nsErr, customTitle: rej.title, customDetail: rej.detail)
            }
            return
        }
        guard !HubViewController.shouldIgnoreNavigationError(nsErr) else { return }
        JWLog("NAV-FAIL", "didFailProvisional site=\(sTitle) domain=\(nsErr.domain) code=\(nsErr.code) desc=\(nsErr.localizedDescription)")
        showErrorOverlay(for: webView, error: nsErr, customTitle: nil, customDetail: nil)
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let guardObj = AuthChallengeGuard(completionHandler)
        let method = challenge.protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodServerTrust {
            handleServerTrustChallenge(challenge, webView: webView, guardObj: guardObj)
            return
        }
        if method == NSURLAuthenticationMethodHTTPBasic ||
            method == NSURLAuthenticationMethodHTTPDigest ||
            method == NSURLAuthenticationMethodDefault {
            handleBasicAuthChallenge(challenge, webView: webView, guardObj: guardObj)
            return
        }
        guardObj.invoke(.performDefaultHandling)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let hitId = siteId(for: webView) else { return }
        let sTitle = site(forId: hitId)?.title ?? hitId
        let st = UIApplication.shared.applicationState
        let isSelected = (hitId == config.selectedSiteId)
        JWLog("TERM", "WebContent terminated! site=\(sTitle) selected=\(isSelected) appState=\(st.rawValue)")
        refreshRuntimeWebPIDMap()

        if isSelected && st == .active {
            reloadSiteFromHomeOrCurrent(siteId: hitId, forceHome: false)
        } else {
            terminatedSiteIds.insert(hitId)
            rebuildTabPills()
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if !(navigationAction.targetFrame?.isMainFrame ?? false), let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           !scheme.isEmpty,
           !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private func canPresentJSDialog(for webView: WKWebView) -> Bool {
        return webView === webViews[config.selectedSiteId]
            && view.window != nil
            && presentedViewController == nil
            && transitionCoordinator == nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let guardObj = JSAlertGuard(completionHandler)
        guard canPresentJSDialog(for: webView) else {
            guardObj.invoke()
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in guardObj.invoke() })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let guardObj = JSConfirmGuard(completionHandler)
        guard canPresentJSDialog(for: webView) else {
            guardObj.invoke(false)
            return
        }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in guardObj.invoke(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in guardObj.invoke(true) })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let guardObj = JSPromptGuard(completionHandler)
        guard canPresentJSDialog(for: webView) else {
            guardObj.invoke(nil)
            return
        }
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { tf in tf.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in guardObj.invoke(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak alert] _ in
            guardObj.invoke(alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }
}
