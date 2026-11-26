import UIKit

final class ErrorOverlayView: UIView {
    var failedURLString: String = ""
    var onRetry: (() -> Void)?
    var onGoHome: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let urlLabel = UILabel()
    private let detailLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let homeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .systemBackground
        isHidden = true

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = .systemOrange
        iconView.contentMode = .scaleAspectFit
        iconView.image = UIImage(
            systemName: "exclamationmark.triangle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 38, weight: .semibold)
        )
        card.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        card.addSubview(titleLabel)

        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        urlLabel.textColor = .secondaryLabel
        urlLabel.textAlignment = .center
        urlLabel.numberOfLines = 2
        urlLabel.lineBreakMode = .byTruncatingMiddle
        card.addSubview(urlLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 13.5, weight: .regular)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        card.addSubview(detailLabel)

        var retryCfg = UIButton.Configuration.filled()
        retryCfg.title = "重新加载"
        retryCfg.cornerStyle = .capsule
        retryCfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 24, bottom: 10, trailing: 24)
        retryButton.configuration = retryCfg
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        var homeCfg = UIButton.Configuration.tinted()
        homeCfg.title = "返回站点首页"
        homeCfg.cornerStyle = .capsule
        homeCfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20)
        homeButton.configuration = homeCfg
        homeButton.translatesAutoresizingMaskIntoConstraints = false
        homeButton.addTarget(self, action: #selector(homeTapped), for: .touchUpInside)

        let btnStack = UIStackView(arrangedSubviews: [retryButton, homeButton])
        btnStack.translatesAutoresizingMaskIntoConstraints = false
        btnStack.axis = .horizontal
        btnStack.spacing = 12
        btnStack.alignment = .center
        card.addSubview(btnStack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            iconView.topAnchor.constraint(equalTo: card.topAnchor),
            iconView.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            iconView.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            urlLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            urlLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            detailLabel.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 10),
            detailLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            btnStack.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 20),
            btnStack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            btnStack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
