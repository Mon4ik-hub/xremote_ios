import Foundation

/// Выбор mp4-потока по качеству. Порт pickMp4 из background.js.
/// Потоки приходят отсортированными по убыванию качества (mp4 раньше hls).
func pickMp4(_ streams: [VideoStream], maxQuality: String?) -> VideoStream? {
    let mp4 = streams.filter { $0.kind == .mp4 }
    guard !mp4.isEmpty else { return nil }
    guard let maxQuality, maxQuality != "best" else { return mp4[0] }
    guard let want = Int(maxQuality) else { return mp4[mp4.count - 1] }
    return mp4.first { ($0.quality ?? 0) <= want } ?? mp4[mp4.count - 1]
}
