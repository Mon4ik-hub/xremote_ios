import Foundation

struct AnimeMeta: Equatable {
    let animeId: String
    let title: String
}

struct Episode: Identifiable, Equatable {
    let number: String   // data-episode-number
    let id: String       // data-episode
}

struct ProviderItem: Identifiable, Equatable {
    let key: String      // "cvh" | "kodik"
    let url: String      // embed-ссылка плеера
    let dub: String      // озвучка

    var id: String { "\(key)|\(url)|\(dub)" }
}

enum StreamKind: String, Equatable {
    case mp4
    case hls
}

struct Stream: Equatable {
    let kind: StreamKind
    let quality: Int?    // 1080, 720, ...; nil у HLS без качества
    let url: String
}
