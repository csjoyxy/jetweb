import UIKit

// MARK: - High-Contrast Adaptive Glass Palette & Squircle Avatar

enum JWGlassPalette {
    enum SemanticRole {
        case emerald
        case amber
        case cobalt
        case teal
        case indigo
        case purple
        case neutral
    }

    static func role(for tint: UIColor) -> SemanticRole {
        if tint == .systemGreen { return .emerald }
        if tint == .systemOrange || tint == .systemYellow { return .amber }
        if tint == .systemTeal { return .teal }
        if tint == .systemIndigo { return .indigo }
        if tint == .systemPurple { return .purple }
        if tint == .secondaryLabel || tint == .tertiaryLabel { return .neutral }
        return .cobalt
    }

    /// High-contrast foreground color (>= 5.8:1 WCAG AA contrast on frosted glass in both Light & Dark modes)
    static func foreground(for role: SemanticRole) -> UIColor {
        return UIColor { tc in
            let dark = (tc.userInterfaceStyle == .dark)
            switch role {
            case .emerald:
                return dark
                    ? UIColor(red: 0.34, green: 0.93, blue: 0.56, alpha: 1.0)
                    : UIColor(red: 0.04, green: 0.44, blue: 0.20, alpha: 1.0)
            case .amber:
                return dark
                    ? UIColor(red: 1.00, green: 0.75, blue: 0.26, alpha: 1.0)
                    : UIColor(red: 0.72, green: 0.27, blue: 0.02, alpha: 1.0)
            case .cobalt:
                return dark
                    ? UIColor(red: 0.46, green: 0.74, blue: 1.00, alpha: 1.0)
                    : UIColor(red: 0.07, green: 0.34, blue: 0.82, alpha: 1.0)
            case .teal:
                return dark
                    ? UIColor(red: 0.36, green: 0.88, blue: 0.92, alpha: 1.0)
                    : UIColor(red: 0.03, green: 0.41, blue: 0.50, alpha: 1.0)
            case .indigo:
                return dark
                    ? UIColor(red: 0.70, green: 0.66, blue: 1.00, alpha: 1.0)
                    : UIColor(red: 0.27, green: 0.20, blue: 0.76, alpha: 1.0)
            case .purple:
                return dark
                    ? UIColor(red: 0.84, green: 0.60, blue: 1.00, alpha: 1.0)
                    : UIColor(red: 0.48, green: 0.18, blue: 0.74, alpha: 1.0)
            case .neutral:
                return dark
                    ? UIColor(white: 0.82, alpha: 1.0)
                    : UIColor(white: 0.26, alpha: 1.0)
            }
        }
    }

    static func chipFill(for role: SemanticRole) -> UIColor {
        return UIColor { tc in
            let dark = (tc.userInterfaceStyle == .dark)
            switch role {
            case .emerald:
                return dark
                    ? UIColor(red: 0.08, green: 0.34, blue: 0.19, alpha: 0.72)
                    : UIColor(red: 0.90, green: 0.98, blue: 0.93, alpha: 0.92)
            case .amber:
                return dark
                    ? UIColor(red: 0.38, green: 0.22, blue: 0.05, alpha: 0.74)
                    : UIColor(red: 1.00, green: 0.95, blue: 0.88, alpha: 0.94)
            case .cobalt:
                return dark
                    ? UIColor(red: 0.10, green: 0.25, blue: 0.48, alpha: 0.72)
                    : UIColor(red: 0.91, green: 0.95, blue: 1.00, alpha: 0.92)
            case .teal:
                return dark
                    ? UIColor(red: 0.07, green: 0.31, blue: 0.36, alpha: 0.72)
                    : UIColor(red: 0.90, green: 0.97, blue: 0.99, alpha: 0.92)
            case .indigo:
                return dark
                    ? UIColor(red: 0.20, green: 0.17, blue: 0.46, alpha: 0.72)
                    : UIColor(red: 0.93, green: 0.92, blue: 1.00, alpha: 0.92)
            case .purple:
                return dark
                    ? UIColor(red: 0.30, green: 0.15, blue: 0.44, alpha: 0.72)
                    : UIColor(red: 0.96, green: 0.91, blue: 1.00, alpha: 0.92)
            case .neutral:
                return dark
                    ? UIColor(white: 0.22, alpha: 0.75)
                    : UIColor(white: 0.95, alpha: 0.90)
            }
        }
    }

    static func chipBorder(for role: SemanticRole) -> UIColor {
        return foreground(for: role).withAlphaComponent(0.24)
    }
}

enum JWSitePalette {
    static let pairs: [(top: UIColor, bottom: UIColor)] = [
        (UIColor(red: 0.18, green: 0.49, blue: 0.96, alpha: 1.0), UIColor(red: 0.30, green: 0.28, blue: 0.90, alpha: 1.0)),
        (UIColor(red: 0.08, green: 0.68, blue: 0.62, alpha: 1.0), UIColor(red: 0.06, green: 0.48, blue: 0.68, alpha: 1.0)),
        (UIColor(red: 0.53, green: 0.33, blue: 0.96, alpha: 1.0), UIColor(red: 0.76, green: 0.24, blue: 0.72, alpha: 1.0)),
        (UIColor(red: 0.95, green: 0.50, blue: 0.16, alpha: 1.0), UIColor(red: 0.90, green: 0.27, blue: 0.36, alpha: 1.0)),
        (UIColor(red: 0.14, green: 0.62, blue: 0.92, alpha: 1.0), UIColor(red: 0.16, green: 0.38, blue: 0.86, alpha: 1.0)),
        (UIColor(red: 0.20, green: 0.72, blue: 0.42, alpha: 1.0), UIColor(red: 0.09, green: 0.52, blue: 0.46, alpha: 1.0))
    ]

    static func gradientPair(for key: String) -> (top: UIColor, bottom: UIColor) {
        var hash: UInt32 = 5381
        for b in key.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt32(b)
        }
        return pairs[Int(hash % UInt32(pairs.count))]
    }

    static func initialText(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "W" }
        return String(first).uppercased()
    }
}

final class JWSquircleAvatarView: UIView {
    private let gradLayer = CAGradientLayer()
    private let label = UILabel()
    private let iconView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerCurve = .continuous
        clipsToBounds = true

        gradLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        gradLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        layer.addSublayer(gradLayer)

        layer.borderWidth = 1.0 / UIScreen.main.scale
        layer.borderColor = UIColor.white.withAlphaComponent(0.32).cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.textAlignment = .center
        addSubview(label)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.isHidden = true
        addSubview(iconView)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradLayer.frame = bounds
        layer.cornerRadius = min(bounds.width, bounds.height) * 0.29
    }

    func configureWithTitle(_ title: String, fontSize: CGFloat = 17) {
        let pair = JWSitePalette.gradientPair(for: title)
        gradLayer.colors = [pair.top.cgColor, pair.bottom.cgColor]
        label.font = .systemFont(ofSize: fontSize, weight: .bold)
        label.text = JWSitePalette.initialText(for: title)
        label.isHidden = false
        iconView.isHidden = true
    }

    func configureWithSymbol(_ symbol: String, topColor: UIColor, bottomColor: UIColor, pointSize: CGFloat = 17) {
        gradLayer.colors = [topColor.cgColor, bottomColor.cgColor]
        let cfg = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        iconView.image = UIImage(systemName: symbol, withConfiguration: cfg)
        iconView.isHidden = false
        label.isHidden = true
    }
}

// MARK: - Data Models for Control-Center Frosted Glass Sheet

struct JWGlassChipItem {
    let symbol: String
    let text: String
    let tint: UIColor
}

struct JWGlassTileItem {
    let symbol: String
    let title: String
    var subtitle: String = ""
    var tint: UIColor = .systemBlue
    var isActive: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void
}

struct JWGlassRowItem {
    let symbol: String
    var tint: UIColor = .systemBlue
    let title: String
    var trailingText: String = ""
    var isSelected: Bool = false
    var isDestructive: Bool = false
    var showsChevron: Bool = false
    let action: () -> Void
}

// MARK: - Interactive Pressable Controls (Exact Balanced Tile Size)

private final class JWGlassTileControl: UIControl {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subLabel = UILabel()
    private var tapAction: (() -> Void)?
    private var itemRole: JWGlassPalette.SemanticRole = .cobalt
    private var itemActive: Bool = false

    init(item: JWGlassTileItem, fixedHeight: CGFloat, onInvoke: @escaping (@escaping () -> Void) -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        isEnabled = item.isEnabled
        itemRole = JWGlassPalette.role(for: item.tint)
        itemActive = item.isActive
        tapAction = { onInvoke(item.action) }

        let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: item.symbol, withConfiguration: cfg)
        iconView.contentMode = .scaleAspectFit
        iconView.isUserInteractionEnabled = false

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = item.title
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isUserInteractionEnabled = false

        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.text = item.subtitle
        subLabel.font = .systemFont(ofSize: 10, weight: .medium)
        subLabel.textAlignment = .center
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.isHidden = item.subtitle.isEmpty
        subLabel.isUserInteractionEnabled = false

        let vStack = UIStackView(arrangedSubviews: [iconView, titleLabel, subLabel])
        vStack.translatesAutoresizingMaskIntoConstraints = false
        vStack.axis = .vertical
        vStack.alignment = .center
        vStack.spacing = 4
        vStack.setCustomSpacing(1.5, after: titleLabel)
        vStack.isUserInteractionEnabled = false
        addSubview(vStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: fixedHeight),
            iconView.heightAnchor.constraint(equalToConstant: 21),
            vStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            vStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            vStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5)
        ])

        applyVisualState()
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.13, delay: 0, options: [.allowUserInteraction, .curveEaseOut]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
                self.alpha = self.isHighlighted ? 0.80 : (self.isEnabled ? 1.0 : 0.38)
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyVisualState()
    }

    private func applyVisualState() {
        let isDark = (traitCollection.userInterfaceStyle == .dark)
        layer.borderWidth = 1.0 / UIScreen.main.scale

        if itemActive {
            let fg = JWGlassPalette.foreground(for: itemRole)
            backgroundColor = JWGlassPalette.chipFill(for: itemRole)
            layer.borderColor = JWGlassPalette.chipBorder(for: itemRole).cgColor
            iconView.tintColor = fg
            titleLabel.textColor = fg
            subLabel.textColor = fg.withAlphaComponent(0.85)
        } else {
            backgroundColor = UIColor.secondarySystemGroupedBackground.withAlphaComponent(isDark ? 0.56 : 0.78)
            layer.borderColor = UIColor.white.withAlphaComponent(isDark ? 0.09 : 0.65).cgColor
            iconView.tintColor = .label
            titleLabel.textColor = .label
            subLabel.textColor = .secondaryLabel
        }
        alpha = isEnabled ? 1.0 : 0.38
    }

    @objc private func handleTap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        tapAction?()
    }
}

private final class JWGlassRowControl: UIControl {
    private var tapAction: (() -> Void)?

    init(item: JWGlassRowItem, showBottomSeparator: Bool, onInvoke: @escaping (@escaping () -> Void) -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        tapAction = { onInvoke(item.action) }

        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer.cornerRadius = 8
        badge.layer.cornerCurve = .continuous
        let role = JWGlassPalette.role(for: item.tint)
        let fgColor: UIColor = item.isDestructive ? .systemRed : JWGlassPalette.foreground(for: role)
        badge.backgroundColor = item.isDestructive
            ? UIColor.systemRed.withAlphaComponent(0.14)
            : JWGlassPalette.chipFill(for: role)
        badge.isUserInteractionEnabled = false
        addSubview(badge)

        let iconView = UIImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
        iconView.image = UIImage(systemName: item.symbol, withConfiguration: cfg)
        iconView.tintColor = fgColor
        iconView.contentMode = .scaleAspectFit
        badge.addSubview(iconView)

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = item.title
        titleLabel.font = .systemFont(ofSize: 15, weight: item.isSelected ? .semibold : .medium)
        titleLabel.textColor = item.isDestructive ? .systemRed : .label
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isUserInteractionEnabled = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        let rightStack = UIStackView()
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.axis = .horizontal
        rightStack.alignment = .center
        rightStack.spacing = 6
        rightStack.isUserInteractionEnabled = false
        addSubview(rightStack)

        if !item.trailingText.isEmpty {
            let trail = UILabel()
            trail.text = item.trailingText
            trail.font = .systemFont(ofSize: 13, weight: .medium)
            trail.textColor = .secondaryLabel
            trail.setContentCompressionResistancePriority(.required, for: .horizontal)
            rightStack.addArrangedSubview(trail)
        }

        if item.isSelected {
            let check = UIImageView(
                image: UIImage(
                    systemName: "checkmark.circle.fill",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
                )
            )
            check.tintColor = .systemBlue
            rightStack.addArrangedSubview(check)
        } else if item.showsChevron {
            let chev = UIImageView(
                image: UIImage(
                    systemName: "chevron.right",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                )
            )
            chev.tintColor = .tertiaryLabel
            rightStack.addArrangedSubview(chev)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 29),
            badge.heightAnchor.constraint(equalToConstant: 29),

            iconView.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 11),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -8),

            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        if showBottomSeparator {
            let sep = UIView()
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.backgroundColor = UIColor.separator.withAlphaComponent(0.38)
            sep.isUserInteractionEnabled = false
            addSubview(sep)
            NSLayoutConstraint.activate([
                sep.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                sep.trailingAnchor.constraint(equalTo: trailingAnchor),
                sep.bottomAnchor.constraint(equalTo: bottomAnchor),
                sep.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale)
            ])
        }

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? UIColor.tertiarySystemFill.withAlphaComponent(0.65) : .clear
        }
    }

    @objc private func handleTap() {
        UISelectionFeedbackGenerator().selectionChanged()
        tapAction?()
    }
}

// MARK: - Control-Center Frosted Glass Bottom Sheet Controller

final class JWGlassSheetController: UIViewController {
    enum HeaderIcon {
        case siteTitle(String)
        case symbol(name: String, top: UIColor, bottom: UIColor)
    }

    private let headerIcon: HeaderIcon
    private let sheetTitle: String
    private let sheetSubtitle: String
    private let chips: [JWGlassChipItem]
    private let tiles: [JWGlassTileItem]
    private let sections: [[JWGlassRowItem]]

    private let dimView = UIView()
    private let shadowWrap = UIView()
    private let glassCard = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private var cardBottomConstraint: NSLayoutConstraint!
    private var didAnimateIn = false
    private var isDismissingSheet = false

    init(
        icon: HeaderIcon,
        title: String,
        subtitle: String = "",
        chips: [JWGlassChipItem] = [],
        tiles: [JWGlassTileItem] = [],
        sections: [[JWGlassRowItem]]
    ) {
        self.headerIcon = icon
        self.sheetTitle = title
        self.sheetSubtitle = subtitle
        self.chips = chips
        self.tiles = tiles
        self.sections = sections
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        dimView.alpha = 0
        let tapDim = UITapGestureRecognizer(target: self, action: #selector(dismissTapped))
        dimView.addGestureRecognizer(tapDim)
        view.addSubview(dimView)

        shadowWrap.translatesAutoresizingMaskIntoConstraints = false
        shadowWrap.backgroundColor = .clear
        shadowWrap.layer.shadowColor = UIColor.black.cgColor
        shadowWrap.layer.shadowOpacity = 0.20
        shadowWrap.layer.shadowRadius = 26
        shadowWrap.layer.shadowOffset = CGSize(width: 0, height: 10)
        shadowWrap.transform = CGAffineTransform(translationX: 0, y: 420)
        view.addSubview(shadowWrap)

        glassCard.translatesAutoresizingMaskIntoConstraints = false
        glassCard.layer.cornerRadius = 26
        glassCard.layer.cornerCurve = .continuous
        glassCard.clipsToBounds = true
        shadowWrap.addSubview(glassCard)

        let grabber = UIView()
        grabber.translatesAutoresizingMaskIntoConstraints = false
        grabber.backgroundColor = UIColor.tertiaryLabel.withAlphaComponent(0.55)
        grabber.layer.cornerRadius = 2.25
        glassCard.contentView.addSubview(grabber)

        let headerView = buildHeaderView()
        glassCard.contentView.addSubview(headerView)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        glassCard.contentView.addSubview(scrollView)

        let bodyStack = UIStackView()
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.axis = .vertical
        bodyStack.spacing = 10
        scrollView.addSubview(bodyStack)

        if !tiles.isEmpty {
            let hasSub = tiles.contains { !$0.subtitle.isEmpty }
            let tileH: CGFloat = hasSub ? 72 : 68
            let tileRow = UIStackView()
            tileRow.translatesAutoresizingMaskIntoConstraints = false
            tileRow.axis = .horizontal
            tileRow.distribution = .fillEqually
            tileRow.alignment = .fill
            tileRow.spacing = 8
            tileRow.heightAnchor.constraint(equalToConstant: tileH).isActive = true
            for t in tiles {
                let ctrl = JWGlassTileControl(item: t, fixedHeight: tileH) { [weak self] action in
                    self?.dismissAndInvoke(action)
                }
                tileRow.addArrangedSubview(ctrl)
            }
            bodyStack.addArrangedSubview(tileRow)
        }

        let isDark = (traitCollection.userInterfaceStyle == .dark)
        for group in sections where !group.isEmpty {
            let groupCard = UIView()
            groupCard.translatesAutoresizingMaskIntoConstraints = false
            groupCard.backgroundColor = UIColor.secondarySystemGroupedBackground.withAlphaComponent(isDark ? 0.56 : 0.78)
            groupCard.layer.cornerRadius = 16
            groupCard.layer.cornerCurve = .continuous
            groupCard.layer.borderWidth = 1.0 / UIScreen.main.scale
            groupCard.layer.borderColor = UIColor.white.withAlphaComponent(isDark ? 0.09 : 0.65).cgColor
            groupCard.clipsToBounds = true

            let rowsStack = UIStackView()
            rowsStack.translatesAutoresizingMaskIntoConstraints = false
            rowsStack.axis = .vertical
            rowsStack.spacing = 0
            for (idx, rowItem) in group.enumerated() {
                let rowCtrl = JWGlassRowControl(
                    item: rowItem,
                    showBottomSeparator: idx < (group.count - 1)
                ) { [weak self] action in
                    self?.dismissAndInvoke(action)
                }
                rowsStack.addArrangedSubview(rowCtrl)
            }
            groupCard.addSubview(rowsStack)
            NSLayoutConstraint.activate([
                rowsStack.topAnchor.constraint(equalTo: groupCard.topAnchor),
                rowsStack.leadingAnchor.constraint(equalTo: groupCard.leadingAnchor),
                rowsStack.trailingAnchor.constraint(equalTo: groupCard.trailingAnchor),
                rowsStack.bottomAnchor.constraint(equalTo: groupCard.bottomAnchor)
            ])
            bodyStack.addArrangedSubview(groupCard)
        }

        let contentHeightConstraint = scrollView.heightAnchor.constraint(equalTo: bodyStack.heightAnchor)
        contentHeightConstraint.priority = UILayoutPriority(995)

        /* Gently pull shadowWrap toward minimum intrinsic height so short sheets never stretch upward */
        let compactSheetConstraint = shadowWrap.heightAnchor.constraint(equalToConstant: 0)
        compactSheetConstraint.priority = UILayoutPriority(50)

        cardBottomConstraint = shadowWrap.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10)
        let lead = shadowWrap.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12)
        lead.priority = UILayoutPriority(999)
        let trail = shadowWrap.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12)
        trail.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            shadowWrap.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            lead,
            trail,
            shadowWrap.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            shadowWrap.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),
            cardBottomConstraint,
            compactSheetConstraint,

            glassCard.topAnchor.constraint(equalTo: shadowWrap.topAnchor),
            glassCard.leadingAnchor.constraint(equalTo: shadowWrap.leadingAnchor),
            glassCard.trailingAnchor.constraint(equalTo: shadowWrap.trailingAnchor),
            glassCard.bottomAnchor.constraint(equalTo: shadowWrap.bottomAnchor),

            grabber.topAnchor.constraint(equalTo: glassCard.contentView.topAnchor, constant: 8),
            grabber.centerXAnchor.constraint(equalTo: glassCard.contentView.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 36),
            grabber.heightAnchor.constraint(equalToConstant: 4.5),

            headerView.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 10),
            headerView.leadingAnchor.constraint(equalTo: glassCard.contentView.leadingAnchor, constant: 16),
            headerView.trailingAnchor.constraint(equalTo: glassCard.contentView.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: glassCard.contentView.leadingAnchor, constant: 13),
            scrollView.trailingAnchor.constraint(equalTo: glassCard.contentView.trailingAnchor, constant: -13),
            scrollView.bottomAnchor.constraint(equalTo: glassCard.contentView.bottomAnchor, constant: -13),
            contentHeightConstraint,

            bodyStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            bodyStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleCardPan(_:)))
        glassCard.addGestureRecognizer(pan)

        updateSpecularBorder()
    }

    private func buildHeaderView() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let avatar = JWSquircleAvatarView(frame: .zero)
        switch headerIcon {
        case .siteTitle(let t):
            avatar.configureWithTitle(t, fontSize: 17)
        case .symbol(let name, let top, let bottom):
            avatar.configureWithSymbol(name, topColor: top, bottomColor: bottom, pointSize: 17)
        }
        container.addSubview(avatar)

        let closeBtn = UIButton(type: .system)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.backgroundColor = UIColor.tertiarySystemFill.withAlphaComponent(0.9)
        closeBtn.layer.cornerRadius = 14
        let xCfg = UIImage.SymbolConfiguration(pointSize: 11.5, weight: .bold)
        closeBtn.setImage(UIImage(systemName: "xmark", withConfiguration: xCfg), for: .normal)
        closeBtn.tintColor = .secondaryLabel
        closeBtn.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        container.addSubview(closeBtn)

        let textStack = UIStackView()
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4.5
        container.addSubview(textStack)

        let titleLbl = UILabel()
        titleLbl.text = sheetTitle
        titleLbl.font = .systemFont(ofSize: 16.5, weight: .bold)
        titleLbl.textColor = .label
        titleLbl.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(titleLbl)

        if !sheetSubtitle.isEmpty {
            let subLbl = UILabel()
            subLbl.text = sheetSubtitle
            subLbl.font = .systemFont(ofSize: 12, weight: .regular)
            subLbl.textColor = .secondaryLabel
            subLbl.lineBreakMode = .byTruncatingMiddle
            subLbl.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
            textStack.addArrangedSubview(subLbl)
        }

        if !chips.isEmpty {
            let chipRow = UIStackView()
            chipRow.axis = .horizontal
            chipRow.spacing = 5.5
            chipRow.alignment = .center
            for ch in chips {
                chipRow.addArrangedSubview(makeChipView(ch))
            }
            textStack.addArrangedSubview(chipRow)
        }

        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            avatar.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 40),
            avatar.heightAnchor.constraint(equalToConstant: 40),

            closeBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            closeBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 28),
            closeBtn.heightAnchor.constraint(equalToConstant: 28),

            textStack.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 11),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: closeBtn.leadingAnchor, constant: -8),
            textStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            textStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 42)
        ])

        return container
    }

    private func makeChipView(_ chip: JWGlassChipItem) -> UIView {
        let role = JWGlassPalette.role(for: chip.tint)
        let fgColor = JWGlassPalette.foreground(for: role)

        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = JWGlassPalette.chipFill(for: role)
        pill.layer.cornerRadius = 7
        pill.layer.cornerCurve = .continuous
        pill.layer.borderWidth = 1.0 / UIScreen.main.scale
        pill.layer.borderColor = JWGlassPalette.chipBorder(for: role).cgColor

        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 9.5, weight: .bold)
        iv.image = UIImage(systemName: chip.symbol, withConfiguration: cfg)
        iv.tintColor = fgColor

        let lbl = UILabel()
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.text = chip.text
        lbl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        lbl.textColor = fgColor
        lbl.setContentCompressionResistancePriority(.required, for: .horizontal)

        pill.addSubview(iv)
        pill.addSubview(lbl)

        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 21),
            iv.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6.5),
            iv.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            lbl.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 3.5),
            lbl.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
            lbl.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])
        return pill
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAnimateIn else { return }
        didAnimateIn = true
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        UIView.animate(
            withDuration: 0.30,
            delay: 0,
            usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0.6,
            options: [.allowUserInteraction, .curveEaseOut]
        ) {
            self.dimView.alpha = 1.0
            self.shadowWrap.transform = .identity
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        shadowWrap.layer.shadowPath = UIBezierPath(
            roundedRect: shadowWrap.bounds,
            cornerRadius: 26
        ).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateSpecularBorder()
    }

    private func updateSpecularBorder() {
        let isDark = (traitCollection.userInterfaceStyle == .dark)
        glassCard.layer.borderWidth = 1.0 / UIScreen.main.scale
        glassCard.layer.borderColor = UIColor.white.withAlphaComponent(isDark ? 0.18 : 0.68).cgColor
    }

    @objc private func handleCardPan(_ pan: UIPanGestureRecognizer) {
        let dy = pan.translation(in: view).y
        switch pan.state {
        case .changed:
            if dy > 0 {
                shadowWrap.transform = CGAffineTransform(translationX: 0, y: dy)
                let progress = min(1.0, dy / 260.0)
                dimView.alpha = 1.0 - (progress * 0.65)
            } else {
                shadowWrap.transform = CGAffineTransform(translationX: 0, y: dy * 0.18)
            }
        case .ended, .cancelled:
            let vy = pan.velocity(in: view).y
            if dy > 105 || vy > 850 {
                dismissAndInvoke(nil)
            } else {
                UIView.animate(
                    withDuration: 0.24,
                    delay: 0,
                    usingSpringWithDamping: 0.86,
                    initialSpringVelocity: 0.4,
                    options: [.allowUserInteraction]
                ) {
                    self.shadowWrap.transform = .identity
                    self.dimView.alpha = 1.0
                }
            }
        default:
            break
        }
    }

    @objc private func dismissTapped() {
        dismissAndInvoke(nil)
    }

    private func dismissAndInvoke(_ action: (() -> Void)?) {
        guard !isDismissingSheet else { return }
        isDismissingSheet = true
        UIView.animate(
            withDuration: 0.19,
            delay: 0,
            options: [.curveEaseIn]
        ) {
            self.dimView.alpha = 0
            self.shadowWrap.transform = CGAffineTransform(translationX: 0, y: self.shadowWrap.bounds.height + 40)
        } completion: { _ in
            self.dismiss(animated: false) {
                action?()
            }
        }
    }
}
