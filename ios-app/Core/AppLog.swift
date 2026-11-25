import Foundation

/// Простой файловый журнал (последние ~64 КБ) в Documents таргета.
/// Приложение: файл виден в «Файлах» (UIFileSharingEnabled) и через iTunes.
/// Расширение: выдаётся кнопкой «Журнал» на панели.
final class AppLog {
    static let shared = AppLog()

    private let queue = DispatchQueue(label: "ru.mon4ik.animegocast.applog")
    private let url: URL
    private let maxBytes = 64 * 1024

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = documents.appendingPathComponent("applog.txt")
    }

    func log(_ message: String) {
        let line = "\(Self.stamp()) \(message)\n"
        queue.async { self.append(line) }
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    func text() -> String {
        queue.sync { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    }

    func clear() {
        queue.async {
            try? "".write(to: self.url, atomically: true, encoding: .utf8)
        }
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        if let size = try? handle.seekToEnd(), size > UInt64(maxBytes) {
            // оставляем только хвост
            try? handle.seek(toOffset: size - UInt64(maxBytes / 2))
            let tail = (try? handle.read(upToCount: maxBytes / 2)) ?? Data()
            try? handle.close()
            try? (String(decoding: tail, as: UTF8.self)).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
