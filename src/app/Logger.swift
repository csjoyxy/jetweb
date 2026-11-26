import Foundation

final class JWLogger {
    static let shared = JWLogger()

    private let queue = DispatchQueue(label: "com.lili.jetweb.logger", qos: .utility)
    private let maxFileBytes: UInt64 = 256 * 1024
    private var enabledFlag: Bool = true
    private let formatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    private init() {
        ensureLogFileReadyOnQueue()
    }

    static var logFilePath: String {
        return (AppConfig.effectiveDir() as NSString).appendingPathComponent("jetweb.log")
    }

    static var prevLogFilePath: String {
        return (AppConfig.effectiveDir() as NSString).appendingPathComponent("jetweb.prev.log")
    }

    func setEnabled(_ enabled: Bool) {
        queue.async {
            self.enabledFlag = enabled
            if enabled {
                self.ensureLogFileReadyOnQueue()
            }
        }
    }

    private func ensureLogFileReadyOnQueue() {
        let path = JWLogger.logFilePath
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o644])
        }
    }

    func log(_ tag: String, _ message: String) {
        let now = Date()
        queue.async {
            guard self.enabledFlag else { return }
            self.ensureLogFileReadyOnQueue()
            let path = JWLogger.logFilePath
            let fm = FileManager.default

            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = (attrs[.size] as? NSNumber)?.uint64Value,
               size >= self.maxFileBytes {
                let prev = JWLogger.prevLogFilePath
                try? fm.removeItem(atPath: prev)
                try? fm.moveItem(atPath: path, toPath: prev)
                fm.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o644])
            }

            let ts = self.formatter.string(from: now)
            let cleanMsg = message.replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ⏎ ")
            let line = "\(ts) [\(tag)] \(cleanMsg)\n"
            guard let data = line.data(using: .utf8) else { return }

            if let fh = FileHandle(forWritingAtPath: path) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
            }
        }
    }

    func readCombinedLogs(maxCharacters: Int = 48_000, completion: @escaping (String) -> Void) {
        queue.async {
            var combined = ""
            if let prevData = try? Data(contentsOf: URL(fileURLWithPath: JWLogger.prevLogFilePath)),
               let prevText = String(data: prevData, encoding: .utf8), !prevText.isEmpty {
                combined += prevText
            }
            if let curData = try? Data(contentsOf: URL(fileURLWithPath: JWLogger.logFilePath)),
               let curText = String(data: curData, encoding: .utf8), !curText.isEmpty {
                combined += curText
            }
            if combined.count > maxCharacters {
                combined = "...(已截断早期日志)...\n" + String(combined.suffix(maxCharacters))
            }
            DispatchQueue.main.async {
                completion(combined)
            }
        }
    }

    func clearLogs(completion: (() -> Void)? = nil) {
        queue.async {
            let fm = FileManager.default
            try? fm.removeItem(atPath: JWLogger.prevLogFilePath)
            try? fm.removeItem(atPath: JWLogger.logFilePath)
            self.ensureLogFileReadyOnQueue()
            if let completion = completion {
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
    }

    static func maskURL(_ url: URL?) -> String {
        guard let url = url else { return "(nil)" }
        let scheme = url.scheme ?? "https"
        let host = url.host ?? ""
        if host.isEmpty {
            return url.absoluteString
        }
        let portPart: String
        if let port = url.port, port != 80 && port != 443 {
            portPart = ":\(port)"
        } else {
            portPart = ""
        }
        let path = url.path.isEmpty ? "/" : url.path
        return "\(scheme)://\(host)\(portPart)\(path)"
    }
}

func JWLog(_ tag: String, _ message: String) {
    JWLogger.shared.log(tag, message)
}
