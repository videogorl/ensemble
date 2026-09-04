import Foundation

/// Portable, library-independent description of media shared between Ensemble users.
public struct EnsemblePermalink: Sendable, Equatable, Hashable {
    public static let currentVersion = 1
    private static let webHost = "ensemble.videogorl.me"

    public let kind: SiriMediaKind
    public let title: String
    public let artistName: String?
    public let albumTitle: String?
    public let year: Int?
    public let duration: TimeInterval?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let isSmartPlaylist: Bool?

    public init(
        kind: SiriMediaKind,
        title: String,
        artistName: String? = nil,
        albumTitle: String? = nil,
        year: Int? = nil,
        duration: TimeInterval? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        isSmartPlaylist: Bool? = nil
    ) {
        self.kind = kind
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.year = year
        self.duration = duration
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.isSmartPlaylist = isSmartPlaylist
    }

    /// Encodes the descriptor as a portable Ensemble Universal Link.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.webHost
        guard let encodedTitle = title.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) else {
            return nil
        }
        components.percentEncodedPath = "/media/v\(Self.currentVersion)/\(pathKind)/\(encodedTitle)"

        var queryItems: [URLQueryItem] = []
        append(artistName, named: "artist", to: &queryItems)
        append(albumTitle, named: "album", to: &queryItems)
        append(year, named: "year", to: &queryItems)
        append(duration.map { Int($0.rounded()) }, named: "duration", to: &queryItems)
        append(trackNumber, named: "track", to: &queryItems)
        append(discNumber.flatMap { $0 > 1 ? $0 : nil }, named: "disc", to: &queryItems)
        append(isSmartPlaylist, named: "smart", to: &queryItems)
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    /// Decodes a supported portable Ensemble media URL.
    public init?(url: URL) {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()
        var path = url.pathComponents.filter { $0 != "/" }

        if scheme == "https", host == Self.webHost, path.first?.lowercased() == "media" {
            path.removeFirst()
        } else if scheme != "ensemble" || host != "media" {
            return nil
        }

        guard path.count == 3,
              path[0].lowercased() == "v\(Self.currentVersion)",
              let kind = Self.kind(for: path[1]),
              !path[2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value
        }

        self.init(
            kind: kind,
            title: path[2],
            artistName: value("artist"),
            albumTitle: value("album"),
            year: value("year").flatMap(Int.init),
            duration: value("duration").flatMap(Double.init),
            trackNumber: value("track").flatMap(Int.init),
            discNumber: value("disc").flatMap(Int.init),
            isSmartPlaylist: value("smart").flatMap(Bool.init)
        )
    }

    private var pathKind: String {
        kind == .track ? "song" : kind.rawValue
    }

    private static func kind(for pathComponent: String) -> SiriMediaKind? {
        if pathComponent.lowercased() == "song" {
            return .track
        }
        return SiriMediaKind(rawValue: pathComponent.lowercased())
    }

    private func append<T>(_ value: T?, named name: String, to items: inout [URLQueryItem]) {
        guard let value else { return }
        items.append(URLQueryItem(name: name, value: String(describing: value)))
    }
}
