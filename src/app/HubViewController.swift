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

// MARK: - Bottom Dock Tab Pill Control (Frosted Glass & Specular Capsule)

final class SitePillControl: UIControl {
    var siteId: String = ""
    var onLongPress: ((SitePillControl) -> Void)?

    private let activeGradient = CAGradientLayer()
    private let haloView = UIView()
    private let dotView = UIView()
    private let sleepIconView = UIImageView()
    private let titleLabel = UILabel()
    private let metaBadge = UIView()
    private let metaLabel = UILabel()
    private let unreadCornerDot = UIView()

    private var isTabActive: Bool = false
    private var isTabHibernated: Bool = false
    private var lastAliveState: String = ""
    private var hasUnread: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 17
        layer.cornerCurve = .continuous

        activeGradient.startPoint = CGPoint(x: 0.0, y: 0.0)
        activeGradient.endPoint = CGPoint(x: 1.0, y: 1.0)
        activeGradient.cornerRadius = 17
        activeGradient.cornerCurve = .continuous
        activeGradient.isHidden = true
        layer.insertSublayer(activeGradient, at: 0)

        haloView.translatesAutoresizingMaskIntoConstraints = false
        haloView.layer.cornerRadius = 6
        haloView.isUserInteractionEnabled = false
        addSubview(haloView)

        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.layer.cornerRadius = 3.25
        dotView.isUserInteractionEnabled = false
        haloView.addSubview(dotView)

        sleepIconView.translatesAutoresizingMaskIntoConstraints = false
        let moonCfg = UIImage.SymbolConfiguration(pointSize: 10.5, weight: .bold)
        sleepIconView.image = UIImage(systemName: "moon.zzz.fill", withConfiguration: moonCfg)
        sleepIconView.contentMode = .scaleAspectFit
        sleepIconView.isHidden = true
        sleepIconView.isUserInteractionEnabled = false
        addSubview(sleepIconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isUserInteractionEnabled = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metaBadge.translatesAutoresizingMaskIntoConstraints = false
        metaBadge.layer.cornerRadius = 5.5
        metaBadge.layer.cornerCurve = .continuous
        metaBadge.isUserInteractionEnabled = false

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        metaLabel.isUserInteractionEnabled = false
        metaLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        metaBadge.addSubview(metaLabel)

        let rowStack = UIStackView(arrangedSubviews: [titleLabel, metaBadge])
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = 5
        rowStack.isUserInteractionEnabled = false
        addSubview(rowStack)

        unreadCornerDot.translatesAutoresizingMaskIntoConstraints = false
        unreadCornerDot.backgroundColor = .systemRed
        unreadCornerDot.layer.cornerRadius = 4.25
        unreadCornerDot.layer.borderWidth = 1.5
        unreadCornerDot.isHidden = true
        unreadCornerDot.isUserInteractionEnabled = false
        addSubview(unreadCornerDot)

        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        lp.minimumPressDuration = 0.42
        addGestureRecognizer(lp)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            widthAnchor.constraint(lessThanOrEqualToConstant: 186),

            haloView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            haloView.centerYAnchor.constraint(equalTo: centerYAnchor),
            haloView.widthAnchor.constraint(equalToConstant: 12),
            haloView.heightAnchor.constraint(equalToConstant: 12),

            dotView.centerXAnchor.constraint(equalTo: haloView.centerXAnchor),
            dotView.centerYAnchor.constraint(equalTo: haloView.centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 6.5),
            dotView.heightAnchor.constraint(equalToConstant: 6.5),

            sleepIconView.centerXAnchor.constraint(equalTo: haloView.centerXAnchor),
            sleepIconView.centerYAnchor.constraint(equalTo: haloView.centerYAnchor),
            sleepIconView.widthAnchor.constraint(equalToConstant: 13),
            sleepIconView.heightAnchor.constraint(equalToConstant: 13),

            rowStack.leadingAnchor.constraint(equalTo: haloView.trailingAnchor, constant: 5.5),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            rowStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            metaBadge.heightAnchor.constraint(equalToConstant: 16),
            metaLabel.leadingAnchor.constraint(equalTo: metaBadge.leadingAnchor, constant: 4.5),
            metaLabel.trailingAnchor.constraint(equalTo: metaBadge.trailingAnchor, constant: -4.5),
            metaLabel.centerYAnchor.constraint(equalTo: metaBadge.centerYAnchor),

            unreadCornerDot.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            unreadCornerDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            unreadCornerDot.widthAnchor.constraint(equalToConstant: 8.5),
            unreadCornerDot.heightAnchor.constraint(equalToConstant: 8.5)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        activeGradient.frame = bounds
        CATransaction.commit()
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.13, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyColors()
    }

    @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
        if gr.state == .began {
            onLongPress?(self)
        }
    }

    func configure(
        title: String,
        active: Bool,
        aliveState: String,
        isolated: Bool,
        hibernated: Bool = false,
        customBand: Int = 0,
        unread: Bool = false
    ) {
        isTabActive = active
        isTabHibernated = hibernated
        lastAliveState = aliveState
        hasUnread = unread

        titleLabel.text = title.isEmpty ? "网页" : title

        var tags: [String] = []
        if isolated { tags.append("独") }
        if customBand > 0 { tags.append("\(customBand)") }
        if tags.isEmpty {
            metaBadge.isHidden = true
        } else {
            metaLabel.text = tags.joined(separator: "·")
            metaBadge.isHidden = false
        }

        haloView.isHidden = hibernated
        sleepIconView.isHidden = !hibernated
        unreadCornerDot.isHidden = !(unread && !active && !hibernated)

        applyColors()
    }

    private func applyColors() {
        let isDark = (traitCollection.userInterfaceStyle == .dark)
        let hairline = 1.0 / UIScreen.main.scale
        layer.borderWidth = hairline
        unreadCornerDot.layer.borderColor = (isDark ? UIColor.black : UIColor.white).cgColor

        if isTabActive {
            activeGradient.isHidden = false
            backgroundColor = .clear
            if isTabHibernated {
                activeGradient.colors = [
                    UIColor(red: 0.42, green: 0.36, blue: 0.94, alpha: 1.0).cgColor,
                    UIColor(red: 0.31, green: 0.24, blue: 0.80, alpha: 1.0).cgColor
                ]
            } else {
                activeGradient.colors = [
                    UIColor(red: 0.16, green: 0.48, blue: 0.98, alpha: 1.0).cgColor,
                    UIColor(red: 0.29, green: 0.31, blue: 0.91, alpha: 1.0).cgColor
                ]
            }
            layer.borderColor = UIColor.white.withAlphaComponent(0.36).cgColor
            titleLabel.textColor = .white
            metaBadge.backgroundColor = UIColor.white.withAlphaComponent(0.22)
            metaLabel.textColor = .white
            sleepIconView.tintColor = UIColor(red: 0.88, green: 0.84, blue: 1.0, alpha: 1.0)
            alpha = 1.0
        } else {
            activeGradient.isHidden = true
            if isTabHibernated {
                backgroundColor = UIColor.systemIndigo.withAlphaComponent(isDark ? 0.16 : 0.09)
                layer.borderColor = UIColor.systemIndigo.withAlphaComponent(isDark ? 0.28 : 0.18).cgColor
                titleLabel.textColor = .secondaryLabel
                sleepIconView.tintColor = .systemIndigo
                alpha = 0.88
            } else {
                backgroundColor = UIColor.systemBackground.withAlphaComponent(isDark ? 0.48 : 0.84)
                layer.borderColor = UIColor.white.withAlphaComponent(isDark ? 0.10 : 0.65).cgColor
                titleLabel.textColor = .label
                alpha = 1.0
            }
            metaBadge.backgroundColor = UIColor.tertiarySystemFill.withAlphaComponent(0.85)
            metaLabel.textColor = .secondaryLabel
        }

        if hasUnread && !isTabActive && !isTabHibernated {
            dotView.backgroundColor = .systemRed
            haloView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.20)
        } else if lastAliveState == "OK" || lastAliveState == "FG" {
            let emerald = isTabActive
                ? UIColor(red: 0.36, green: 1.0, blue: 0.60, alpha: 1.0)
                : UIColor.systemGreen
            dotView.backgroundColor = emerald
            haloView.backgroundColor = emerald.withAlphaComponent(isTabActive ? 0.26 : 0.18)
        } else if lastAliveState == "OVER_MEM" {
            dotView.backgroundColor = .systemOrange
            haloView.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.22)
        } else {
            let neutral = isTabActive ? UIColor(white: 1.0, alpha: 0.72) : UIColor.tertiaryLabel
            dotView.backgroundColor = neutral
            haloView.backgroundColor = neutral.withAlphaComponent(0.15)
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
    private var unreadSiteIds: Set<String> = []

    private var terminatedSiteIds: Set<String> = [] {
        didSet { runtime.terminatedSiteIds = terminatedSiteIds }
    }
    private var detachedSiteIds: Set<String> = [] {
        didSet { runtime.detachedSiteIds = detachedSiteIds }
    }
    private var isTrimmingMemory: Bool = false {
        didSet { runtime.isTrimmingMemory = isTrimmingMemory }
    }
    private var lastProcStatuses: [Int32: ProcStatus] = [:] {
        didSet { runtime.liveStatuses = lastProcStatuses }
    }
    private var lastActiveUptimeBySiteId: [String: TimeInterval] = [:]
    private var lastStreamingUptimeBySiteId: [String: TimeInterval] = [:]
    private var lastAutoTrimUptime: TimeInterval = 0
    private var lastAutoDeepTrimUptime: TimeInterval = 0
    private var lastMemWarningUptime: TimeInterval = 0
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
    private let emptyShadowWrap = UIView()
    private let emptyGlassCard = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))

    private let hibernatedStateView = UIView()
    private let hibernatedShadowWrap = UIView()
    private let hibernatedGlassCard = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let hibernatedTitleLabel = UILabel()
    private let hibernatedSubLabel = UILabel()

    private let dockAmbientTintView = UIView()
    private var dockBar: UIVisualEffectView!
    private let dockTopHighlight = UIView()
    private let tabsTrayView = UIView()
    private let toolsCapsuleView = UIView()
    private let tabsScrollView = UIScrollView()
    private let tabsStackView = UIStackView()
    private var webBottomToDockConstraint: NSLayoutConstraint!
    private var webBottomToViewConstraint: NSLayoutConstraint!

    private let floatingShadowWrap = UIView()
    private var floatingPill: UIVisualEffectView!
    private let floatingDotView = UIView()
    private let floatingLabel = UILabel()
    private var floatingTrailingConstraint: NSLayoutConstraint!
    private var floatingBottomConstraint: NSLayoutConstraint!

    private let toastShadowWrap = UIView()
    private var toastPill: UIVisualEffectView!
    private let toastIconView = UIImageView()
    private let toastLabel = UILabel()
    private var toastHideWorkItem: DispatchWorkItem?

    deinit {
        fgProtectTimer?.invalidate()
        toastHideWorkItem?.cancel()
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
        JWNotificationManager.shared.configure()
        JWNotificationManager.shared.onSelectSiteFromNotification = { [weak self] siteId in
            guard let self = self, let target = self.site(forId: siteId) else { return }
            if !target.enabled || target.hibernated {
                self.setSiteHibernated(siteId: siteId, hibernated: false)
            } else {
                self.selectSite(byId: siteId)
            }
        }
        JWNotificationManager.shared.onBackgroundListenWillStopForSuspend = { [weak self] in
            self?.armDetachedJetsamGuardForBackgroundTransition(reason: "notify-guard-ending")
        }
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

        if config.notificationsEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                JWNotificationManager.shared.requestPermissionIfNeeded()
            }
        }

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
        updateGlassChromeMaterials()
        if let prev = previousTraitCollection,
           traitCollection.hasDifferentColorAppearance(comparedTo: prev) {
            applyAppearanceStyles()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        clampFloatingPillPosition()
        if floatingShadowWrap.bounds.width > 0 {
            floatingShadowWrap.layer.shadowPath = UIBezierPath(
                roundedRect: floatingShadowWrap.bounds,
                cornerRadius: 19
            ).cgPath
        }
        if toastShadowWrap.bounds.width > 0 {
            toastShadowWrap.layer.shadowPath = UIBezierPath(
                roundedRect: toastShadowWrap.bounds,
                cornerRadius: 18
            ).cgPath
        }
        if emptyShadowWrap.bounds.width > 0 {
            emptyShadowWrap.layer.shadowPath = UIBezierPath(
                roundedRect: emptyShadowWrap.bounds,
                cornerRadius: 28
            ).cgPath
        }
        if hibernatedShadowWrap.bounds.width > 0 {
            hibernatedShadowWrap.layer.shadowPath = UIBezierPath(
                roundedRect: hibernatedShadowWrap.bounds,
                cornerRadius: 28
            ).cgPath
        }
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
            self?.updateGlassChromeMaterials()
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
        runtime.onTrimMemoryNow = { [weak self] in
            self?.triggerUserMemoryTrim()
        }
        runtime.onMemoryPolicyChanged = { [weak self] in
            guard let self = self else { return }
            let snap = self.currentLiveMemorySnapshot()
            self.detachIdleBackgroundWebViewsIfNeeded(totalMemoryMB: snap.totalMB, forceAllUnselected: false)
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
        runtime.onSendTestNotification = { [weak self] in
            self?.sendUserTestNotification()
        }
        runtime.onNotificationPolicyChanged = { [weak self] in
            guard let self = self else { return }
            if self.config.notificationsEnabled {
                JWNotificationManager.shared.requestPermissionIfNeeded()
            }
            self.rebuildTabPills()
        }
        runtime.buildDiagnosticHeader = { [weak self] in
            self?.buildDiagnosticHeaderText() ?? ""
        }
    }

    private func sendUserTestNotification() {
        JWNotificationManager.shared.requestPermissionIfNeeded { [weak self] granted in
            guard let self = self else { return }
            if !granted {
                let alert = UIAlertController(
                    title: "系统通知权限未开启",
                    message: "请在 iOS「设置 → 通知 → JetWeb」中允许通知，即可接收对话回复横幅与提示音。",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "取消", style: .cancel))
                alert.addAction(UIAlertAction(title: "前往系统设置", style: .default) { _ in
                    if let u = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(u, options: [:], completionHandler: nil)
                    }
                })
                self.topMostPresenter().present(alert, animated: true)
                return
            }
            let curSite = self.site(forId: self.config.selectedSiteId)
            JWNotificationManager.shared.postSiteNotification(
                siteId: curSite?.id ?? "",
                siteTitle: curSite?.title ?? "JetWeb",
                subtitle: "测试通知成功",
                body: "通知栏横幅与声音已就绪！当其他标签或后台网页（如 Muse / agy）完成回复时将自动提醒你。",
                isTest: true
            )
        }
    }

    // MARK: - UIKit Layout (Instant-Switch Web Container + Sculpted Glass Capsule Dock + Floating Island)

    private func makeIconButton(symbol: String, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
        btn.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
        btn.tintColor = .label
        btn.addTarget(self, action: action, for: .touchUpInside)
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 33),
            btn.heightAnchor.constraint(equalToConstant: 33)
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

        dockAmbientTintView.translatesAutoresizingMaskIntoConstraints = false
        dockAmbientTintView.isUserInteractionEnabled = false
        view.addSubview(dockAmbientTintView)

        dockBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        dockBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dockBar)

        dockTopHighlight.translatesAutoresizingMaskIntoConstraints = false
        dockTopHighlight.isUserInteractionEnabled = false
        dockBar.contentView.addSubview(dockTopHighlight)

        let barRow = UIView()
        barRow.translatesAutoresizingMaskIntoConstraints = false
        dockBar.contentView.addSubview(barRow)

        tabsTrayView.translatesAutoresizingMaskIntoConstraints = false
        tabsTrayView.layer.cornerRadius = 20
        tabsTrayView.layer.cornerCurve = .continuous
        tabsTrayView.clipsToBounds = true
        barRow.addSubview(tabsTrayView)

        tabsScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabsScrollView.showsHorizontalScrollIndicator = false
        tabsScrollView.showsVerticalScrollIndicator = false
        tabsScrollView.contentInsetAdjustmentBehavior = .never
        tabsScrollView.contentInset = UIEdgeInsets(top: 0, left: 3, bottom: 0, right: 3)
        tabsTrayView.addSubview(tabsScrollView)

        tabsStackView.translatesAutoresizingMaskIntoConstraints = false
        tabsStackView.axis = .horizontal
        tabsStackView.spacing = 6
        tabsStackView.alignment = .center
        tabsScrollView.addSubview(tabsStackView)

        toolsCapsuleView.translatesAutoresizingMaskIntoConstraints = false
        toolsCapsuleView.layer.cornerRadius = 19
        toolsCapsuleView.layer.cornerCurve = .continuous
        barRow.addSubview(toolsCapsuleView)

        let reloadBtn = makeIconButton(symbol: "arrow.clockwise", action: #selector(reloadCurrentSite))
        let settingsBtn = makeIconButton(symbol: "slider.horizontal.3", action: #selector(openManageSheet))
        let collapseBtn = makeIconButton(symbol: "chevron.down", action: #selector(collapseDockTapped))

        let rightTools = UIStackView(arrangedSubviews: [reloadBtn, settingsBtn, collapseBtn])
        rightTools.translatesAutoresizingMaskIntoConstraints = false
        rightTools.axis = .horizontal
        rightTools.spacing = 0
        rightTools.alignment = .center
        toolsCapsuleView.addSubview(rightTools)

        webBottomToDockConstraint = webContainerView.bottomAnchor.constraint(equalTo: dockBar.topAnchor)
        webBottomToViewConstraint = webContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)

        let hairline = 1.0 / UIScreen.main.scale

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

            dockAmbientTintView.topAnchor.constraint(equalTo: dockBar.topAnchor),
            dockAmbientTintView.leadingAnchor.constraint(equalTo: dockBar.leadingAnchor),
            dockAmbientTintView.trailingAnchor.constraint(equalTo: dockBar.trailingAnchor),
            dockAmbientTintView.bottomAnchor.constraint(equalTo: dockBar.bottomAnchor),

            dockTopHighlight.topAnchor.constraint(equalTo: dockBar.contentView.topAnchor),
            dockTopHighlight.leadingAnchor.constraint(equalTo: dockBar.contentView.leadingAnchor),
            dockTopHighlight.trailingAnchor.constraint(equalTo: dockBar.contentView.trailingAnchor),
            dockTopHighlight.heightAnchor.constraint(equalToConstant: hairline),

            barRow.topAnchor.constraint(equalTo: dockBar.contentView.topAnchor, constant: 4),
            barRow.leadingAnchor.constraint(equalTo: dockBar.contentView.leadingAnchor, constant: 10),
            barRow.trailingAnchor.constraint(equalTo: dockBar.contentView.trailingAnchor, constant: -10),
            barRow.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -2),
            barRow.heightAnchor.constraint(equalToConstant: 44),

            toolsCapsuleView.trailingAnchor.constraint(equalTo: barRow.trailingAnchor),
            toolsCapsuleView.centerYAnchor.constraint(equalTo: barRow.centerYAnchor),
            toolsCapsuleView.heightAnchor.constraint(equalToConstant: 38),

            rightTools.leadingAnchor.constraint(equalTo: toolsCapsuleView.leadingAnchor, constant: 3),
            rightTools.trailingAnchor.constraint(equalTo: toolsCapsuleView.trailingAnchor, constant: -3),
            rightTools.centerYAnchor.constraint(equalTo: toolsCapsuleView.centerYAnchor),

            tabsTrayView.leadingAnchor.constraint(equalTo: barRow.leadingAnchor),
            tabsTrayView.trailingAnchor.constraint(equalTo: toolsCapsuleView.leadingAnchor, constant: -8),
            tabsTrayView.centerYAnchor.constraint(equalTo: barRow.centerYAnchor),
            tabsTrayView.heightAnchor.constraint(equalToConstant: 40),

            tabsScrollView.leadingAnchor.constraint(equalTo: tabsTrayView.leadingAnchor),
            tabsScrollView.trailingAnchor.constraint(equalTo: tabsTrayView.trailingAnchor),
            tabsScrollView.topAnchor.constraint(equalTo: tabsTrayView.topAnchor),
            tabsScrollView.bottomAnchor.constraint(equalTo: tabsTrayView.bottomAnchor),

            tabsStackView.leadingAnchor.constraint(equalTo: tabsScrollView.contentLayoutGuide.leadingAnchor),
            tabsStackView.trailingAnchor.constraint(equalTo: tabsScrollView.contentLayoutGuide.trailingAnchor),
            tabsStackView.topAnchor.constraint(equalTo: tabsScrollView.contentLayoutGuide.topAnchor),
            tabsStackView.bottomAnchor.constraint(equalTo: tabsScrollView.contentLayoutGuide.bottomAnchor),
            tabsStackView.heightAnchor.constraint(equalTo: tabsScrollView.frameLayoutGuide.heightAnchor)
        ])

        setupEmptyGlassStateView()
        setupHibernatedGlassStateView()
        setupFloatingGlassIsland()
        setupTopGlassToast()
        updateGlassChromeMaterials()
    }

    private func setupEmptyGlassStateView() {
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.backgroundColor = .secondarySystemBackground
        webContainerView.addSubview(emptyStateView)

        let orbA = UIView()
        orbA.translatesAutoresizingMaskIntoConstraints = false
        orbA.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.11)
        orbA.layer.cornerRadius = 100
        orbA.isUserInteractionEnabled = false
        emptyStateView.addSubview(orbA)

        let orbB = UIView()
        orbB.translatesAutoresizingMaskIntoConstraints = false
        orbB.backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.10)
        orbB.layer.cornerRadius = 115
        orbB.isUserInteractionEnabled = false
        emptyStateView.addSubview(orbB)

        emptyShadowWrap.translatesAutoresizingMaskIntoConstraints = false
        emptyShadowWrap.layer.shadowColor = UIColor.black.cgColor
        emptyShadowWrap.layer.shadowOpacity = 0.10
        emptyShadowWrap.layer.shadowRadius = 24
        emptyShadowWrap.layer.shadowOffset = CGSize(width: 0, height: 8)
        emptyStateView.addSubview(emptyShadowWrap)

        emptyGlassCard.translatesAutoresizingMaskIntoConstraints = false
        emptyGlassCard.layer.cornerRadius = 28
        emptyGlassCard.layer.cornerCurve = .continuous
        emptyGlassCard.clipsToBounds = true
        emptyShadowWrap.addSubview(emptyGlassCard)

        let medallion = JWSquircleAvatarView(frame: .zero)
        medallion.configureWithSymbol(
            "square.stack.3d.up.fill",
            topColor: UIColor(red: 0.16, green: 0.49, blue: 0.98, alpha: 1.0),
            bottomColor: UIColor(red: 0.32, green: 0.28, blue: 0.90, alpha: 1.0),
            pointSize: 25
        )
        emptyGlassCard.contentView.addSubview(medallion)

        let emptyTitle = UILabel()
        emptyTitle.translatesAutoresizingMaskIntoConstraints = false
        emptyTitle.text = "JetWeb 常驻工作台"
        emptyTitle.font = .systemFont(ofSize: 20, weight: .bold)
        emptyTitle.textAlignment = .center
        emptyGlassCard.contentView.addSubview(emptyTitle)

        let emptySub = UILabel()
        emptySub.translatesAutoresizingMaskIntoConstraints = false
        emptySub.text = "将常用桌面级 WebApp 放进同一容器：\n0ms 秒切不白屏 · 独立多账号空间 · 分档保活与休眠"
        emptySub.font = .systemFont(ofSize: 13.5)
        emptySub.textColor = .secondaryLabel
        emptySub.numberOfLines = 0
        emptySub.textAlignment = .center
        emptyGlassCard.contentView.addSubview(emptySub)

        let addFirstBtn = UIButton(type: .system)
        addFirstBtn.translatesAutoresizingMaskIntoConstraints = false
        var btnCfg = UIButton.Configuration.filled()
        btnCfg.title = "添加第一个常驻 WebApp"
        btnCfg.image = UIImage(systemName: "plus.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        btnCfg.imagePadding = 6
        btnCfg.cornerStyle = .capsule
        btnCfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24)
        addFirstBtn.configuration = btnCfg
        addFirstBtn.addTarget(self, action: #selector(openManageSheet), for: .touchUpInside)
        emptyGlassCard.contentView.addSubview(addFirstBtn)

        NSLayoutConstraint.activate([
            emptyStateView.topAnchor.constraint(equalTo: webContainerView.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: webContainerView.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: webContainerView.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: webContainerView.bottomAnchor),

            orbA.widthAnchor.constraint(equalToConstant: 200),
            orbA.heightAnchor.constraint(equalToConstant: 200),
            orbA.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor, constant: -75),
            orbA.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor, constant: -95),

            orbB.widthAnchor.constraint(equalToConstant: 230),
            orbB.heightAnchor.constraint(equalToConstant: 230),
            orbB.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor, constant: 80),
            orbB.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor, constant: 95),

            emptyShadowWrap.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyShadowWrap.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor),
            emptyShadowWrap.leadingAnchor.constraint(greaterThanOrEqualTo: emptyStateView.leadingAnchor, constant: 24),
            emptyShadowWrap.trailingAnchor.constraint(lessThanOrEqualTo: emptyStateView.trailingAnchor, constant: -24),
            emptyShadowWrap.widthAnchor.constraint(lessThanOrEqualToConstant: 390),

            emptyGlassCard.topAnchor.constraint(equalTo: emptyShadowWrap.topAnchor),
            emptyGlassCard.leadingAnchor.constraint(equalTo: emptyShadowWrap.leadingAnchor),
            emptyGlassCard.trailingAnchor.constraint(equalTo: emptyShadowWrap.trailingAnchor),
            emptyGlassCard.bottomAnchor.constraint(equalTo: emptyShadowWrap.bottomAnchor),

            medallion.topAnchor.constraint(equalTo: emptyGlassCard.contentView.topAnchor, constant: 28),
            medallion.centerXAnchor.constraint(equalTo: emptyGlassCard.contentView.centerXAnchor),
            medallion.widthAnchor.constraint(equalToConstant: 58),
            medallion.heightAnchor.constraint(equalToConstant: 58),

            emptyTitle.topAnchor.constraint(equalTo: medallion.bottomAnchor, constant: 16),
            emptyTitle.leadingAnchor.constraint(equalTo: emptyGlassCard.contentView.leadingAnchor, constant: 22),
            emptyTitle.trailingAnchor.constraint(equalTo: emptyGlassCard.contentView.trailingAnchor, constant: -22),

            emptySub.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 9),
            emptySub.leadingAnchor.constraint(equalTo: emptyGlassCard.contentView.leadingAnchor, constant: 22),
            emptySub.trailingAnchor.constraint(equalTo: emptyGlassCard.contentView.trailingAnchor, constant: -22),

            addFirstBtn.topAnchor.constraint(equalTo: emptySub.bottomAnchor, constant: 22),
            addFirstBtn.centerXAnchor.constraint(equalTo: emptyGlassCard.contentView.centerXAnchor),
            addFirstBtn.bottomAnchor.constraint(equalTo: emptyGlassCard.contentView.bottomAnchor, constant: -26)
        ])
    }

    private func setupHibernatedGlassStateView() {
        hibernatedStateView.translatesAutoresizingMaskIntoConstraints = false
        hibernatedStateView.backgroundColor = .secondarySystemBackground
        hibernatedStateView.isHidden = true
        webContainerView.addSubview(hibernatedStateView)

        let orbA = UIView()
        orbA.translatesAutoresizingMaskIntoConstraints = false
        orbA.backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.12)
        orbA.layer.cornerRadius = 105
        orbA.isUserInteractionEnabled = false
        hibernatedStateView.addSubview(orbA)

        let orbB = UIView()
        orbB.translatesAutoresizingMaskIntoConstraints = false
        orbB.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.09)
        orbB.layer.cornerRadius = 115
        orbB.isUserInteractionEnabled = false
        hibernatedStateView.addSubview(orbB)

        hibernatedShadowWrap.translatesAutoresizingMaskIntoConstraints = false
        hibernatedShadowWrap.layer.shadowColor = UIColor.black.cgColor
        hibernatedShadowWrap.layer.shadowOpacity = 0.10
        hibernatedShadowWrap.layer.shadowRadius = 24
        hibernatedShadowWrap.layer.shadowOffset = CGSize(width: 0, height: 8)
        hibernatedStateView.addSubview(hibernatedShadowWrap)

        hibernatedGlassCard.translatesAutoresizingMaskIntoConstraints = false
        hibernatedGlassCard.layer.cornerRadius = 28
        hibernatedGlassCard.layer.cornerCurve = .continuous
        hibernatedGlassCard.clipsToBounds = true
        hibernatedShadowWrap.addSubview(hibernatedGlassCard)

        let medallion = JWSquircleAvatarView(frame: .zero)
        medallion.configureWithSymbol(
            "moon.zzz.fill",
            topColor: UIColor(red: 0.42, green: 0.35, blue: 0.95, alpha: 1.0),
            bottomColor: UIColor(red: 0.28, green: 0.22, blue: 0.78, alpha: 1.0),
            pointSize: 25
        )
        hibernatedGlassCard.contentView.addSubview(medallion)

        let zeroMemPill = UIView()
        zeroMemPill.translatesAutoresizingMaskIntoConstraints = false
        zeroMemPill.backgroundColor = JWGlassPalette.chipFill(for: .emerald)
        zeroMemPill.layer.cornerRadius = 10
        zeroMemPill.layer.cornerCurve = .continuous
        zeroMemPill.layer.borderWidth = 1.0 / UIScreen.main.scale
        zeroMemPill.layer.borderColor = JWGlassPalette.chipBorder(for: .emerald).cgColor
        hibernatedGlassCard.contentView.addSubview(zeroMemPill)

        let zeroMemLabel = UILabel()
        zeroMemLabel.translatesAutoresizingMaskIntoConstraints = false
        zeroMemLabel.text = "✓ 已释放网页内存 · 当前占用 0 MB"
        zeroMemLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .bold)
        zeroMemLabel.textColor = JWGlassPalette.foreground(for: .emerald)
        zeroMemPill.addSubview(zeroMemLabel)

        hibernatedTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        hibernatedTitleLabel.text = "标签已休眠"
        hibernatedTitleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        hibernatedTitleLabel.numberOfLines = 2
        hibernatedTitleLabel.textAlignment = .center
        hibernatedGlassCard.contentView.addSubview(hibernatedTitleLabel)

        hibernatedSubLabel.translatesAutoresizingMaskIntoConstraints = false
        hibernatedSubLabel.text = "已销毁该标签渲染进程并释放全部运行内存。\nCookie 与本地登录态完整保留，随时一键唤醒。"
        hibernatedSubLabel.font = .systemFont(ofSize: 13.5)
        hibernatedSubLabel.textColor = .secondaryLabel
        hibernatedSubLabel.numberOfLines = 0
        hibernatedSubLabel.textAlignment = .center
        hibernatedGlassCard.contentView.addSubview(hibernatedSubLabel)

        let wakeBtn = UIButton(type: .system)
        wakeBtn.translatesAutoresizingMaskIntoConstraints = false
        var wakeCfg = UIButton.Configuration.filled()
        wakeCfg.title = "立即唤醒并打开网页"
        wakeCfg.image = UIImage(systemName: "bolt.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        wakeCfg.imagePadding = 6
        wakeCfg.baseBackgroundColor = .systemIndigo
        wakeCfg.cornerStyle = .capsule
        wakeCfg.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24)
        wakeBtn.configuration = wakeCfg
        wakeBtn.addTarget(self, action: #selector(wakeSelectedSiteTapped), for: .touchUpInside)
        hibernatedGlassCard.contentView.addSubview(wakeBtn)

        let hibManageBtn = UIButton(type: .system)
        hibManageBtn.translatesAutoresizingMaskIntoConstraints = false
        var manageCfg = UIButton.Configuration.tinted()
        manageCfg.title = "打开工作台设置"
        manageCfg.baseBackgroundColor = .secondaryLabel
        manageCfg.baseForegroundColor = .label
        manageCfg.cornerStyle = .capsule
        manageCfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 18, bottom: 8, trailing: 18)
        hibManageBtn.configuration = manageCfg
        hibManageBtn.addTarget(self, action: #selector(openManageSheet), for: .touchUpInside)
        hibernatedGlassCard.contentView.addSubview(hibManageBtn)

        NSLayoutConstraint.activate([
            hibernatedStateView.topAnchor.constraint(equalTo: webContainerView.topAnchor),
            hibernatedStateView.leadingAnchor.constraint(equalTo: webContainerView.leadingAnchor),
            hibernatedStateView.trailingAnchor.constraint(equalTo: webContainerView.trailingAnchor),
            hibernatedStateView.bottomAnchor.constraint(equalTo: webContainerView.bottomAnchor),

            orbA.widthAnchor.constraint(equalToConstant: 210),
            orbA.heightAnchor.constraint(equalToConstant: 210),
            orbA.centerXAnchor.constraint(equalTo: hibernatedStateView.centerXAnchor, constant: -75),
            orbA.centerYAnchor.constraint(equalTo: hibernatedStateView.centerYAnchor, constant: -95),

            orbB.widthAnchor.constraint(equalToConstant: 230),
            orbB.heightAnchor.constraint(equalToConstant: 230),
            orbB.centerXAnchor.constraint(equalTo: hibernatedStateView.centerXAnchor, constant: 80),
            orbB.centerYAnchor.constraint(equalTo: hibernatedStateView.centerYAnchor, constant: 95),

            hibernatedShadowWrap.centerXAnchor.constraint(equalTo: hibernatedStateView.centerXAnchor),
            hibernatedShadowWrap.centerYAnchor.constraint(equalTo: hibernatedStateView.centerYAnchor),
            hibernatedShadowWrap.leadingAnchor.constraint(greaterThanOrEqualTo: hibernatedStateView.leadingAnchor, constant: 24),
            hibernatedShadowWrap.trailingAnchor.constraint(lessThanOrEqualTo: hibernatedStateView.trailingAnchor, constant: -24),
            hibernatedShadowWrap.widthAnchor.constraint(lessThanOrEqualToConstant: 396),

            hibernatedGlassCard.topAnchor.constraint(equalTo: hibernatedShadowWrap.topAnchor),
            hibernatedGlassCard.leadingAnchor.constraint(equalTo: hibernatedShadowWrap.leadingAnchor),
            hibernatedGlassCard.trailingAnchor.constraint(equalTo: hibernatedShadowWrap.trailingAnchor),
            hibernatedGlassCard.bottomAnchor.constraint(equalTo: hibernatedShadowWrap.bottomAnchor),

            medallion.topAnchor.constraint(equalTo: hibernatedGlassCard.contentView.topAnchor, constant: 26),
            medallion.centerXAnchor.constraint(equalTo: hibernatedGlassCard.contentView.centerXAnchor),
            medallion.widthAnchor.constraint(equalToConstant: 58),
            medallion.heightAnchor.constraint(equalToConstant: 58),

            zeroMemPill.topAnchor.constraint(equalTo: medallion.bottomAnchor, constant: 13),
            zeroMemPill.centerXAnchor.constraint(equalTo: hibernatedGlassCard.contentView.centerXAnchor),
            zeroMemLabel.topAnchor.constraint(equalTo: zeroMemPill.topAnchor, constant: 4),
            zeroMemLabel.bottomAnchor.constraint(equalTo: zeroMemPill.bottomAnchor, constant: -4),
            zeroMemLabel.leadingAnchor.constraint(equalTo: zeroMemPill.leadingAnchor, constant: 10),
            zeroMemLabel.trailingAnchor.constraint(equalTo: zeroMemPill.trailingAnchor, constant: -10),

            hibernatedTitleLabel.topAnchor.constraint(equalTo: zeroMemPill.bottomAnchor, constant: 11),
            hibernatedTitleLabel.leadingAnchor.constraint(equalTo: hibernatedGlassCard.contentView.leadingAnchor, constant: 22),
            hibernatedTitleLabel.trailingAnchor.constraint(equalTo: hibernatedGlassCard.contentView.trailingAnchor, constant: -22),

            hibernatedSubLabel.topAnchor.constraint(equalTo: hibernatedTitleLabel.bottomAnchor, constant: 8),
            hibernatedSubLabel.leadingAnchor.constraint(equalTo: hibernatedGlassCard.contentView.leadingAnchor, constant: 22),
            hibernatedSubLabel.trailingAnchor.constraint(equalTo: hibernatedGlassCard.contentView.trailingAnchor, constant: -22),

            wakeBtn.topAnchor.constraint(equalTo: hibernatedSubLabel.bottomAnchor, constant: 20),
            wakeBtn.centerXAnchor.constraint(equalTo: hibernatedGlassCard.contentView.centerXAnchor),

            hibManageBtn.topAnchor.constraint(equalTo: wakeBtn.bottomAnchor, constant: 10),
            hibManageBtn.centerXAnchor.constraint(equalTo: hibernatedGlassCard.contentView.centerXAnchor),
            hibManageBtn.bottomAnchor.constraint(equalTo: hibernatedGlassCard.contentView.bottomAnchor, constant: -24)
        ])
    }

    private func setupFloatingGlassIsland() {
        floatingShadowWrap.translatesAutoresizingMaskIntoConstraints = false
        floatingShadowWrap.layer.shadowColor = UIColor.black.cgColor
        floatingShadowWrap.layer.shadowOpacity = 0.16
        floatingShadowWrap.layer.shadowRadius = 14
        floatingShadowWrap.layer.shadowOffset = CGSize(width: 0, height: 5)
        floatingShadowWrap.isHidden = true
        view.addSubview(floatingShadowWrap)

        floatingPill = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        floatingPill.translatesAutoresizingMaskIntoConstraints = false
        floatingPill.layer.cornerRadius = 19
        floatingPill.layer.cornerCurve = .continuous
        floatingPill.clipsToBounds = true
        floatingShadowWrap.addSubview(floatingPill)

        floatingDotView.translatesAutoresizingMaskIntoConstraints = false
        floatingDotView.layer.cornerRadius = 3.75
        floatingDotView.backgroundColor = .systemGreen
        floatingDotView.isUserInteractionEnabled = false

        floatingLabel.translatesAutoresizingMaskIntoConstraints = false
        floatingLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        floatingLabel.textColor = .label
        floatingLabel.lineBreakMode = .byTruncatingTail
        floatingLabel.text = "展开底栏"

        let expandChevron = UIImageView(
            image: UIImage(
                systemName: "chevron.up",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 10.5, weight: .bold)
            )
        )
        expandChevron.tintColor = .secondaryLabel
        expandChevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        let pillStack = UIStackView(arrangedSubviews: [floatingDotView, floatingLabel, expandChevron])
        pillStack.translatesAutoresizingMaskIntoConstraints = false
        pillStack.axis = .horizontal
        pillStack.alignment = .center
        pillStack.spacing = 6.5
        pillStack.isUserInteractionEnabled = false
        floatingPill.contentView.addSubview(pillStack)

        floatingTrailingConstraint = floatingShadowWrap.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14)
        floatingBottomConstraint = floatingShadowWrap.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18)

        NSLayoutConstraint.activate([
            floatingTrailingConstraint,
            floatingBottomConstraint,
            floatingShadowWrap.heightAnchor.constraint(equalToConstant: 38),
            floatingShadowWrap.widthAnchor.constraint(lessThanOrEqualToConstant: 196),

            floatingPill.topAnchor.constraint(equalTo: floatingShadowWrap.topAnchor),
            floatingPill.leadingAnchor.constraint(equalTo: floatingShadowWrap.leadingAnchor),
            floatingPill.trailingAnchor.constraint(equalTo: floatingShadowWrap.trailingAnchor),
            floatingPill.bottomAnchor.constraint(equalTo: floatingShadowWrap.bottomAnchor),

            floatingDotView.widthAnchor.constraint(equalToConstant: 7.5),
            floatingDotView.heightAnchor.constraint(equalToConstant: 7.5),

            pillStack.leadingAnchor.constraint(equalTo: floatingPill.contentView.leadingAnchor, constant: 13),
            pillStack.trailingAnchor.constraint(equalTo: floatingPill.contentView.trailingAnchor, constant: -12),
            pillStack.centerYAnchor.constraint(equalTo: floatingPill.contentView.centerYAnchor)
        ])

        let tapExpand = UITapGestureRecognizer(target: self, action: #selector(expandDockTapped))
        floatingPill.addGestureRecognizer(tapExpand)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(floatingPillLongPressed(_:)))
        longPress.minimumPressDuration = 0.4
        floatingPill.addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(floatingPillPanned(_:)))
        floatingPill.addGestureRecognizer(pan)
    }

    private func setupTopGlassToast() {
        toastShadowWrap.translatesAutoresizingMaskIntoConstraints = false
        toastShadowWrap.layer.shadowColor = UIColor.black.cgColor
        toastShadowWrap.layer.shadowOpacity = 0.16
        toastShadowWrap.layer.shadowRadius = 14
        toastShadowWrap.layer.shadowOffset = CGSize(width: 0, height: 5)
        toastShadowWrap.alpha = 0
        toastShadowWrap.isHidden = true
        toastShadowWrap.isUserInteractionEnabled = false
        view.addSubview(toastShadowWrap)

        toastPill = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        toastPill.translatesAutoresizingMaskIntoConstraints = false
        toastPill.layer.cornerRadius = 18
        toastPill.layer.cornerCurve = .continuous
        toastPill.clipsToBounds = true
        toastShadowWrap.addSubview(toastPill)

        toastIconView.translatesAutoresizingMaskIntoConstraints = false
        toastIconView.contentMode = .scaleAspectFit
        toastIconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        toastLabel.textColor = .label
        toastLabel.numberOfLines = 1
        toastLabel.lineBreakMode = .byTruncatingTail

        let hStack = UIStackView(arrangedSubviews: [toastIconView, toastLabel])
        hStack.translatesAutoresizingMaskIntoConstraints = false
        hStack.axis = .horizontal
        hStack.alignment = .center
        hStack.spacing = 6.5
        toastPill.contentView.addSubview(hStack)

        NSLayoutConstraint.activate([
            toastShadowWrap.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            toastShadowWrap.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastShadowWrap.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            toastShadowWrap.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            toastShadowWrap.heightAnchor.constraint(equalToConstant: 36),

            toastPill.topAnchor.constraint(equalTo: toastShadowWrap.topAnchor),
            toastPill.leadingAnchor.constraint(equalTo: toastShadowWrap.leadingAnchor),
            toastPill.trailingAnchor.constraint(equalTo: toastShadowWrap.trailingAnchor),
            toastPill.bottomAnchor.constraint(equalTo: toastShadowWrap.bottomAnchor),

            toastIconView.widthAnchor.constraint(equalToConstant: 15),
            toastIconView.heightAnchor.constraint(equalToConstant: 15),

            hStack.leadingAnchor.constraint(equalTo: toastPill.contentView.leadingAnchor, constant: 13),
            hStack.trailingAnchor.constraint(equalTo: toastPill.contentView.trailingAnchor, constant: -14),
            hStack.centerYAnchor.constraint(equalTo: toastPill.contentView.centerYAnchor)
        ])
    }

    private func showTopGlassToast(symbol: String, tint: UIColor, text: String) {
        toastHideWorkItem?.cancel()
        let cfg = UIImage.SymbolConfiguration(pointSize: 12.5, weight: .bold)
        toastIconView.image = UIImage(systemName: symbol, withConfiguration: cfg)
        toastIconView.tintColor = JWGlassPalette.foreground(for: JWGlassPalette.role(for: tint))
        toastLabel.text = text

        view.bringSubviewToFront(toastShadowWrap)
        if toastShadowWrap.isHidden {
            toastShadowWrap.transform = CGAffineTransform(translationX: 0, y: -18)
            toastShadowWrap.alpha = 0
            toastShadowWrap.isHidden = false
        }
        UIView.animate(
            withDuration: 0.26,
            delay: 0,
            usingSpringWithDamping: 0.84,
            initialSpringVelocity: 0.5,
            options: [.beginFromCurrentState, .curveEaseOut]
        ) {
            self.toastShadowWrap.alpha = 1.0
            self.toastShadowWrap.transform = .identity
        }

        let hideWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
                self.toastShadowWrap.alpha = 0
                self.toastShadowWrap.transform = CGAffineTransform(translationX: 0, y: -14)
            } completion: { finished in
                if finished && self.toastShadowWrap.alpha < 0.05 {
                    self.toastShadowWrap.isHidden = true
                }
            }
        }
        toastHideWorkItem = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: hideWork)
    }

    private func updateGlassChromeMaterials() {
        let effTrait = view.window?.traitCollection ?? traitCollection
        let isDark = (overrideUserInterfaceStyle == .dark)
            || (overrideUserInterfaceStyle == .unspecified && effTrait.userInterfaceStyle == .dark)
        let hairline = 1.0 / UIScreen.main.scale

        dockAmbientTintView.backgroundColor = isDark
            ? UIColor(red: 0.08, green: 0.10, blue: 0.18, alpha: 0.45)
            : UIColor(red: 0.90, green: 0.93, blue: 0.99, alpha: 0.65)
        dockTopHighlight.backgroundColor = isDark
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.white.withAlphaComponent(0.75)

        tabsTrayView.backgroundColor = isDark
            ? UIColor.white.withAlphaComponent(0.06)
            : UIColor.black.withAlphaComponent(0.045)
        tabsTrayView.layer.borderWidth = hairline
        tabsTrayView.layer.borderColor = (isDark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor.white.withAlphaComponent(0.65)).cgColor

        toolsCapsuleView.backgroundColor = isDark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.white.withAlphaComponent(0.70)
        toolsCapsuleView.layer.borderWidth = hairline
        toolsCapsuleView.layer.borderColor = (isDark
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.white.withAlphaComponent(0.72)).cgColor

        let cardBorder = (isDark
            ? UIColor.white.withAlphaComponent(0.16)
            : UIColor.white.withAlphaComponent(0.68)).cgColor
        emptyGlassCard.layer.borderWidth = hairline
        emptyGlassCard.layer.borderColor = cardBorder
        hibernatedGlassCard.layer.borderWidth = hairline
        hibernatedGlassCard.layer.borderColor = cardBorder

        let pillBorder = (isDark
            ? UIColor.white.withAlphaComponent(0.20)
            : UIColor.white.withAlphaComponent(0.75)).cgColor
        floatingPill.layer.borderWidth = hairline
        floatingPill.layer.borderColor = pillBorder
        toastPill?.layer.borderWidth = hairline
        toastPill?.layer.borderColor = pillBorder
    }

    private func updateFloatingIslandVisuals() {
        let enabled = enabledSites()
        guard !enabled.isEmpty else {
            floatingLabel.text = "展开底栏"
            floatingDotView.backgroundColor = .systemBlue
            return
        }
        let hasOtherUnread = enabled.contains { $0.id != config.selectedSiteId && unreadSiteIds.contains($0.id) && !$0.hibernated }
        if let cur = site(forId: config.selectedSiteId) {
            floatingLabel.text = cur.title
            if hasOtherUnread {
                floatingDotView.backgroundColor = .systemRed
            } else if cur.hibernated {
                floatingDotView.backgroundColor = .systemIndigo
            } else {
                floatingDotView.backgroundColor = .systemGreen
            }
        } else {
            floatingLabel.text = "展开底栏"
            floatingDotView.backgroundColor = hasOtherUnread ? .systemRed : .systemGreen
        }
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
        cfg.userContentController.addUserScript(WebScripts.scrollAnchorStabilizerScript())
        cfg.userContentController.addUserScript(WebScripts.diagnosticJSErrorScript())
        cfg.userContentController.addUserScript(WebScripts.conversationMonitorScript())
        cfg.userContentController.addUserScript(WebScripts.memoryReliefHelperScript())
        cfg.userContentController.add(WeakScriptMessageProxy(target: self), name: "jwDiag")
        cfg.userContentController.add(WeakScriptMessageProxy(target: self), name: "jwNotify")

        let wv = WKWebView(frame: webContainerView.bounds, configuration: cfg)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4 Mobile/15E148 Safari/604.1"

        let capturedId = site.id
        lastActiveUptimeBySiteId[capturedId] = ProcessInfo.processInfo.systemUptime
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

        attachWebViewIfNeeded(wv, forSiteId: capturedId)

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

    private func snapshotRememberedURLIfNeeded(forSiteId siteId: String) {
        guard !siteId.isEmpty,
              let curURL = webViews[siteId]?.url,
              let scheme = curURL.scheme?.lowercased(),
              (scheme == "http" || scheme == "https") else { return }
        lastKnownURLBySiteId[siteId] = curURL.absoluteString
    }

    private func attachWebViewIfNeeded(_ wv: WKWebView, forSiteId siteId: String) {
        if wv.superview !== webContainerView {
            if webContainerView.bounds.width > 0 && webContainerView.bounds.height > 0 {
                wv.frame = webContainerView.bounds
            }
            webContainerView.insertSubview(wv, belowSubview: emptyStateView)
            NSLayoutConstraint.activate([
                wv.topAnchor.constraint(equalTo: webContainerView.topAnchor),
                wv.leadingAnchor.constraint(equalTo: webContainerView.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: webContainerView.trailingAnchor),
                wv.bottomAnchor.constraint(equalTo: webContainerView.bottomAnchor)
            ])
            webContainerView.layoutIfNeeded()
        }
        detachedSiteIds.remove(siteId)
    }

    @discardableResult
    private func detachWebViewFromWindow(siteId: String, reason: String) -> Bool {
        guard siteId != config.selectedSiteId,
              let wv = webViews[siteId],
              wv.superview != nil else { return false }
        snapshotRememberedURLIfNeeded(forSiteId: siteId)
        wv.isUserInteractionEnabled = false
        wv.isHidden = true
        wv.removeFromSuperview()
        detachedSiteIds.insert(siteId)
        let title = site(forId: siteId)?.title ?? siteId
        JWLog("MEM-TRIM", "Detached off-screen WebView from window site=\(title) reason=\(reason)")
        return true
    }

    private func detachIdleBackgroundWebViewsIfNeeded(totalMemoryMB: Int, forceAllUnselected: Bool) {
        if !forceAllUnselected && config.idleDetachSeconds <= 0 {
            if !detachedSiteIds.isEmpty {
                for s in awakeSites() {
                    if let wv = webViews[s.id], wv.superview == nil {
                        attachWebViewIfNeeded(wv, forSiteId: s.id)
                        wv.isHidden = (s.id != config.selectedSiteId)
                        wv.isUserInteractionEnabled = (s.id == config.selectedSiteId)
                    }
                }
            }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let baseIdle = TimeInterval(max(15, config.idleDetachSeconds))
        var detachedAny = false

        for s in awakeSites() where s.id != config.selectedSiteId {
            guard let wv = webViews[s.id], wv.superview != nil, !wv.isLoading else { continue }
            if !forceAllUnselected {
                if let stAt = lastStreamingUptimeBySiteId[s.id], (now - stAt) < 75.0 {
                    continue
                }
                let pid = JWBridgeWebViewContentPID(wv)
                let tabMB = (pid > 0) ? max(0, lastProcStatuses[pid]?.footprintMB ?? 0) : 0
                let isNotifySite = config.notificationsEnabled && s.notifyEnabled
                if isNotifySite && totalMemoryMB < 720 && tabMB < 260 {
                    continue
                }
                let requiredIdle = isNotifySite ? max(baseIdle, 75.0) : baseIdle
                let lastActive = lastActiveUptimeBySiteId[s.id] ?? now
                if (now - lastActive) < requiredIdle {
                    continue
                }
            }
            if detachWebViewFromWindow(siteId: s.id, reason: forceAllUnselected ? "force" : "idle-\(Int(baseIdle))s") {
                detachedAny = true
            }
        }

        if detachedAny && !forceAllUnselected && UIApplication.shared.applicationState == .active {
            schedulePostStateChangeProtectionWaves()
        }
    }

    private func teardownWebView(forSiteId siteId: String) {
        guard let old = webViews[siteId] else { return }
        old.stopLoading()
        old.configuration.userContentController.removeScriptMessageHandler(forName: "jwDiag")
        old.configuration.userContentController.removeScriptMessageHandler(forName: "jwNotify")
        progressObservations.removeValue(forKey: siteId)?.invalidate()
        urlObservations.removeValue(forKey: siteId)?.invalidate()
        old.navigationDelegate = nil
        old.uiDelegate = nil
        old.removeFromSuperview()
        webViews.removeValue(forKey: siteId)
        webViewStoreIds.removeValue(forKey: siteId)
        errorOverlays.removeValue(forKey: siteId)
        terminatedSiteIds.remove(siteId)
        detachedSiteIds.remove(siteId)
        unreadSiteIds.remove(siteId)
        lastActiveUptimeBySiteId.removeValue(forKey: siteId)
        lastStreamingUptimeBySiteId.removeValue(forKey: siteId)
        lastRejectedAuthBySiteId.removeValue(forKey: siteId)
    }

    private func syncAllWebViewHostStates(appActive: Bool) {
        let activeLiteral = appActive ? "true" : "false"
        for (sid, wv) in webViews {
            let selLiteral = (sid == config.selectedSiteId) ? "true" : "false"
            let js = "if(window.__jwUpdateHostState)window.__jwUpdateHostState({appActive:\(activeLiteral),tabSelected:\(selLiteral)});"
            wv.evaluateJavaScript(js, in: nil, in: .page, completionHandler: nil)
        }
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
            updateFloatingIslandVisuals()
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
        let now = ProcessInfo.processInfo.systemUptime
        let prevSelectedId = config.selectedSiteId
        if !prevSelectedId.isEmpty && prevSelectedId != siteId {
            lastActiveUptimeBySiteId[prevSelectedId] = now
        }
        lastActiveUptimeBySiteId[siteId] = now
        config.selectedSiteId = siteId
        unreadSiteIds.remove(siteId)
        config.save()

        if let targetWV = webViews[siteId], !curSite.hibernated {
            hibernatedStateView.isHidden = true
            attachWebViewIfNeeded(targetWV, forSiteId: siteId)
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
        } else {
            for (_, wv) in webViews {
                wv.isHidden = true
                wv.isUserInteractionEnabled = false
            }
            progressView.isHidden = true
            let spaceLabel = JWDataStoreHelper.label(for: curSite.dataStoreId)
            let tierText = JWPriorityHelper.tierDescription(customBand: curSite.customBand, globalBand: config.targetBand)
            hibernatedTitleLabel.text = "\(curSite.title) 已休眠"
            hibernatedSubLabel.text = "已销毁该标签渲染进程并释放全部运行内存。\n登录空间（\(spaceLabel)）与保活预设（\(tierText)）完整保留。"
            hibernatedStateView.isHidden = false
            webContainerView.bringSubviewToFront(hibernatedStateView)
        }

        updateFloatingIslandVisuals()

        let isAppActive = (UIApplication.shared.applicationState == .active)
        syncAllWebViewHostStates(appActive: isAppActive)

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

        snapshotRememberedURLIfNeeded(forSiteId: siteId)
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
                snapshotRememberedURLIfNeeded(forSiteId: config.sites[i].id)
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
            snapshotRememberedURLIfNeeded(forSiteId: config.sites[i].id)
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
                customBand: JWPriorityHelper.normalizeCustomBand(s.customBand),
                unread: unreadSiteIds.contains(s.id)
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

    private func toggleSiteNotify(siteId: String) {
        guard let idx = config.sites.firstIndex(where: { $0.id == siteId }) else { return }
        config.sites[idx].notifyEnabled.toggle()
        let enabled = config.sites[idx].notifyEnabled
        if enabled {
            config.notificationsEnabled = true
            JWNotificationManager.shared.requestPermissionIfNeeded()
        }
        config.save()
        JWLog("NOTIFY", "Toggled site=\(config.sites[idx].title) notifyEnabled=\(enabled)")
        rebuildTabPills()
    }

    private func presentGlassSheet(_ sheet: JWGlassSheetController) {
        guard view.window != nil, presentedViewController == nil else { return }
        let globalMode = JWAppearanceHelper.normalizeGlobal(config.appearanceMode)
        sheet.overrideUserInterfaceStyle = JWAppearanceHelper.uiStyle(for: globalMode, fallback: .unspecified)
        present(sheet, animated: false)
    }

    private func buildSiteStatusChips(for targetSite: SiteItem) -> [JWGlassChipItem] {
        var chips: [JWGlassChipItem] = []
        let effBand = config.effectiveSiteBand(for: targetSite)
        let wpid = JWBridgeWebViewContentPID(webViews[targetSite.id])
        let st = (wpid > 0) ? lastProcStatuses[wpid] : nil

        if targetSite.hibernated {
            chips.append(JWGlassChipItem(symbol: "moon.zzz.fill", text: "已休眠 · 0 MB", tint: .systemIndigo))
        } else if let st = st {
            let memTint: UIColor = st.footprintMB > config.maxMemoryMB ? .systemOrange : .systemGreen
            chips.append(JWGlassChipItem(symbol: "memorychip", text: "\(st.footprintMB) MB", tint: memTint))
        }

        let bandTint: UIColor = effBand >= 86 ? .systemOrange : .systemBlue
        let bandText = targetSite.customBand > 0 ? "专属 \(effBand) 档" : "默认 \(effBand) 档"
        chips.append(JWGlassChipItem(symbol: "bolt.shield.fill", text: bandText, tint: bandTint))

        if targetSite.isIsolatedStore {
            chips.append(JWGlassChipItem(symbol: "lock.shield.fill", text: "独立空间", tint: .systemTeal))
        } else {
            chips.append(JWGlassChipItem(symbol: "person.2.fill", text: "共享空间", tint: .secondaryLabel))
        }
        return chips
    }

    private func showTabLongPressMenu(for targetSite: SiteItem, sourceView: UIView?) {
        let effBand = config.effectiveSiteBand(for: targetSite)
        let tierText = JWPriorityHelper.tierDescription(customBand: targetSite.customBand, globalBand: config.targetBand)
        let notifyOn = config.notificationsEnabled && targetSite.notifyEnabled

        let tiles: [JWGlassTileItem] = [
            JWGlassTileItem(
                symbol: targetSite.hibernated ? "bolt.fill" : "moon.zzz.fill",
                title: targetSite.hibernated ? "立即唤醒" : "休眠释放",
                subtitle: targetSite.hibernated ? "恢复加载" : "降至 0 MB",
                tint: .systemIndigo,
                isActive: targetSite.hibernated
            ) { [weak self] in
                self?.setSiteHibernated(siteId: targetSite.id, hibernated: !targetSite.hibernated)
            },
            JWGlassTileItem(
                symbol: "bolt.shield.fill",
                title: "保活 \(effBand) 档",
                subtitle: targetSite.customBand > 0 ? "专属档位" : "跟随全局",
                tint: .systemBlue,
                isActive: targetSite.customBand > 0
            ) { [weak self] in
                self?.showQuickPriorityPicker(for: targetSite, sourceView: sourceView)
            },
            JWGlassTileItem(
                symbol: notifyOn ? "bell.badge.fill" : "bell.slash.fill",
                title: notifyOn ? "通知已开" : "通知已关",
                subtitle: "点击切换",
                tint: .systemTeal,
                isActive: notifyOn
            ) { [weak self] in
                self?.toggleSiteNotify(siteId: targetSite.id)
            },
            JWGlassTileItem(
                symbol: "person.crop.circle.badge.plus",
                title: "账号分身",
                subtitle: "独立登录",
                tint: .systemPurple,
                isActive: false
            ) { [weak self] in
                self?.promptCloneIsolatedSite(from: targetSite)
            }
        ]

        var hibGroup: [JWGlassRowItem] = []
        if !awakeSites().isEmpty {
            let snap = currentLiveMemorySnapshot()
            hibGroup.append(JWGlassRowItem(
                symbol: "wand.and.stars",
                tint: .systemTeal,
                title: "一键无损内存瘦身",
                trailingText: snap.totalMB > 0 ? "不重载 · \(snap.totalMB) MB" : "不重载网页"
            ) { [weak self] in
                self?.triggerUserMemoryTrim()
            })
        }
        let otherAwakeCount = awakeSites().filter { $0.id != targetSite.id }.count
        if otherAwakeCount > 0 {
            hibGroup.append(JWGlassRowItem(
                symbol: "sparkles",
                tint: .systemBlue,
                title: "休眠其他 \(otherAwakeCount) 个标签",
                trailingText: "仅留此页"
            ) { [weak self] in
                self?.hibernateOtherSites(keepingSiteId: targetSite.id)
            })
        }
        if awakeSites().count >= 2 {
            hibGroup.append(JWGlassRowItem(
                symbol: "powersleep",
                tint: .systemPurple,
                title: "全部标签一键休眠",
                trailingText: "清空网页内存"
            ) { [weak self] in
                self?.hibernateAllSites()
            })
        }

        let configGroup: [JWGlassRowItem] = [
            JWGlassRowItem(
                symbol: "bolt.shield.fill",
                tint: .systemBlue,
                title: "进程保活等级",
                trailingText: tierText,
                showsChevron: true
            ) { [weak self] in
                self?.showQuickPriorityPicker(for: targetSite, sourceView: sourceView)
            },
            JWGlassRowItem(
                symbol: "lock.shield.fill",
                tint: .systemTeal,
                title: "账号存储空间",
                trailingText: targetSite.isIsolatedStore ? "独立空间" : "默认共享",
                showsChevron: true
            ) { [weak self] in
                self?.showQuickAccountSpacePicker(for: targetSite, sourceView: sourceView)
            },
            JWGlassRowItem(
                symbol: "circle.lefthalf.filled",
                tint: .systemIndigo,
                title: "站点外观模式",
                trailingText: JWAppearanceHelper.label(for: targetSite.appearanceMode),
                showsChevron: true
            ) { [weak self] in
                self?.showQuickAppearancePicker(for: targetSite, sourceView: sourceView)
            },
            JWGlassRowItem(
                symbol: "eye.slash",
                tint: .secondaryLabel,
                title: "从底栏暂时隐藏",
                trailingText: "设置可恢复"
            ) { [weak self] in
                guard let self = self,
                      let idx = self.config.sites.firstIndex(where: { $0.id == targetSite.id }) else { return }
                self.config.sites[idx].enabled = false
                self.config.save()
                JWLog("SITE", "Hid site from dock site=\(targetSite.title)")
                self.syncWebViewsWithConfig(preferredSelectId: nil)
                self.applyDockCollapsedState(animated: false)
            },
            JWGlassRowItem(
                symbol: "trash",
                title: "彻底删除此站点…",
                isDestructive: true
            ) { [weak self] in
                self?.confirmDeleteSite(targetSite)
            }
        ]

        let sheet = JWGlassSheetController(
            icon: .siteTitle(targetSite.title),
            title: targetSite.title,
            chips: buildSiteStatusChips(for: targetSite),
            tiles: tiles,
            sections: [hibGroup, configGroup]
        )
        presentGlassSheet(sheet)
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

        let presets: [(band: Int, symbol: String, tint: UIColor, title: String, sub: String)] = [
            (0, "bolt.shield.fill", .systemBlue, "跟随全局默认", "\(clampedGlobal) 档"),
            (JWConstants.bandPresetCore, "flame.fill", .systemOrange, "核心常驻（最后回收）", "88 档"),
            (JWConstants.bandPresetFrequent, "star.fill", .systemYellow, "常用保活（高优常驻）", "80 档"),
            (JWConstants.bandPresetSecondary, "pin.fill", .systemTeal, "次要备选（优先让路）", "70 档"),
            (JWConstants.bandPresetDisposable, "leaf.fill", .systemGreen, "随用随清（内存紧先清）", "35 档")
        ]

        let presetRows: [JWGlassRowItem] = presets.map { p in
            JWGlassRowItem(
                symbol: p.symbol,
                tint: p.tint,
                title: p.title,
                trailingText: p.sub,
                isSelected: curNorm == p.band
            ) { [weak self] in
                self?.applyUpdatedSiteCustomBand(siteId: site.id, newCustomBand: p.band)
            }
        }

        let isCustomOther = curNorm > 0 && !presets.contains(where: { $0.band == curNorm })
        let customRow = JWGlassRowItem(
            symbol: "slider.horizontal.3",
            tint: .systemIndigo,
            title: isCustomOther ? "自定义精确档位（点击修改）" : "手动输入精确档位 (30~92)…",
            trailingText: isCustomOther ? "\(curNorm) 档" : "",
            isSelected: isCustomOther,
            showsChevron: !isCustomOther
        ) { [weak self] in
            self?.promptCustomBandInput(for: site)
        }

        let sheet = JWGlassSheetController(
            icon: .symbol(
                name: "bolt.shield.fill",
                top: UIColor(red: 0.16, green: 0.49, blue: 0.98, alpha: 1.0),
                bottom: UIColor(red: 0.30, green: 0.28, blue: 0.90, alpha: 1.0)
            ),
            title: "\(site.title) · 保活等级",
            subtitle: "内存吃紧按档位从低到高回收 · 网络与主进程自动 +1/+2 压阵",
            sections: [presetRows, [customRow]]
        )
        presentGlassSheet(sheet)
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
        let cur = JWAppearanceHelper.normalizeSite(site.appearanceMode)
        let options: [(mode: String, symbol: String, tint: UIColor)] = [
            (JWConstants.appearanceInherit, "sparkles", .systemBlue),
            (JWConstants.appearanceSystem, "circle.lefthalf.filled", .systemTeal),
            (JWConstants.appearanceLight, "sun.max.fill", .systemOrange),
            (JWConstants.appearanceDark, "moon.stars.fill", .systemIndigo)
        ]

        let rows: [JWGlassRowItem] = options.map { opt in
            JWGlassRowItem(
                symbol: opt.symbol,
                tint: opt.tint,
                title: JWAppearanceHelper.label(for: opt.mode),
                isSelected: opt.mode == cur
            ) { [weak self] in
                guard let self = self,
                      let idx = self.config.sites.firstIndex(where: { $0.id == site.id }) else { return }
                self.config.sites[idx].appearanceMode = opt.mode
                self.config.save()
                self.applyAppearanceStyles()
                self.updateGlassChromeMaterials()
            }
        }

        let sheet = JWGlassSheetController(
            icon: .symbol(
                name: "circle.lefthalf.filled",
                top: UIColor(red: 0.42, green: 0.35, blue: 0.95, alpha: 1.0),
                bottom: UIColor(red: 0.18, green: 0.52, blue: 0.94, alpha: 1.0)
            ),
            title: "\(site.title) · 外观模式",
            subtitle: "遇到深色模式下输入框对比度异常时，可切换为「强制浅色」立即生效",
            sections: [rows]
        )
        presentGlassSheet(sheet)
    }

    private func showQuickAccountSpacePicker(for site: SiteItem, sourceView: UIView?) {
        let isIso = site.isIsolatedStore
        let mainRows: [JWGlassRowItem] = [
            JWGlassRowItem(
                symbol: "lock.shield.fill",
                tint: .systemTeal,
                title: "独立账号空间",
                trailingText: isIso ? "当前使用" : "可登录新账号",
                isSelected: isIso
            ) { [weak self] in
                guard let self = self, !isIso,
                      let idx = self.config.sites.firstIndex(where: { $0.id == site.id }) else { return }
                self.config.sites[idx].dataStoreId = UUID().uuidString
                self.config.save()
                JWLog("STORE", "Quick-switched site=\(site.title) to isolated store")
                self.syncWebViewsWithConfig(preferredSelectId: site.id)
            },
            JWGlassRowItem(
                symbol: "person.2.fill",
                tint: .systemBlue,
                title: "默认共享空间",
                trailingText: !isIso ? "当前使用" : "共用默认登录态",
                isSelected: !isIso
            ) { [weak self] in
                guard let self = self, isIso,
                      let idx = self.config.sites.firstIndex(where: { $0.id == site.id }) else { return }
                self.config.sites[idx].dataStoreId = JWConstants.dataStoreDefault
                self.config.save()
                JWLog("STORE", "Switched site=\(site.title) back to default store")
                self.syncWebViewsWithConfig(preferredSelectId: site.id)
            }
        ]

        var sections: [[JWGlassRowItem]] = [mainRows]
        if isIso {
            sections.append([
                JWGlassRowItem(
                    symbol: "arrow.triangle.2.circlepath",
                    title: "重置为全新独立账号空间（换另一新号）",
                    isDestructive: true
                ) { [weak self] in
                    guard let self = self,
                          let idx = self.config.sites.firstIndex(where: { $0.id == site.id }) else { return }
                    self.config.sites[idx].dataStoreId = UUID().uuidString
                    self.config.save()
                    JWLog("STORE", "Rotated isolated store for site=\(site.title)")
                    self.syncWebViewsWithConfig(preferredSelectId: site.id)
                }
            ])
        }

        let sheet = JWGlassSheetController(
            icon: .symbol(
                name: "lock.shield.fill",
                top: UIColor(red: 0.08, green: 0.68, blue: 0.62, alpha: 1.0),
                bottom: UIColor(red: 0.06, green: 0.46, blue: 0.68, alpha: 1.0)
            ),
            title: "\(site.title) · 账号空间",
            subtitle: "独立账号空间拥有专属 Cookie 与缓存，同网站登录多号互不串号",
            sections: sections
        )
        presentGlassSheet(sheet)
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
                hibernated: false,
                notifyEnabled: site.notifyEnabled
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
        let spaceLabel = curSite.isIsolatedStore ? "独立空间" : "默认共享"
        let tierText = JWPriorityHelper.tierDescription(customBand: curSite.customBand, globalBand: config.targetBand)
        let curURLStr = wv.url?.absoluteString ?? curSite.urlString
        let notifyOn = config.notificationsEnabled && curSite.notifyEnabled

        let navTiles: [JWGlassTileItem] = [
            JWGlassTileItem(
                symbol: "chevron.backward",
                title: "后退",
                isEnabled: wv.canGoBack
            ) { [weak wv] in
                wv?.goBack()
            },
            JWGlassTileItem(
                symbol: "chevron.forward",
                title: "前进",
                isEnabled: wv.canGoForward
            ) { [weak wv] in
                wv?.goForward()
            },
            JWGlassTileItem(
                symbol: "arrow.clockwise",
                title: "刷新页面",
                tint: .systemBlue
            ) { [weak self] in
                self?.reloadSiteFromHomeOrCurrent(siteId: siteId, forceHome: false)
            },
            JWGlassTileItem(
                symbol: "safari.fill",
                title: "浏览器打开",
                tint: .systemTeal
            ) {
                if let targetURL = URL(string: curURLStr) {
                    UIApplication.shared.open(targetURL, options: [:], completionHandler: nil)
                }
            }
        ]

        let snap = currentLiveMemorySnapshot()
        let trimTrail = snap.totalMB > 0 ? "不重载 · \(snap.totalMB) MB" : "不重载网页"
        let pageGroup: [JWGlassRowItem] = [
            JWGlassRowItem(
                symbol: "house.fill",
                tint: .systemBlue,
                title: "回到站点初始首页"
            ) { [weak self] in
                self?.reloadSiteFromHomeOrCurrent(siteId: siteId, forceHome: true)
            },
            JWGlassRowItem(
                symbol: "doc.on.doc",
                tint: .systemTeal,
                title: "复制当前页面网址"
            ) {
                UIPasteboard.general.string = curURLStr
            },
            JWGlassRowItem(
                symbol: "wand.and.stars",
                tint: .systemTeal,
                title: "一键无损内存瘦身",
                trailingText: trimTrail
            ) { [weak self] in
                self?.triggerUserMemoryTrim()
            },
            JWGlassRowItem(
                symbol: "moon.zzz.fill",
                tint: .systemIndigo,
                title: "休眠释放此标签",
                trailingText: "保留登录态"
            ) { [weak self] in
                self?.setSiteHibernated(siteId: siteId, hibernated: true)
            }
        ]

        let sitePolicyGroup: [JWGlassRowItem] = [
            JWGlassRowItem(
                symbol: "bolt.shield.fill",
                tint: .systemBlue,
                title: "进程保活等级",
                trailingText: tierText,
                showsChevron: true
            ) { [weak self] in
                self?.showQuickPriorityPicker(for: curSite, sourceView: sourceView)
            },
            JWGlassRowItem(
                symbol: notifyOn ? "bell.badge.fill" : "bell.slash.fill",
                tint: notifyOn ? .systemTeal : .secondaryLabel,
                title: "新消息系统通知",
                trailingText: notifyOn ? "已开启" : "已关闭"
            ) { [weak self] in
                self?.toggleSiteNotify(siteId: siteId)
            },
            JWGlassRowItem(
                symbol: "lock.shield.fill",
                tint: .systemTeal,
                title: "账号存储空间",
                trailingText: spaceLabel,
                showsChevron: true
            ) { [weak self] in
                self?.showQuickAccountSpacePicker(for: curSite, sourceView: sourceView)
            },
            JWGlassRowItem(
                symbol: "person.crop.circle.badge.plus",
                tint: .systemPurple,
                title: "复制为独立新账号分身"
            ) { [weak self] in
                self?.promptCloneIsolatedSite(from: curSite)
            },
            JWGlassRowItem(
                symbol: "circle.lefthalf.filled",
                tint: .systemIndigo,
                title: "外观模式",
                trailingText: JWAppearanceHelper.label(for: curSite.appearanceMode),
                showsChevron: true
            ) { [weak self] in
                self?.showQuickAppearancePicker(for: curSite, sourceView: sourceView)
            }
        ]

        let diagGroup: [JWGlassRowItem] = [
            JWGlassRowItem(
                symbol: "doc.text.magnifyingglass",
                tint: .secondaryLabel,
                title: "查看运行与诊断日志"
            ) { [weak self] in
                self?.openLogViewerSheet()
            },
            JWGlassRowItem(
                symbol: "trash",
                title: "退出并清理此标签登录态",
                isDestructive: true
            ) { [weak self] in
                self?.clearDataForSite(siteId: siteId)
            }
        ]

        let sheet = JWGlassSheetController(
            icon: .siteTitle(curSite.title),
            title: curSite.title,
            subtitle: curURLStr,
            chips: buildSiteStatusChips(for: curSite),
            tiles: navTiles,
            sections: [pageGroup, sitePolicyGroup, diagGroup]
        )
        presentGlassSheet(sheet)
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
        dockAmbientTintView.isHidden = collapsed
        floatingShadowWrap.isHidden = !collapsed
        updateFloatingIslandVisuals()
        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
                self.view.layoutIfNeeded()
            }
        }
    }

    @objc private func floatingPillLongPressed(_ gr: UILongPressGestureRecognizer) {
        guard gr.state == .began else { return }

        let siteRows: [JWGlassRowItem] = enabledSites().map { s in
            let isSel = (s.id == config.selectedSiteId)
            let isUnread = unreadSiteIds.contains(s.id) && !isSel && !s.hibernated
            let effBand = config.effectiveSiteBand(for: s)
            let wpid = JWBridgeWebViewContentPID(webViews[s.id])
            let mb = (wpid > 0) ? (lastProcStatuses[wpid]?.footprintMB ?? 0) : 0

            let symbol: String
            let tint: UIColor
            let trail: String
            if s.hibernated {
                symbol = "moon.zzz.fill"
                tint = .systemIndigo
                trail = "休眠 · 0 MB"
            } else if isUnread {
                symbol = "bell.badge.fill"
                tint = .systemRed
                trail = "有新消息"
            } else {
                symbol = "globe"
                tint = isSel ? .systemBlue : .systemGreen
                trail = mb > 0 ? "\(mb) MB · \(effBand)档" : "\(effBand) 档"
            }

            return JWGlassRowItem(
                symbol: symbol,
                tint: tint,
                title: s.title,
                trailingText: trail,
                isSelected: isSel
            ) { [weak self] in
                if s.hibernated {
                    self?.setSiteHibernated(siteId: s.id, hibernated: false)
                } else {
                    self?.selectSite(byId: s.id)
                }
            }
        }

        let toolTiles: [JWGlassTileItem] = [
            JWGlassTileItem(
                symbol: "chevron.up",
                title: "展开底栏",
                tint: .systemBlue
            ) { [weak self] in
                self?.expandDockTapped()
            },
            JWGlassTileItem(
                symbol: "wand.and.stars",
                title: "无损瘦身",
                tint: .systemTeal,
                isEnabled: !awakeSites().isEmpty && !isTrimmingMemory
            ) { [weak self] in
                self?.triggerUserMemoryTrim()
            },
            JWGlassTileItem(
                symbol: "slider.horizontal.3",
                title: "工作台设置",
                tint: .systemIndigo
            ) { [weak self] in
                self?.openManageSheet()
            },
            JWGlassTileItem(
                symbol: "doc.text.magnifyingglass",
                title: "诊断日志",
                tint: .secondaryLabel
            ) { [weak self] in
                self?.openLogViewerSheet()
            }
        ]

        var sections: [[JWGlassRowItem]] = [siteRows]
        if let cur = site(forId: config.selectedSiteId), cur.enabled && !cur.hibernated {
            sections.append([
                JWGlassRowItem(
                    symbol: "moon.zzz.fill",
                    tint: .systemIndigo,
                    title: "休眠释放当前标签",
                    trailingText: "保留登录态"
                ) { [weak self] in
                    self?.setSiteHibernated(siteId: cur.id, hibernated: true)
                }
            ])
        }

        let sheet = JWGlassSheetController(
            icon: .symbol(
                name: "square.stack.3d.up.fill",
                top: UIColor(red: 0.16, green: 0.49, blue: 0.98, alpha: 1.0),
                bottom: UIColor(red: 0.32, green: 0.28, blue: 0.90, alpha: 1.0)
            ),
            title: "快速切换常驻 WebApp",
            subtitle: "点击秒切 · 无损瘦身不重载",
            tiles: toolTiles,
            sections: sections
        )
        presentGlassSheet(sheet)
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
        let notifySummary = config.notificationsEnabled
            ? "开启(护航\(config.bgNotifyGuardMinutes)m\(config.bgAutoSleepAfterNotify ? "/回完休眠" : ""))"
            : "关闭"

        var lines: [String] = []
        lines.append("=== JetWeb 诊断摘要 ===")
        let detachDesc = config.idleDetachSeconds > 0 ? "\(config.idleDetachSeconds)s" : "关闭"
        lines.append("版本: v\(JWBridgeVersion()) (\(JWBridgeGitCommit())) | 系统: \(dev.systemName) \(dev.systemVersion) | 物理内存: \(ramMB) MB")
        lines.append("策略: 全局默认 \(config.targetBand) 档 (网络压阵 \(guardian.auxBand) 档 / 主容器 \(guardian.hostBand) 档) | 单页上限 \(config.maxMemoryMB) MB | 自动脱水: \(config.autoMemoryTrimEnabled ? "开" : "关") | 离屏省显存: \(detachDesc) | 告警休眠: \(config.autoHibernateOnCriticalMemory ? "开" : "关") | 通知: \(notifySummary) | 外观: \(config.appearanceMode)")
        lines.append("主进程: PID \(selfPid) | 实测档位 \(hostSt?.band ?? -1) | 内存 \(hostSt?.footprintMB ?? 0) MB")

        for s in config.sites {
            let wv = webViews[s.id]
            let wpid = JWBridgeWebViewContentPID(wv)
            let npid = JWBridgeWebViewNetworkingPID(wv)
            let gpid = JWBridgeWebViewGPUPID(wv)
            let st = (wpid > 0) ? lastProcStatuses[wpid] : nil
            let stateLabel = !s.enabled ? "隐藏" : (s.hibernated ? "已休眠" : (detachedSiteIds.contains(s.id) ? "离屏保活" : "运行中"))
            let effBand = config.effectiveSiteBand(for: s)
            let bandLabel = s.customBand > 0 ? "专属\(effBand)档" : "默认\(effBand)档"
            let notifyBadge = s.notifyEnabled ? "🔔" : "🔕"
            let recMark = terminatedSiteIds.contains(s.id) ? " [曾被回收]" : ""
            lines.append("站点[\(stateLabel)]: \(s.title) \(notifyBadge) | \(bandLabel) | \(JWDataStoreHelper.shortBadge(for: s.dataStoreId)) | WebPID=\(wpid) NetPID=\(npid) GPUPID=\(gpid) | 实测=\(st?.band ?? -1)档 内存=\(st?.footprintMB ?? 0)MB\(recMark)")
        }
        lines.append("======================")
        return lines.joined(separator: "\n")
    }

    // MARK: - Jetsam Protection Engine, Lossless Memory Trim & Detached Background Guard

    private func currentLiveMemorySnapshot() -> (totalMB: Int, maxAwakeTabMB: Int, maxBgTabMB: Int) {
        let selfPid = getpid()
        var total = max(0, lastProcStatuses[selfPid]?.footprintMB ?? 0)
        var maxTab = 0
        var maxBg = 0
        for s in awakeSites() {
            let pid = JWBridgeWebViewContentPID(webViews[s.id])
            let mb = (pid > 0) ? max(0, lastProcStatuses[pid]?.footprintMB ?? 0) : 0
            total += mb
            if mb > maxTab { maxTab = mb }
            if s.id != config.selectedSiteId && mb > maxBg {
                maxBg = mb
            }
        }
        return (total, maxTab, maxBg)
    }

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
            self.scheduleApplyProtectionAsync { [weak self] _ in
                self?.evaluateProactiveMemoryMaintenanceOnMainThread()
            }
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

    // MARK: - Active Lossless Memory Relief & Emergency LRU Self-Rescue

    private func triggerUserMemoryTrim() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        performMemoryTrim(deep: true, reason: "user-manual", showFeedbackToast: true, completion: nil)
    }

    private func performMemoryTrim(
        deep: Bool,
        reason: String,
        showFeedbackToast: Bool,
        completion: ((MemoryTrimSummary?) -> Void)?
    ) {
        guard !isTrimmingMemory else {
            completion?(nil)
            return
        }
        isTrimmingMemory = true

        if deep && config.idleDetachSeconds > 0 {
            detachIdleBackgroundWebViewsIfNeeded(
                totalMemoryMB: 9999,
                forceAllUnselected: (reason == "mem-warning")
            )
        }

        let aggLiteral = deep ? "true" : "false"
        let suspendBgMedia = deep && (reason == "mem-warning")
        for (sid, wv) in webViews {
            let isHiddenTab = (sid != config.selectedSiteId)
            let hidLiteral = isHiddenTab ? "true" : "false"
            let js = "if(window.__jwTrimPageMemory)window.__jwTrimPageMemory({aggressive:\(aggLiteral),hiddenTab:\(hidLiteral)});"
            wv.evaluateJavaScript(js, in: nil, in: .page, completionHandler: nil)
            JWBridgeTrimWebViewMemory(wv, deep, suspendBgMedia && isHiddenTab)
        }
        JWBridgeReleaseHostMemory()

        let preSnap = currentLiveMemorySnapshot()
        let collected = collectTargetPIDStringsOnMainThread()
        let band = config.targetBand
        let maxMB = config.maxMemoryMB
        let modeArg = deep ? "deep" : "gentle"

        protectQueue.async { [weak self] in
            HubViewController.writeSharedSnapshotOnBgQueue(collected.sharedSnapshot)

            var trimArgs = ["--trim", modeArg]
            trimArgs.append(contentsOf: collected.queryPIDs)
            var trimCode: Int32 = -1
            let trimOut = JWBridgeRunJetWebCtl(trimArgs, &trimCode)
            let trimSummary = MemoryTrimSummary.parseHelperOutput(trimOut)
            let trimStatuses = ProcStatus.parseHelperOutput(trimOut)

            var applyArgs = ["--apply", "\(band)", "\(maxMB)"]
            applyArgs.append(contentsOf: collected.applySpecs)
            var applyCode: Int32 = -1
            let applyOut = JWBridgeRunJetWebCtl(applyArgs, &applyCode)
            let applyStatuses = ProcStatus.parseHelperOutput(applyOut)

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isTrimmingMemory = false

                if !applyStatuses.isEmpty {
                    self.lastProcStatuses = applyStatuses
                } else if !trimStatuses.isEmpty {
                    self.lastProcStatuses = trimStatuses
                }
                self.rebuildTabPills()

                let postSnap = self.currentLiveMemorySnapshot()
                let beforeMB = trimSummary?.beforeMB ?? preSnap.totalMB
                let afterMB = trimSummary?.afterMB ?? postSnap.totalMB
                let savedMB = max(0, trimSummary?.savedMB ?? (beforeMB - afterMB))

                JWLog("MEM-TRIM", "mode=\(modeArg) reason=\(reason) rc=\(trimCode)/\(applyCode) before=\(beforeMB)MB after=\(afterMB)MB saved=\(savedMB)MB")

                let banner: String
                if trimCode == 0 {
                    if savedMB > 0 {
                        banner = "✓ 无损内存瘦身完成：释放 \(savedMB) MB（\(beforeMB) → \(afterMB) MB · 网页零重载）"
                    } else {
                        banner = "✓ 已完成内存紧致整理（当前总占用 \(afterMB) MB · 网页零重载）"
                    }
                } else {
                    banner = "✓ 已执行 WebKit 缓存与垃圾回收（总占用 \(afterMB) MB）"
                }
                self.runtime.helperBannerText = banner

                if showFeedbackToast {
                    let toastText = savedMB > 0
                        ? "已无损释放 \(savedMB) MB · 当前 \(afterMB) MB"
                        : "内存已整理紧致 · 当前 \(afterMB) MB"
                    self.showTopGlassToast(symbol: "wand.and.stars", tint: .systemTeal, text: toastText)
                }

                let resolved = trimSummary ?? MemoryTrimSummary(
                    mode: modeArg,
                    beforeMB: beforeMB,
                    afterMB: afterMB,
                    savedMB: savedMB,
                    count: collected.queryPIDs.count
                )
                completion?(resolved)
            }
        }
    }

    private func evaluateProactiveMemoryMaintenanceOnMainThread() {
        let snap = currentLiveMemorySnapshot()
        detachIdleBackgroundWebViewsIfNeeded(totalMemoryMB: snap.totalMB, forceAllUnselected: false)

        guard config.autoMemoryTrimEnabled, !isTrimmingMemory else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let softTabMB = max(210, Int(Double(config.maxMemoryMB) * 0.72))

        if (snap.maxBgTabMB > config.maxMemoryMB || snap.totalMB >= 1120) && (now - lastAutoDeepTrimUptime) >= 90.0 {
            lastAutoDeepTrimUptime = now
            lastAutoTrimUptime = now
            performMemoryTrim(
                deep: true,
                reason: "patrol-high(\(snap.totalMB)MB)",
                showFeedbackToast: false,
                completion: nil
            )
        } else if (snap.maxAwakeTabMB >= softTabMB || snap.totalMB >= 820) && (now - lastAutoTrimUptime) >= 55.0 {
            lastAutoTrimUptime = now
            performMemoryTrim(
                deep: false,
                reason: "patrol-soft(\(snap.totalMB)MB)",
                showFeedbackToast: false,
                completion: nil
            )
        }
    }

    private func evaluateEmergencyAutoHibernateAfterWarning(
        trimSummary: MemoryTrimSummary?,
        isRepeatedWarning: Bool,
        detachedCount: Int
    ) {
        let postSnap = currentLiveMemorySnapshot()
        let savedByTrim = max(0, trimSummary?.savedMB ?? 0)
        let candidates = awakeSites().filter { $0.id != config.selectedSiteId }

        let criticalTotalCap = max(860, config.maxMemoryMB * 2)
        let hasOverLimitBgTab = candidates.contains { s in
            let pid = JWBridgeWebViewContentPID(webViews[s.id])
            return pid > 0 && (lastProcStatuses[pid]?.footprintMB ?? 0) > config.maxMemoryMB
        }
        let needEvict = config.autoHibernateOnCriticalMemory
            && !candidates.isEmpty
            && (postSnap.totalMB > criticalTotalCap || hasOverLimitBgTab || (isRepeatedWarning && postSnap.totalMB > 560))

        guard needEvict else {
            JWLog("MEM-TRIM", "Memory warning absorbed by lossless trim (saved=\(savedByTrim)MB after=\(postSnap.totalMB)MB detached=\(detachedCount))")
            if UIApplication.shared.applicationState == .active && savedByTrim > 0 {
                showTopGlassToast(
                    symbol: "bolt.shield.fill",
                    tint: .systemTeal,
                    text: "内存吃紧：已无损释放 \(savedByTrim) MB 保住全部标签"
                )
            }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let sortedCandidates = candidates.sorted { a, b in
            let pidA = JWBridgeWebViewContentPID(webViews[a.id])
            let pidB = JWBridgeWebViewContentPID(webViews[b.id])
            let mbA = (pidA > 0) ? (lastProcStatuses[pidA]?.footprintMB ?? 0) : 0
            let mbB = (pidB > 0) ? (lastProcStatuses[pidB]?.footprintMB ?? 0) : 0

            let overA = mbA > config.maxMemoryMB
            let overB = mbB > config.maxMemoryMB
            if overA != overB { return overA && !overB }

            let streamA = (now - (lastStreamingUptimeBySiteId[a.id] ?? 0)) < 45.0
            let streamB = (now - (lastStreamingUptimeBySiteId[b.id] ?? 0)) < 45.0
            if streamA != streamB { return !streamA && streamB }

            let bandA = config.effectiveSiteBand(for: a)
            let bandB = config.effectiveSiteBand(for: b)
            if bandA != bandB { return bandA < bandB }

            let activeA = lastActiveUptimeBySiteId[a.id] ?? 0
            let activeB = lastActiveUptimeBySiteId[b.id] ?? 0
            if abs(activeA - activeB) > 1.0 { return activeA < activeB }

            return mbA > mbB
        }

        var projectedMB = postSnap.totalMB
        let targetSafeMB = max(680, Int(Double(criticalTotalCap) * 0.76))
        var evictedTitles: [String] = []
        var evictedMB = 0

        for victim in sortedCandidates {
            if evictedTitles.count >= 2 { break }
            if evictedTitles.count >= 1 && projectedMB <= targetSafeMB { break }
            guard let idx = config.sites.firstIndex(where: { $0.id == victim.id }) else { continue }

            snapshotRememberedURLIfNeeded(forSiteId: victim.id)
            let vPid = JWBridgeWebViewContentPID(webViews[victim.id])
            let vMB = (vPid > 0) ? max(0, lastProcStatuses[vPid]?.footprintMB ?? 0) : 0
            config.sites[idx].hibernated = true
            evictedTitles.append(victim.title)
            evictedMB += vMB
            projectedMB = max(0, projectedMB - vMB)
        }

        guard !evictedTitles.isEmpty else { return }
        config.save()
        let joinedNames = evictedTitles.joined(separator: "、")
        let totalSaved = savedByTrim + evictedMB
        JWLog("MEM-WARN", "Emergency self-rescue auto-hibernated [\(joinedNames)] freeing ~\(evictedMB)MB (trim+\(savedByTrim)MB) to protect active tab")
        syncWebViewsWithConfig(preferredSelectId: config.selectedSiteId)

        let rescueMsg = "🛡 内存自救：已自动休眠「\(joinedNames)」释放 \(max(evictedMB, totalSaved)) MB，保住当前页"
        runtime.helperBannerText = rescueMsg
        if UIApplication.shared.applicationState == .active {
            showTopGlassToast(symbol: "exclamationmark.shield.fill", tint: .systemOrange, text: rescueMsg)
        }
    }

    private func armDetachedJetsamGuardForBackgroundTransition(reason: String) {
        endBackgroundGuardTask()

        bgEpoch &+= 1
        let epoch = bgEpoch
        writeBgEpochToken(epoch)
        JWLog("BG", "Arming detached Jetsam guard reason=\(reason) epoch=\(epoch)")

        bgTask = UIApplication.shared.beginBackgroundTask(withName: "com.lili.jetweb.jetsamguard") { [weak self] in
            JWLog("BG", "UIBackgroundTask expired by system")
            self?.endBackgroundGuardTask()
        }

        let now = ProcessInfo.processInfo.systemUptime
        let snap = currentLiveMemorySnapshot()
        let shouldTrimBeforeBg = (reason == "enter-bg")
            && config.autoMemoryTrimEnabled
            && !awakeSites().isEmpty
            && (now - lastAutoTrimUptime) >= 15.0

        if shouldTrimBeforeBg {
            let useDeepBgTrim = (snap.totalMB >= 650 || snap.maxAwakeTabMB >= 300)
            lastAutoTrimUptime = now
            if useDeepBgTrim { lastAutoDeepTrimUptime = now }

            let aggLit = useDeepBgTrim ? "true" : "false"
            for (sid, wv) in webViews {
                let hidLit = (sid != config.selectedSiteId) ? "true" : "false"
                let js = "if(window.__jwTrimPageMemory)window.__jwTrimPageMemory({aggressive:\(aggLit),hiddenTab:\(hidLit)});"
                wv.evaluateJavaScript(js, in: nil, in: .page, completionHandler: nil)
                JWBridgeTrimWebViewMemory(wv, useDeepBgTrim, false)
            }
            JWBridgeReleaseHostMemory()

            let trimPIDs = collectTargetPIDStringsOnMainThread().queryPIDs
            let modeStr = useDeepBgTrim ? "deep" : "gentle"
            protectQueue.async { [weak self] in
                var trimArgs = ["--trim", modeStr]
                trimArgs.append(contentsOf: trimPIDs)
                var trimCode: Int32 = -1
                let trimOut = JWBridgeRunJetWebCtl(trimArgs, &trimCode)
                if let sum = MemoryTrimSummary.parseHelperOutput(trimOut) {
                    DispatchQueue.main.async {
                        JWLog("MEM-TRIM", "pre-bg mode=\(modeStr) before=\(sum.beforeMB)MB after=\(sum.afterMB)MB saved=\(sum.savedMB)MB")
                        let parsed = ProcStatus.parseHelperOutput(trimOut)
                        if !parsed.isEmpty {
                            self?.lastProcStatuses = parsed
                        }
                    }
                }
            }
        }

        scheduleApplyProtectionAsync(completion: nil)

        let guardSpawnDelay: TimeInterval = shouldTrimBeforeBg ? 0.85 : 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + guardSpawnDelay) { [weak self] in
            guard let self = self, self.bgEpoch == epoch else { return }
            let collected = self.collectTargetPIDStringsOnMainThread()
            let band = self.config.targetBand
            let maxMB = self.config.maxMemoryMB
            let epochPath = AppConfig.effectiveBgEpochPath()
            let logArg = self.config.debugLoggingEnabled ? JWLogger.logFilePath : "-"
            JWLog("BG", "Spawning detached --bg-guard reason=\(reason) epoch=\(epoch) specs=[\(collected.applySpecs.joined(separator: ","))]")

            self.protectQueue.async { [weak self] in
                HubViewController.writeSharedSnapshotOnBgQueue(collected.sharedSnapshot)
                JWBridgeSpawnDetachedBgGuard(band, maxMB, epochPath, epoch, logArg, collected.applySpecs)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self = self, self.bgEpoch == epoch else { return }
                    JWLog("BG", "Releasing UIBackgroundTask (reason=\(reason) epoch=\(epoch))")
                    self.endBackgroundGuardTask()
                }
            }
        }
    }

    @objc private func appDidEnterBackground() {
        stopForegroundProtectTimer()
        syncAllWebViewHostStates(appActive: false)

        if config.idleDetachSeconds > 0 {
            let now = ProcessInfo.processInfo.systemUptime
            for s in awakeSites() where s.id != config.selectedSiteId {
                let isNotifyActive = config.notificationsEnabled && s.notifyEnabled && config.bgNotifyGuardMinutes > 0
                let isStreaming = (now - (lastStreamingUptimeBySiteId[s.id] ?? 0)) < 60.0
                if !isNotifyActive && !isStreaming {
                    detachWebViewFromWindow(siteId: s.id, reason: "enter-bg")
                }
            }
        }

        if config.hasAwakeNotifySite() && config.bgNotifyGuardMinutes > 0 {
            JWNotificationManager.shared.startBackgroundListening(
                minutes: config.bgNotifyGuardMinutes,
                autoSleepAfterNotify: config.bgAutoSleepAfterNotify
            )
        } else {
            JWNotificationManager.shared.stopBackgroundListening(
                reason: "no_awake_notify_site",
                triggerJetsamGuard: false
            )
        }

        armDetachedJetsamGuardForBackgroundTransition(reason: "enter-bg")
    }

    @objc private func appWillEnterForeground() {
        JWNotificationManager.shared.stopBackgroundListening(
            reason: "entered_foreground",
            triggerJetsamGuard: false
        )
        bgEpoch &+= 1
        writeBgEpochToken(bgEpoch)
        endBackgroundGuardTask()
        unreadSiteIds.remove(config.selectedSiteId)
        if !config.selectedSiteId.isEmpty {
            lastActiveUptimeBySiteId[config.selectedSiteId] = ProcessInfo.processInfo.systemUptime
            if let curWV = webViews[config.selectedSiteId] {
                attachWebViewIfNeeded(curWV, forSiteId: config.selectedSiteId)
            }
        }
        updateFloatingIslandVisuals()
        JWLog("FG", "WillEnterForeground newEpoch=\(bgEpoch) terminatedCount=\(terminatedSiteIds.count) detachedCount=\(detachedSiteIds.count)")
        applyAppearanceStyles()
        recoverWebViewIfTerminated(siteId: config.selectedSiteId)
        syncAllWebViewHostStates(appActive: true)
        rebuildTabPills()
        startForegroundProtectTimer()
        schedulePostStateChangeProtectionWaves()
    }

    @objc private func appDidReceiveMemoryWarning() {
        let now = ProcessInfo.processInfo.systemUptime
        let isRepeatedWarning = (lastMemWarningUptime > 0 && (now - lastMemWarningUptime) < 25.0)
        lastMemWarningUptime = now

        let hibCount = enabledSites().filter { $0.hibernated }.count
        let items = awakeSites().map { s -> String in
            let wpid = JWBridgeWebViewContentPID(webViews[s.id])
            let mb = (wpid > 0) ? (lastProcStatuses[wpid]?.footprintMB ?? 0) : 0
            let eff = config.effectiveSiteBand(for: s)
            return "\(s.title)(\(wpid):\(mb)MB@\(eff))"
        }
        JWLog("MEM-WARN", "System memory warning (repeated=\(isRepeatedWarning))! awake=[\(items.joined(separator: ", "))] hibernated=\(hibCount)")

        // Stage 1: Detach all non-selected WebViews from window to immediately free off-screen layer surfaces
        var detachedCount = 0
        for s in awakeSites() where s.id != config.selectedSiteId {
            if detachWebViewFromWindow(siteId: s.id, reason: "mem-warning") {
                detachedCount += 1
            }
        }
        JWBridgeReleaseHostMemory()

        // Stage 2 & 3: Deep lossless WebKit trim -> LRU lowest-band emergency hibernation if still critical
        performMemoryTrim(deep: true, reason: "mem-warning", showFeedbackToast: false) { [weak self] summary in
            guard let self = self else { return }
            self.evaluateEmergencyAutoHibernateAfterWarning(
                trimSummary: summary,
                isRepeatedWarning: isRepeatedWarning,
                detachedCount: detachedCount
            )
        }
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
        if message.name == "jwDiag" {
            guard config.debugLoggingEnabled,
                  let dict = message.body as? [String: Any] else { return }
            let kind = (dict["k"] as? String) ?? "err"
            var msg = (dict["m"] as? String) ?? ""
            guard !msg.isEmpty else { return }
            if msg.count > 220 {
                msg = String(msg.prefix(220)) + "..."
            }
            let title = siteId(for: message.webView).flatMap { site(forId: $0)?.title } ?? "?"
            JWLog("JS-ERR", "site=\(title) (\(kind)) \(msg)")
            return
        }

        if message.name == "jwNotify" {
            guard let dict = message.body as? [String: Any],
                  let sid = siteId(for: message.webView),
                  let senderSite = site(forId: sid) else { return }
            let kind = (dict["k"] as? String) ?? ""
            if kind == "user_sent" {
                let now = ProcessInfo.processInfo.systemUptime
                lastStreamingUptimeBySiteId[sid] = now
                lastActiveUptimeBySiteId[sid] = now
                JWLog("NOTIFY", "User submitted message in site=\(senderSite.title)")
                return
            }
            if kind == "streaming" {
                lastStreamingUptimeBySiteId[sid] = ProcessInfo.processInfo.systemUptime
                JWNotificationManager.shared.noteSiteStreamingActivity()
                return
            }
            guard kind == "reply_done" || kind == "unread_dot" || kind == "web_api" || kind == "title_badge" else {
                return
            }
            guard config.notificationsEnabled,
                  senderSite.notifyEnabled,
                  senderSite.enabled,
                  !senderSite.hibernated else { return }

            let isActivelyViewing = (UIApplication.shared.applicationState == .active && sid == config.selectedSiteId)
            guard !isActivelyViewing else { return }

            let sub = (dict["sub"] as? String) ?? "收到新消息"
            let body = (dict["body"] as? String) ?? "有新的对话回复待查看"

            if sid != config.selectedSiteId {
                unreadSiteIds.insert(sid)
                rebuildTabPills()
                updateFloatingIslandVisuals()
            }

            JWNotificationManager.shared.postSiteNotification(
                siteId: sid,
                siteTitle: senderSite.title,
                subtitle: sub,
                body: body
            )
        }
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
        syncAllWebViewHostStates(appActive: UIApplication.shared.applicationState == .active)
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

    private static func rootDomain(of url: URL?) -> String {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return "" }
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return host }
        let twoPartSLDs: Set<String> = ["co", "com", "org", "net", "gov", "edu", "ac"]
        if parts.count >= 3,
           parts[parts.count - 1].count == 2,
           twoPartSLDs.contains(parts[parts.count - 2]) {
            return parts.suffix(3).joined(separator: ".")
        }
        return parts.suffix(2).joined(separator: ".")
    }

    private static func isLikelyOAuthFlow(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let authHosts: Set<String> = [
            "accounts.google.com",
            "appleid.apple.com",
            "login.microsoftonline.com",
            "login.live.com"
        ]
        if authHosts.contains(host) || host.contains("auth0.com") || host.contains("clerk.") {
            return true
        }
        let pathAndQuery = ((url.path) + "?" + (url.query ?? "")).lowercased()
        if pathAndQuery.contains("/oauth") ||
            pathAndQuery.contains("client_id=") ||
            pathAndQuery.contains("redirect_uri=") ||
            pathAndQuery.contains("/sso/") {
            return true
        }
        return false
    }

    private func shouldPromptExternalLink(url: URL, for webView: WKWebView) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https") else { return false }
        let targetRoot = HubViewController.rootDomain(of: url)
        guard !targetRoot.isEmpty else { return false }
        if HubViewController.isLikelyOAuthFlow(url) {
            return false
        }
        let curRoot = HubViewController.rootDomain(of: webView.url)
        let configuredStr = siteId(for: webView).flatMap { site(forId: $0)?.urlString } ?? ""
        let homeRoot = HubViewController.rootDomain(of: URL(string: configuredStr))

        if !curRoot.isEmpty && targetRoot == curRoot {
            return false
        }
        if !homeRoot.isEmpty && targetRoot == homeRoot {
            return false
        }
        return !curRoot.isEmpty || !homeRoot.isEmpty
    }

    private func presentExternalLinkActionSheet(url: URL, for webView: WKWebView) {
        guard view.window != nil, presentedViewController == nil else {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }
        let hostLabel = url.host ?? "外部链接"

        let tiles: [JWGlassTileItem] = [
            JWGlassTileItem(
                symbol: "safari.fill",
                title: "浏览器打开",
                subtitle: "支持下载",
                tint: .systemBlue,
                isActive: true
            ) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            },
            JWGlassTileItem(
                symbol: "doc.on.doc",
                title: "拷贝链接",
                subtitle: "粘贴访问",
                tint: .systemTeal
            ) {
                UIPasteboard.general.string = url.absoluteString
            },
            JWGlassTileItem(
                symbol: "square.and.arrow.up",
                title: "系统分享",
                subtitle: "发送到其他",
                tint: .systemIndigo
            ) { [weak self] in
                guard let self = self else { return }
                let act = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let pop = act.popoverPresentationController {
                    pop.sourceView = self.view
                    pop.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                    pop.permittedArrowDirections = []
                }
                self.present(act, animated: true)
            }
        ]

        let rows: [JWGlassRowItem] = [
            JWGlassRowItem(
                symbol: "safari.fill",
                tint: .systemBlue,
                title: "跳转自带浏览器打开（支持下载安装）"
            ) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            },
            JWGlassRowItem(
                symbol: "globe",
                tint: .systemTeal,
                title: "在当前标签页内直接打开"
            ) { [weak webView] in
                webView?.load(URLRequest(url: url))
            }
        ]

        let sheet = JWGlassSheetController(
            icon: .symbol(
                name: "safari.fill",
                top: UIColor(red: 0.14, green: 0.56, blue: 0.98, alpha: 1.0),
                bottom: UIColor(red: 0.18, green: 0.36, blue: 0.88, alpha: 1.0)
            ),
            title: "外部链接 · \(hostLabel)",
            subtitle: url.absoluteString,
            tiles: tiles,
            sections: [rows]
        )
        presentGlassSheet(sheet)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard !(navigationAction.targetFrame?.isMainFrame ?? false),
              let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              !scheme.isEmpty else {
            return nil
        }
        if !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            return nil
        }
        if (scheme == "http" || scheme == "https"),
           webView === webViews[config.selectedSiteId],
           shouldPromptExternalLink(url: url, for: webView) {
            presentExternalLinkActionSheet(url: url, for: webView)
            return nil
        }
        if scheme == "http" || scheme == "https" {
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

        if navigationAction.navigationType == .linkActivated,
           (navigationAction.targetFrame?.isMainFrame ?? true),
           webView === webViews[config.selectedSiteId],
           let url = navigationAction.request.url,
           shouldPromptExternalLink(url: url, for: webView) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self = self, let webView = webView else { return }
                self.presentExternalLinkActionSheet(url: url, for: webView)
            }
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        guard let linkURL = elementInfo.linkURL else {
            completionHandler(nil)
            return
        }
        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self, weak webView] _ in
            let openSafari = UIAction(
                title: "跳转自带浏览器打开",
                image: UIImage(systemName: "safari")
            ) { _ in
                UIApplication.shared.open(linkURL, options: [:], completionHandler: nil)
            }
            let copyLink = UIAction(
                title: "拷贝链接地址",
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                UIPasteboard.general.string = linkURL.absoluteString
            }
            let openInTab = UIAction(
                title: "在当前标签内打开",
                image: UIImage(systemName: "arrow.right.circle")
            ) { _ in
                webView?.load(URLRequest(url: linkURL))
            }
            let shareLink = UIAction(
                title: "系统分享…",
                image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in
                guard let self = self else { return }
                let act = UIActivityViewController(activityItems: [linkURL], applicationActivities: nil)
                if let pop = act.popoverPresentationController {
                    pop.sourceView = self.view
                    pop.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                    pop.permittedArrowDirections = []
                }
                self.present(act, animated: true)
            }
            return UIMenu(
                title: linkURL.absoluteString,
                children: [openSafari, copyLink, openInTab, shareLink]
            )
        }
        completionHandler(config)
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
