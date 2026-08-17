import Combine
import EnsembleDomain
import Foundation

public struct HiddenMediaSnapshot: Equatable, Sendable {
    public static let empty = HiddenMediaSnapshot(identities: [])

    public let identities: Set<HiddenMediaIdentity>

    public init(identities: Set<HiddenMediaIdentity>) {
        self.identities = identities
    }

    public func contains(_ identity: HiddenMediaIdentity) -> Bool {
        identities.contains(identity)
    }

    public func isHidden(_ track: Track) -> Bool {
        guard let sourceKey = track.sourceCompositeKey else { return false }
        if contains(.init(kind: .track, itemID: track.id, sourceCompositeKey: sourceKey)) { return true }
        if let albumID = track.albumRatingKey,
           contains(.init(kind: .album, itemID: albumID, sourceCompositeKey: sourceKey)) { return true }
        if let artistID = track.artistRatingKey,
           contains(.init(kind: .artist, itemID: artistID, sourceCompositeKey: sourceKey)) { return true }
        return false
    }

    public func isHidden(_ album: Album) -> Bool {
        guard let sourceKey = album.sourceCompositeKey else { return false }
        if contains(.init(kind: .album, itemID: album.id, sourceCompositeKey: sourceKey)) { return true }
        guard let artistID = album.artistRatingKey else { return false }
        return contains(.init(kind: .artist, itemID: artistID, sourceCompositeKey: sourceKey))
    }

    public func isHidden(_ artist: Artist) -> Bool {
        HiddenMediaIdentity(artist).map(contains) ?? false
    }

    public func isHidden(_ playlist: Playlist) -> Bool {
        HiddenMediaIdentity(playlist).map(contains) ?? false
    }

    public func visibleTracks(_ tracks: [Track]) -> [Track] {
        tracks.filter { !isHidden($0) }
    }

}

public struct HiddenMediaCandidate: Identifiable, Equatable, Sendable {
    public let identity: HiddenMediaIdentity
    public let title: String
    public let source: String
    public let relatedCatalogID: String?

    public init(
        identity: HiddenMediaIdentity,
        title: String,
        source: String,
        relatedCatalogID: String? = nil
    ) {
        self.identity = identity
        self.title = title
        self.source = source
        self.relatedCatalogID = relatedCatalogID
    }

    public var id: String { identity.id }
}

@MainActor
public final class HiddenMediaStore: ObservableObject {
    public static let shared = HiddenMediaStore()

    @Published public private(set) var snapshot: HiddenMediaSnapshot = .empty
    @Published public var pendingCandidates: [HiddenMediaCandidate] = []
    @Published public private(set) var sectionOrder: [HiddenMediaKind]

    public private(set) var lastRemoteApplyTime: Date?

    private let defaults: UserDefaults
    private let recordsKey: String
    private let orderKey: String
    private var mutations: [HiddenMediaIdentity: HiddenMediaMutation] = [:]

    public init(
        defaults: UserDefaults = .standard,
        recordsKey: String = "hiddenMedia.mutations",
        orderKey: String = "hiddenMedia.sectionOrder"
    ) {
        self.defaults = defaults
        self.recordsKey = recordsKey
        self.orderKey = orderKey
        sectionOrder = Self.loadOrder(defaults: defaults, key: orderKey)
        load()
    }

    public var activeIdentities: [HiddenMediaIdentity] {
        mutations.values.filter(\.isHidden).map(\.identity)
    }

    public func setHidden(
        _ isHidden: Bool,
        identity: HiddenMediaIdentity,
        at date: Date = Date(),
        relatedCatalogID: String? = nil
    ) {
        apply(HiddenMediaMutation(
            identity: identity,
            isHidden: isHidden,
            modifiedAt: date,
            relatedCatalogID: relatedCatalogID ?? mutations[identity]?.relatedCatalogID
        ))
    }

    public func choose(_ candidate: HiddenMediaCandidate) {
        setHidden(true, identity: candidate.identity, relatedCatalogID: candidate.relatedCatalogID)
        pendingCandidates = []
    }

    public func requestHide(_ candidates: [HiddenMediaCandidate]) {
        let visible = candidates.filter { !snapshot.contains($0.identity) }
        if visible.count == 1, let candidate = visible.first {
            choose(candidate)
        } else {
            pendingCandidates = visible
        }
    }

    public func moveSections(fromOffsets source: IndexSet, toOffset destination: Int) {
        sectionOrder.move(fromOffsets: source, toOffset: destination)
        defaults.set(sectionOrder.map(\.rawValue), forKey: orderKey)
    }

    public func applyRemote(_ remote: [HiddenMediaMutation]) {
        lastRemoteApplyTime = Date()
        var changed = false
        for mutation in remote {
            let current = mutations[mutation.identity]
            guard current == nil || current!.modifiedAt < mutation.modifiedAt else { continue }
            mutations[mutation.identity] = mutation
            changed = true
        }
        if changed { save() }
    }

    public func exportMutations() -> [HiddenMediaMutation] {
        Array(mutations.values)
    }

    public func hiddenLibraryIdentity(catalogID: String, sourceKey: String) -> HiddenMediaIdentity? {
        mutations.values.first {
            $0.isHidden &&
            $0.identity.kind == .track &&
            $0.identity.sourceCompositeKey == sourceKey &&
            $0.relatedCatalogID == catalogID
        }?.identity
    }

    public func removeMissing(kind: HiddenMediaKind, sourceKey: String, survivingItemIDs: Set<String>) {
        let missing = mutations.values.compactMap { mutation in
            mutation.isHidden &&
            mutation.identity.kind == kind &&
            mutation.identity.sourceCompositeKey == sourceKey &&
            !survivingItemIDs.contains(mutation.identity.itemID)
                ? mutation.identity
                : nil
        }
        for identity in missing {
            setHidden(false, identity: identity)
        }
    }

    private func apply(_ mutation: HiddenMediaMutation) {
        guard mutations[mutation.identity]?.modifiedAt ?? .distantPast < mutation.modifiedAt else { return }
        mutations[mutation.identity] = mutation
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: recordsKey),
              let values = try? JSONDecoder().decode([HiddenMediaMutation].self, from: data) else { return }
        mutations = Dictionary(values.map { ($0.identity, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.modifiedAt >= rhs.modifiedAt ? lhs : rhs
        })
        updateSnapshot()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(Array(mutations.values)), forKey: recordsKey)
        updateSnapshot()
    }

    private func updateSnapshot() {
        snapshot = HiddenMediaSnapshot(identities: Set(activeIdentities))
    }

    private static func loadOrder(defaults: UserDefaults, key: String) -> [HiddenMediaKind] {
        let saved = (defaults.stringArray(forKey: key) ?? []).compactMap(HiddenMediaKind.init(rawValue:))
        return saved.count == HiddenMediaKind.allCases.count && Set(saved).count == saved.count
            ? saved
            : HiddenMediaKind.allCases
    }
}

public extension HiddenMediaIdentity {
    init?(_ track: Track) {
        guard let sourceKey = track.sourceCompositeKey, !sourceKey.isEmpty else { return nil }
        self.init(kind: .track, itemID: track.id, sourceCompositeKey: sourceKey)
    }

    init?(_ album: Album) {
        guard let sourceKey = album.sourceCompositeKey, !sourceKey.isEmpty else { return nil }
        self.init(kind: .album, itemID: album.id, sourceCompositeKey: sourceKey)
    }

    init?(_ artist: Artist) {
        guard let sourceKey = artist.sourceCompositeKey, !sourceKey.isEmpty else { return nil }
        self.init(kind: .artist, itemID: artist.id, sourceCompositeKey: sourceKey)
    }

    init?(_ playlist: Playlist) {
        guard let sourceKey = playlist.sourceCompositeKey, !sourceKey.isEmpty else { return nil }
        self.init(kind: .playlist, itemID: playlist.id, sourceCompositeKey: sourceKey)
    }
}
