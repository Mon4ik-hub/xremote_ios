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

/// Порядок попыток при отправке серии: первый CVH, первый Kodik, затем остальные.
/// У части тайтлов плейлист CVH пуст — тогда выручает Kodik.
func castCandidates(_ providers: [ProviderItem]) -> [ProviderItem] {
    let cvh = providers.filter { $0.key == "cvh" }
    let kodik = providers.filter { $0.key == "kodik" }
    var candidates: [ProviderItem] = []
    if let first = cvh.first { candidates.append(first) }
    if let first = kodik.first { candidates.append(first) }
    candidates.append(contentsOf: cvh.dropFirst())
    candidates.append(contentsOf: kodik.dropFirst())
    return candidates
}
