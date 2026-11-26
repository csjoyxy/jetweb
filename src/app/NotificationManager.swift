import Foundation
import UIKit
import UserNotifications
import AVFoundation

final class JWNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = JWNotificationManager()

    var onSelectSiteFromNotification: ((String) -> Void)?
    var onBackgroundListenWillStopForSuspend: (() -> Void)?
    var onPermissionStatusChanged: ((Bool) -> Void)?

    private(set) var isAuthorized: Bool = false
    private(set) var isBackgroundListening: Bool = false

    private var audioPlayer: AVAudioPlayer?
    private var hardTimeoutTimer: Timer?
    private var postNotifyGraceTimer: Timer?
    private var activeAutoSleepAfterNotify: Bool = true
    private var listenDeadline: Date?

    private var lastPostTimeBySiteId: [String: TimeInterval] = [:]
    private var lastDigestBySiteId: [String: (digest: String, time: TimeInterval)] = [:]

    private lazy var silentWAVData: Data = JWNotificationManager.makeSilentWAVData()

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        refreshAuthorizationStatus(completion: nil)
    }

    func refreshAuthorizationStatus(completion: ((Bool) -> Void)?) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let ok = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            DispatchQueue.main.async {
                self?.isAuthorized = ok
                self?.onPermissionStatusChanged?(ok)
                completion?(ok)
            }
        }
    }

    func requestPermissionIfNeeded(completion: ((Bool) -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, err in
                    if let err = err {
                        JWLog("NOTIFY", "requestAuthorization error=\(err.localizedDescription)")
                    } else {
                        JWLog("NOTIFY", "User notification permission granted=\(granted)")
                    }
                    DispatchQueue.main.async {
                        self?.isAuthorized = granted
                        self?.onPermissionStatusChanged?(granted)
                        completion?(granted)
                    }
                }
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async {
                    self?.isAuthorized = true
                    self?.onPermissionStatusChanged?(true)
                    completion?(true)
                }
            case .denied:
                DispatchQueue.main.async {
                    self?.isAuthorized = false
                    self?.onPermissionStatusChanged?(false)
                    completion?(false)
                }
            @unknown default:
                DispatchQueue.main.async {
                    completion?(false)
                }
            }
        }
    }

    // MARK: - Posting Native Banner / Notification Center Alerts

    func postSiteNotification(
        siteId: String,
        siteTitle: String,
        subtitle: String,
        body: String,
        isTest: Bool = false
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let cleanTitle = siteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "JetWeb" : siteTitle
        var cleanBody = body
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleanBody.contains("  ") {
            cleanBody = cleanBody.replacingOccurrences(of: "  ", with: " ")
        }
        if cleanBody.isEmpty {
            cleanBody = "有新的对话消息，点击查看"
        }
        if cleanBody.count > 140 {
            cleanBody = String(cleanBody.prefix(140)) + "…"
        }

        if !isTest {
            if let lastT = lastPostTimeBySiteId[siteId], (now - lastT) < 6.0 {
                return
            }
            let digest = "\(subtitle)|\(cleanBody)"
            if let prev = lastDigestBySiteId[siteId], prev.digest == digest, (now - prev.time) < 45.0 {
                return
            }
            lastPostTimeBySiteId[siteId] = now
            lastDigestBySiteId[siteId] = (digest, now)
        }

        requestPermissionIfNeeded { [weak self] granted in
            guard let self = self, granted else {
                JWLog("NOTIFY", "Skipped notification (permission not granted) site=\(cleanTitle)")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = subtitle.isEmpty ? cleanTitle : "\(cleanTitle) · \(subtitle)"
            content.body = cleanBody
            content.sound = .default
            if !siteId.isEmpty {
                content.threadIdentifier = "com.lili.jetweb.site.\(siteId)"
                content.userInfo = ["siteId": siteId]
            }

            let trigger: UNNotificationTrigger? = isTest
                ? UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
                : nil
            let req = UNNotificationRequest(
                identifier: "jw.\(UUID().uuidString)",
                content: content,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(req) { err in
                if let err = err {
                    JWLog("NOTIFY", "UNNotificationCenter add error=\(err.localizedDescription)")
                } else {
                    let appState = UIApplication.shared.applicationState
                    JWLog("NOTIFY", "Delivered banner site=\(cleanTitle) sub=\(subtitle) appState=\(appState.rawValue)")
                }
            }

            if !isTest,
               UIApplication.shared.applicationState != .active,
               self.isBackgroundListening,
               self.activeAutoSleepAfterNotify {
                self.armPostNotifyGraceTimer(seconds: 65.0)
            }
        }
    }

    // MARK: - Battery-Guarded Silent Background Listener

    func startBackgroundListening(minutes: Int, autoSleepAfterNotify: Bool) {
        stopTimersOnly()
        guard minutes > 0 else {
            stopBackgroundListening(reason: "disabled_0m", triggerJetsamGuard: false)
            return
        }

        activeAutoSleepAfterNotify = autoSleepAfterNotify
        let durationSec = TimeInterval(minutes * 60)
        listenDeadline = Date().addingTimeInterval(durationSec)

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if audioPlayer == nil {
                let player = try AVAudioPlayer(data: silentWAVData, fileTypeHint: AVFileType.wav.rawValue)
                player.numberOfLoops = -1
                player.volume = 0.0
                player.prepareToPlay()
                audioPlayer = player
            }
            audioPlayer?.volume = 0.0
            let started = audioPlayer?.play() ?? false
            isBackgroundListening = started
            JWLog("NOTIFY", "Background listener started=\(started) guard=\(minutes)m autoSleepAfterNotify=\(autoSleepAfterNotify)")
        } catch {
            isBackgroundListening = false
            JWLog("NOTIFY", "Failed to start silent audio session: \(error.localizedDescription)")
            return
        }

        let t = Timer(timeInterval: durationSec, repeats: false) { [weak self] _ in
            self?.stopBackgroundListening(reason: "timeout_\(minutes)m", triggerJetsamGuard: true)
        }
        RunLoop.main.add(t, forMode: .common)
        hardTimeoutTimer = t
    }

    func noteSiteStreamingActivity() {
        guard isBackgroundListening, postNotifyGraceTimer != nil else { return }
        armPostNotifyGraceTimer(seconds: 65.0)
    }

    private func armPostNotifyGraceTimer(seconds: TimeInterval) {
        postNotifyGraceTimer?.invalidate()
        if let deadline = listenDeadline, deadline.timeIntervalSinceNow <= seconds {
            return
        }
        JWLog("NOTIFY", "Notification delivered in BG; will auto-suspend in \(Int(seconds))s to save battery")
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.stopBackgroundListening(reason: "auto_sleep_after_reply", triggerJetsamGuard: true)
        }
        RunLoop.main.add(t, forMode: .common)
        postNotifyGraceTimer = t
    }

    func stopBackgroundListening(reason: String, triggerJetsamGuard: Bool) {
        stopTimersOnly()
        listenDeadline = nil
        let wasListening = isBackgroundListening || (audioPlayer?.isPlaying ?? false)

        if wasListening && triggerJetsamGuard && UIApplication.shared.applicationState != .active {
            JWLog("NOTIFY", "Stopping BG listener (\(reason)) -> handing off to Jetsam --bg-guard before suspend")
            onBackgroundListenWillStopForSuspend?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                guard let self = self, UIApplication.shared.applicationState != .active else { return }
                self.deactivateSilentAudio()
            }
            return
        }

        if wasListening {
            JWLog("NOTIFY", "Stopped BG listener (\(reason))")
        }
        deactivateSilentAudio()
    }

    private func deactivateSilentAudio() {
        isBackgroundListening = false
        audioPlayer?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func stopTimersOnly() {
        hardTimeoutTimer?.invalidate()
        hardTimeoutTimer = nil
        postNotifyGraceTimer?.invalidate()
        postNotifyGraceTimer = nil
    }

    @objc private func handleAudioInterruption(_ note: Notification) {
        guard isBackgroundListening,
              let info = note.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
        if type == .ended, let deadline = listenDeadline, deadline.timeIntervalSinceNow > 5 {
            try? AVAudioSession.sharedInstance().setActive(true)
            audioPlayer?.play()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sid = (response.notification.request.content.userInfo["siteId"] as? String) ?? ""
        if !sid.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onSelectSiteFromNotification?(sid)
            }
        }
        completionHandler()
    }

    // MARK: - In-Memory 1s Silent 8kHz Mono 16-Bit PCM WAV Generator

    private static func makeSilentWAVData() -> Data {
        let sampleRate: UInt32 = 8000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
        let dataBytes: UInt32 = byteRate // 1.0 second = 16,000 zero bytes
        let riffChunkSize: UInt32 = 36 + dataBytes

        var d = Data(capacity: Int(44 + dataBytes))
        func appendASCII(_ s: String) {
            d.append(contentsOf: s.utf8)
        }
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }
        func appendU16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { d.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendU32(riffChunkSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendU32(16)
        appendU16(1) // Linear PCM
        appendU16(numChannels)
        appendU32(sampleRate)
        appendU32(byteRate)
        appendU16(blockAlign)
        appendU16(bitsPerSample)
        appendASCII("data")
        appendU32(dataBytes)
        d.append(Data(count: Int(dataBytes)))
        return d
    }
}
