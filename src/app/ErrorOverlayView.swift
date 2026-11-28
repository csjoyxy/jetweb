import UIKit

final class ErrorOverlayView: UIView {
    var hasActiveError: Bool = false
    var failedURLString: String = ""
    var onRetry: (() -> Void)?
    var onGoHome: (() -> Void)?

    private let shadowWrap = UIView()
    private let glassCard = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let medallion = JWSquircleAvatarView(frame: .zero)
    private let titleLabel = UILabel()
    private let urlPill = UIView()
    private let urlLabel = UILabel()
    private let detailLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let homeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .secondarySystemBackground
        isHidden = true

        let orbTop = UIView()
        orbTop.translatesAutoresizingMaskIntoConstraints = false
        orbTop.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.10)
        orbTop.layer.cornerRadius = 95
        orbTop.isUserInteractionEnabled = false
        addSubview(orbTop)

        let orbBottom = UIView()
        orbBottom.translatesAutoresizingMaskIntoConstraints = false
        orbBottom.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
        orbBottom.layer.cornerRadius = 110
        orbBottom.isUserInteractionEnabled = false
        addSubview(orbBottom)

        shadowWrap.translatesAutoresizingMaskIntoConstraints = false
        shadowWrap.layer.shadowColor = UIColor.black.cgColor
        shadowWrap.layer.shadowOpacity = 0.10
        shadowWrap.layer.shadowRadius = 22
        shadowWrap.layer.shadowOffset = CGSize(width: 0, height: 8)
        addSubview(shadowWrap)

        glassCard.translatesAutoresizingMaskIntoConstraints = false
        glassCard.layer.cornerRadius = 26
        glassCard.layer.cornerCurve = .continuous
        glassCard.clipsToBounds = true
        shadowWrap.addSubview(glassCard)

        medallion.configureWithSymbol(
            "wifi.exclamationmark",
            topColor: UIColor(red: 0.96, green: 0.52, blue: 0.18, alpha: 1.0),
            bottomColor: UIColor(red: 0.90, green: 0.28, blue: 0.34, alpha: 1.0),
            pointSize: 24
        )
        glassCard.contentView.addSubview(medallion)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 18.5, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        glassCard.contentView.addSubview(titleLabel)

        urlPill.translatesAutoresizingMaskIntoConstraints = false
        urlPill.backgroundColor = UIColor.tertiarySystemFill.withAlphaComponent(0.75)
        urlPill.layer.cornerRadius = 9
        urlPill.layer.cornerCurve = .continuous
        glassCard.contentView.addSubview(urlPill)

        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        urlLabel.textColor = .secondaryLabel
        urlLabel.textAlignment = .center
        urlLabel.numberOfLines = 2
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlPill.addSubview(urlLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 13.5, weight: .regular)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        glassCard.contentView.addSubview(detailLabel)

        var retryCfg = UIButton.Configuration.filled()
        retryCfg.title = "重新加载"
        retryCfg.image = UIImage(systemName: "arrow.clockwise", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.5, weight: .bold))
        retryCfg.imagePadding = 6
        retryCfg.cornerStyle = .capsule
        retryCfg.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 22, bottom: 11, trailing: 22)
        retryButton.configuration = retryCfg
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        var homeCfg = UIButton.Configuration.tinted()
        homeCfg.title = "返回首页"
        homeCfg.image = UIImage(systemName: "house.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        homeCfg.imagePadding = 6
        homeCfg.cornerStyle = .capsule
        homeCfg.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 18, bottom: 11, trailing: 18)
        homeButton.configuration = homeCfg
        homeButton.translatesAutoresizingMaskIntoConstraints = false
        homeButton.addTarget(self, action: #selector(homeTapped), for: .touchUpInside)

        let btnStack = UIStackView(arrangedSubviews: [retryButton, homeButton])
        btnStack.translatesAutoresizingMaskIntoConstraints = false
        btnStack.axis = .horizontal
        btnStack.spacing = 10
        btnStack.alignment = .center
        glassCard.contentView.addSubview(btnStack)

        NSLayoutConstraint.activate([
            orbTop.widthAnchor.constraint(equalToConstant: 190),
            orbTop.heightAnchor.constraint(equalToConstant: 190),
            orbTop.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -70),
            orbTop.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -95),

            orbBottom.widthAnchor.constraint(equalToConstant: 220),
            orbBottom.heightAnchor.constraint(equalToConstant: 220),
            orbBottom.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 80),
            orbBottom.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 95),

            shadowWrap.centerXAnchor.constraint(equalTo: centerXAnchor),
            shadowWrap.centerYAnchor.constraint(equalTo: centerYAnchor),
            shadowWrap.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 22),
            shadowWrap.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -22),
            shadowWrap.widthAnchor.constraint(lessThanOrEqualToConstant: 400),

            glassCard.topAnchor.constraint(equalTo: shadowWrap.topAnchor),
            glassCard.leadingAnchor.constraint(equalTo: shadowWrap.leadingAnchor),
            glassCard.trailingAnchor.constraint(equalTo: shadowWrap.trailingAnchor),
            glassCard.bottomAnchor.constraint(equalTo: shadowWrap.bottomAnchor),

            medallion.topAnchor.constraint(equalTo: glassCard.contentView.topAnchor, constant: 26),
            medallion.centerXAnchor.constraint(equalTo: glassCard.contentView.centerXAnchor),
            medallion.widthAnchor.constraint(equalToConstant: 56),
            medallion.heightAnchor.constraint(equalToConstant: 56),

            titleLabel.topAnchor.constraint(equalTo: medallion.bottomAnchor, constant: 15),
            titleLabel.leadingAnchor.constraint(equalTo: glassCard.contentView.leadingAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(equalTo: glassCard.contentView.trailingAnchor, constant: -22),

            urlPill.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 9),
            urlPill.centerXAnchor.constraint(equalTo: glassCard.contentView.centerXAnchor),
            urlPill.leadingAnchor.constraint(greaterThanOrEqualTo: glassCard.contentView.leadingAnchor, constant: 20),
            urlPill.trailingAnchor.constraint(lessThanOrEqualTo: glassCard.contentView.trailingAnchor, constant: -20),

            urlLabel.topAnchor.constraint(equalTo: urlPill.topAnchor, constant: 5),
            urlLabel.bottomAnchor.constraint(equalTo: urlPill.bottomAnchor, constant: -5),
            urlLabel.leadingAnchor.constraint(equalTo: urlPill.leadingAnchor, constant: 10),
            urlLabel.trailingAnchor.constraint(equalTo: urlPill.trailingAnchor, constant: -10),

            detailLabel.topAnchor.constraint(equalTo: urlPill.bottomAnchor, constant: 12),
            detailLabel.leadingAnchor.constraint(equalTo: glassCard.contentView.leadingAnchor, constant: 22),
            detailLabel.trailingAnchor.constraint(equalTo: glassCard.contentView.trailingAnchor, constant: -22),

            btnStack.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 22),
            btnStack.centerXAnchor.constraint(equalTo: glassCard.contentView.centerXAnchor),
            btnStack.bottomAnchor.constraint(equalTo: glassCard.contentView.bottomAnchor, constant: -24)
        ])

        updateGlassBorder()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shadowWrap.layer.shadowPath = UIBezierPath(roundedRect: shadowWrap.bounds, cornerRadius: 26).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateGlassBorder()
    }

    private func updateGlassBorder() {
        let isDark = (traitCollection.userInterfaceStyle == .dark)
        glassCard.layer.borderWidth = 1.0 / UIScreen.main.scale
        glassCard.layer.borderColor = UIColor.white.withAlphaComponent(isDark ? 0.16 : 0.65).cgColor
    }

    static func isSSLError(_ error: NSError?) -> Bool {
        guard let error = error, error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorSecureConnectionFailed,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return true
        default:
            return false
        }
    }

    func configure(error: NSError?, failedURL: String, homeURL: String, customTitle: String?, customDetail: String?) {
        failedURLString = failedURL
        let isSSL = ErrorOverlayView.isSSLError(error)
        if isSSL {
            medallion.configureWithSymbol(
                "exclamationmark.shield.fill",
                topColor: UIColor(red: 0.96, green: 0.56, blue: 0.14, alpha: 1.0),
                bottomColor: UIColor(red: 0.88, green: 0.32, blue: 0.22, alpha: 1.0),
                pointSize: 24
            )
        } else {
            medallion.configureWithSymbol(
                "wifi.exclamationmark",
                topColor: UIColor(red: 0.24, green: 0.52, blue: 0.96, alpha: 1.0),
                bottomColor: UIColor(red: 0.36, green: 0.30, blue: 0.88, alpha: 1.0),
                pointSize: 23
            )
        }

        if let customTitle = customTitle, !customTitle.isEmpty {
            titleLabel.text = customTitle
        } else {
            titleLabel.text = isSSL ? "安全连接 / 证书校验失败" : "无法打开此页面"
        }
        urlLabel.text = failedURL

        if let customDetail = customDetail, !customDetail.isEmpty {
            detailLabel.text = customDetail
        } else if let error = error {
            let tip: String
            if isSSL {
                tip = "\n提示：若该站点使用自签名证书，点击「重新加载」可在弹窗中选择按域名信任。"
            } else if error.domain == NSURLErrorDomain &&
                        (error.code == NSURLErrorCannotConnectToHost ||
                         error.code == NSURLErrorTimedOut ||
                         error.code == NSURLErrorCannotFindHost) {
                tip = "\n提示：请检查内网/VPN 连接、服务端口以及本地网络访问权限。"
            } else {
                tip = ""
            }
            detailLabel.text = "\(error.localizedDescription)\n(\(error.domain) \(error.code))\(tip)"
        } else {
            detailLabel.text = "页面加载中断，请点击下方按钮重试。"
        }

        homeButton.isHidden = (homeURL.isEmpty || failedURL.isEmpty || homeURL == failedURL)
    }

    @objc private func retryTapped() {
        onRetry?()
    }

    @objc private func homeTapped() {
        onGoHome?()
    }
}
