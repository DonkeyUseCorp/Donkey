import Foundation
@preconcurrency import MusicKit

/// One catalog search result the planner can play: a typed kind plus the catalog id, so later calls
/// match on structured fields, never on free text.
public struct MusicSearchHit: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case song, album, playlist, station
    }

    public var kind: Kind
    public var id: String
    public var title: String
    /// Artist for songs/albums, curator for playlists; empty when the kind has none (stations).
    public var artist: String
    /// The song's album title; empty for other kinds.
    public var album: String

    public init(kind: Kind, id: String, title: String, artist: String = "", album: String = "") {
        self.kind = kind
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
    }
}

/// One playlist in the user's music library, by typed id — what playlist tools list, create, and
/// add to.
public struct MusicPlaylistSummary: Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One entry inside a library playlist, for reporting and verification after edits.
public struct MusicPlaylistEntry: Equatable, Sendable {
    public var title: String
    public var artist: String

    public init(title: String, artist: String = "") {
        self.title = title
        self.artist = artist
    }
}

/// Queue repeat setting, by the names the planner uses.
public enum MusicRepeatSetting: String, Sendable {
    case off, one, all
}

/// A point-in-time read of the playback engine, with optional advancement evidence: when
/// `positionAdvancing` is non-nil the position was sampled twice, and `true` means audio is really
/// progressing — the only trustworthy "it is playing" signal (a status string alone can lie).
/// Shuffle/repeat are nil when the player has not reported them (nothing queued yet).
public struct MusicPlaybackSnapshot: Equatable, Sendable {
    public enum Status: String, Sendable {
        case playing, paused, stopped, interrupted, seeking, unknown
    }

    public var status: Status
    public var title: String?
    public var artist: String?
    public var positionSeconds: Double
    public var positionAdvancing: Bool?
    public var shuffleOn: Bool?
    public var repeatSetting: MusicRepeatSetting?

    public init(
        status: Status,
        title: String? = nil,
        artist: String? = nil,
        positionSeconds: Double = 0,
        positionAdvancing: Bool? = nil,
        shuffleOn: Bool? = nil,
        repeatSetting: MusicRepeatSetting? = nil
    ) {
        self.status = status
        self.title = title
        self.artist = artist
        self.positionSeconds = positionSeconds
        self.positionAdvancing = positionAdvancing
        self.shuffleOn = shuffleOn
        self.repeatSetting = repeatSetting
    }
}

/// Why a music operation failed, with the exact actionable cause in the message — these strings go
/// straight to the thread and the user-facing summary, so they must name what to fix, not just that
/// something failed.
public enum MusicPlaybackError: Error, Equatable, CustomStringConvertible {
    /// Media & Apple Music permission missing/denied for this app.
    case notAuthorized(String)
    /// No active Apple Music subscription / not signed in for catalog playback.
    case subscriptionRequired(String)
    /// MusicKit could not get its developer token — a signing/provisioning problem, not a user one.
    case developerTokenUnavailable(String)
    /// The query or id matched nothing playable.
    case notFound(String)
    /// Playback was issued but position never advanced.
    case playbackDidNotStart(String)
    /// Any other request failure, with the underlying error text.
    case requestFailed(String)

    public var description: String {
        switch self {
        case let .notAuthorized(detail): return detail
        case let .subscriptionRequired(detail): return detail
        case let .developerTokenUnavailable(detail): return detail
        case let .notFound(detail): return detail
        case let .playbackDidNotStart(detail): return detail
        case let .requestFailed(detail): return detail
        }
    }
}

/// The native music boundary: catalog search, playback, transport, and state — everything the music
/// skill needs, with no Music-app GUI or AppleScript involved. The app-facing tools talk to this
/// protocol; `MusicKitPlaybackService` is the real implementation and tests substitute a fake.
@MainActor
public protocol MusicPlaybackServicing {
    func search(query: String, limit: Int) async throws -> [MusicSearchHit]
    /// Plays one specific catalog item and returns a snapshot with advancement evidence.
    func play(kind: MusicSearchHit.Kind, id: String) async throws -> MusicPlaybackSnapshot
    /// One-shot search + play: ranks hits (preferred kind first when given, else song → album →
    /// playlist → station, each in catalog relevance order) and plays the top match.
    func playTopMatch(query: String, preferredKind: MusicSearchHit.Kind?) async throws
        -> (hit: MusicSearchHit, snapshot: MusicPlaybackSnapshot)
    /// Inserts a catalog item into the play queue without interrupting what's playing. Stations
    /// cannot be queued (they replace the queue) — the tool layer rejects them before this call.
    func enqueue(kind: MusicSearchHit.Kind, id: String, next: Bool) async throws -> MusicPlaybackSnapshot
    func pause() async throws -> MusicPlaybackSnapshot
    func resume() async throws -> MusicPlaybackSnapshot
    func stop() async throws -> MusicPlaybackSnapshot
    func skipToNext() async throws -> MusicPlaybackSnapshot
    func skipToPrevious() async throws -> MusicPlaybackSnapshot
    /// Jumps the play position to an absolute second offset in the current entry (clamped at 0).
    func seek(toSeconds: Double) async throws -> MusicPlaybackSnapshot
    /// Moves the play position relatively — positive fast-forwards, negative rewinds (clamped at 0).
    func seek(bySeconds: Double) async throws -> MusicPlaybackSnapshot
    func setShuffle(_ enabled: Bool) async throws -> MusicPlaybackSnapshot
    func setRepeat(_ setting: MusicRepeatSetting) async throws -> MusicPlaybackSnapshot
    /// Samples the position over ~1s so the snapshot carries advancement evidence.
    func status() async -> MusicPlaybackSnapshot
    /// The user's library playlists, newest context first as the platform returns them.
    func libraryPlaylists(limit: Int) async throws -> [MusicPlaylistSummary]
    func createPlaylist(name: String, description: String?) async throws -> MusicPlaylistSummary
    /// Adds catalog songs (ids from `search`) to a library playlist.
    func addToPlaylist(playlistID: String, songIDs: [String]) async throws
    func playlistEntries(playlistID: String, limit: Int) async throws -> [MusicPlaylistEntry]
}

/// MusicKit-backed implementation. Plays through `ApplicationMusicPlayer` in this process — the
/// Music app is never launched, focused, scripted, or clicked.
///
/// Requirements this surface makes explicit when missing (instead of failing generically):
/// - Media & Apple Music consent (`MusicAuthorization`, needs `NSAppleMusicUsageDescription`).
/// - A MusicKit developer token: the app must be signed with a real development identity and its
///   bundle id enabled for MusicKit — an ad-hoc-signed build cannot get a token.
/// - An active Apple Music subscription on this Mac's Apple ID for catalog playback.
@MainActor
public final class MusicKitPlaybackService: MusicPlaybackServicing {
    private var player: ApplicationMusicPlayer { .shared }

    public init() {}

    public func search(query: String, limit: Int) async throws -> [MusicSearchHit] {
        try await ensureAuthorized()
        var request = MusicCatalogSearchRequest(
            term: query,
            types: [Song.self, Album.self, Playlist.self, Station.self]
        )
        request.limit = max(1, min(limit, 25))
        let response: MusicCatalogSearchResponse
        do {
            response = try await request.response()
        } catch {
            throw Self.mapped(error)
        }
        var hits: [MusicSearchHit] = []
        hits += response.songs.map {
            MusicSearchHit(kind: .song, id: $0.id.rawValue, title: $0.title, artist: $0.artistName, album: $0.albumTitle ?? "")
        }
        hits += response.albums.map {
            MusicSearchHit(kind: .album, id: $0.id.rawValue, title: $0.title, artist: $0.artistName)
        }
        hits += response.playlists.map {
            MusicSearchHit(kind: .playlist, id: $0.id.rawValue, title: $0.name, artist: $0.curatorName ?? "")
        }
        hits += response.stations.map {
            MusicSearchHit(kind: .station, id: $0.id.rawValue, title: $0.name)
        }
        return hits
    }

    public func play(kind: MusicSearchHit.Kind, id: String) async throws -> MusicPlaybackSnapshot {
        try await ensureAuthorized()
        do {
            switch kind {
            case .song:
                try await ensureSubscribed()
                let song = try await firstCatalogItem(
                    MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id)), id: id
                )
                player.queue = ApplicationMusicPlayer.Queue(for: [song])
            case .album:
                try await ensureSubscribed()
                let album = try await firstCatalogItem(
                    MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(id)), id: id
                )
                player.queue = ApplicationMusicPlayer.Queue(for: [album])
            case .playlist:
                // Library first: "play my X playlist" ids come from libraryPlaylists, play without
                // a catalog subscription, and don't exist in the catalog. A miss falls through to
                // the catalog lookup, which does require a subscription.
                if let library = try await Self.fetchLibraryPlaylist(id: id) {
                    player.queue = ApplicationMusicPlayer.Queue(for: [library])
                } else {
                    try await ensureSubscribed()
                    let playlist = try await firstCatalogItem(
                        MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(id)), id: id
                    )
                    player.queue = ApplicationMusicPlayer.Queue(for: [playlist])
                }
            case .station:
                try await ensureSubscribed()
                let station = try await firstCatalogItem(
                    MusicCatalogResourceRequest<Station>(matching: \.id, equalTo: MusicItemID(id)), id: id
                )
                player.queue = ApplicationMusicPlayer.Queue(for: [station])
            }
        } catch let error as MusicPlaybackError {
            throw error
        } catch {
            throw Self.mapped(error)
        }
        return try await startAndVerify(describedAs: "\(kind.rawValue) \(id)")
    }

    public func playTopMatch(query: String, preferredKind: MusicSearchHit.Kind?) async throws
        -> (hit: MusicSearchHit, snapshot: MusicPlaybackSnapshot) {
        try await ensureAuthorized()
        // Library first: owned/downloaded content plays without a catalog subscription and is
        // instant, so a broad term (an artist, an album, a saved playlist) plays whatever the user
        // already owns before reaching for the catalog. A library miss or search error falls
        // through to the catalog path.
        if let owned = try? await Self.queueFirstLibraryMatch(query: query, preferredKind: preferredKind) {
            return (owned, try await startAndVerify(describedAs: "\(owned.kind.rawValue) \"\(owned.title)\""))
        }
        let hits = try await search(query: query, limit: 10)
        guard let hit = Self.topMatch(in: hits, preferredKind: preferredKind) else {
            throw MusicPlaybackError.notFound(
                "Apple Music catalog search found nothing playable for \"\(query)\"."
            )
        }
        return (hit, try await play(kind: hit.kind, id: hit.id))
    }

    /// Starts playback for the already-loaded queue and samples the position until it advances —
    /// the only trustworthy "it really played" signal. Throws a typed `playbackDidNotStart` (not a
    /// generic failure) naming what to check when the position never moves.
    private func startAndVerify(describedAs description: String) async throws -> MusicPlaybackSnapshot {
        do {
            try await Self.startPlayback()
        } catch {
            throw Self.mapped(error)
        }
        let snapshot = await snapshotWithAdvancementEvidence(maxTicks: 5)
        guard snapshot.positionAdvancing == true else {
            throw MusicPlaybackError.playbackDidNotStart(
                "Playback was issued for \(description) but the position never advanced "
                    + "(status=\(snapshot.status.rawValue), position=\(String(format: "%.1f", snapshot.positionSeconds))s). "
                    + "The item may be unavailable in this storefront, or Apple Music is not usable on this Mac."
            )
        }
        return snapshot
    }

    /// Searches the user's own library and loads the top match into the queue, returning a hit that
    /// describes it — or nil when the library has nothing matching. Owned/downloaded content plays
    /// without a catalog subscription, so this restores the local-first behavior the native path
    /// replaced. nonisolated so the non-Sendable request/player machinery stays in one region.
    private nonisolated static func queueFirstLibraryMatch(
        query: String,
        preferredKind: MusicSearchHit.Kind?
    ) async throws -> MusicSearchHit? {
        var request = MusicLibrarySearchRequest(term: query, types: [Song.self, Album.self, Playlist.self])
        request.limit = 10
        let response = try await request.response()
        let player = ApplicationMusicPlayer.shared
        // Prefer the requested kind, then song → album → playlist (the library has no stations).
        let order: [MusicSearchHit.Kind]
        if let preferredKind {
            order = [preferredKind] + MusicSearchHit.Kind.allCases.filter { $0 != preferredKind }
        } else {
            order = MusicSearchHit.Kind.allCases
        }
        for kind in order {
            switch kind {
            case .song:
                if let song = response.songs.first {
                    player.queue = ApplicationMusicPlayer.Queue(for: [song])
                    return MusicSearchHit(
                        kind: .song, id: song.id.rawValue, title: song.title,
                        artist: song.artistName, album: song.albumTitle ?? ""
                    )
                }
            case .album:
                if let album = response.albums.first {
                    player.queue = ApplicationMusicPlayer.Queue(for: [album])
                    return MusicSearchHit(kind: .album, id: album.id.rawValue, title: album.title, artist: album.artistName)
                }
            case .playlist:
                if let playlist = response.playlists.first {
                    player.queue = ApplicationMusicPlayer.Queue(for: [playlist])
                    return MusicSearchHit(kind: .playlist, id: playlist.id.rawValue, title: playlist.name, artist: playlist.curatorName ?? "")
                }
            case .station:
                continue
            }
        }
        return nil
    }

    /// Preferred kind first when given; otherwise songs, then albums, playlists, stations — each in
    /// the catalog's own relevance order. Pure ranking on typed fields.
    static func topMatch(in hits: [MusicSearchHit], preferredKind: MusicSearchHit.Kind?) -> MusicSearchHit? {
        if let preferredKind, let preferred = hits.first(where: { $0.kind == preferredKind }) {
            return preferred
        }
        for kind in MusicSearchHit.Kind.allCases {
            if let hit = hits.first(where: { $0.kind == kind }) {
                return hit
            }
        }
        return nil
    }

    public func enqueue(kind: MusicSearchHit.Kind, id: String, next: Bool) async throws -> MusicPlaybackSnapshot {
        try await ensureAuthorized()
        do {
            switch kind {
            case .song:
                try await ensureSubscribed()
                let song = try await firstCatalogItem(
                    MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id)), id: id
                )
                try await Self.insertIntoQueue(song, next: next)
            case .album:
                try await ensureSubscribed()
                let album = try await firstCatalogItem(
                    MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(id)), id: id
                )
                try await Self.insertIntoQueue(album, next: next)
            case .playlist:
                // Owned library playlists queue without a subscription; a miss needs the catalog.
                if let library = try await Self.fetchLibraryPlaylist(id: id) {
                    try await Self.insertIntoQueue(library, next: next)
                } else {
                    try await ensureSubscribed()
                    let playlist = try await firstCatalogItem(
                        MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(id)), id: id
                    )
                    try await Self.insertIntoQueue(playlist, next: next)
                }
            case .station:
                throw MusicPlaybackError.requestFailed(
                    "Stations cannot be queued — a station replaces the queue. Play it with music.play instead."
                )
            }
        } catch let error as MusicPlaybackError {
            throw error
        } catch {
            throw Self.mapped(error)
        }
        return currentSnapshot()
    }

    public func pause() async throws -> MusicPlaybackSnapshot {
        player.pause()
        return currentSnapshot()
    }

    public func resume() async throws -> MusicPlaybackSnapshot {
        do {
            try await Self.startPlayback()
        } catch {
            throw Self.mapped(error)
        }
        return await snapshotWithAdvancementEvidence(maxTicks: 3)
    }

    public func stop() async throws -> MusicPlaybackSnapshot {
        player.stop()
        return currentSnapshot()
    }

    public func skipToNext() async throws -> MusicPlaybackSnapshot {
        do {
            try await Self.advanceQueue(forward: true)
        } catch {
            throw Self.mapped(error)
        }
        return await snapshotWithAdvancementEvidence(maxTicks: 3)
    }

    public func skipToPrevious() async throws -> MusicPlaybackSnapshot {
        do {
            try await Self.advanceQueue(forward: false)
        } catch {
            throw Self.mapped(error)
        }
        return await snapshotWithAdvancementEvidence(maxTicks: 3)
    }

    public func seek(toSeconds: Double) async throws -> MusicPlaybackSnapshot {
        player.playbackTime = max(0, toSeconds)
        return currentSnapshot()
    }

    public func seek(bySeconds: Double) async throws -> MusicPlaybackSnapshot {
        player.playbackTime = max(0, player.playbackTime + bySeconds)
        return currentSnapshot()
    }

    public func setShuffle(_ enabled: Bool) async throws -> MusicPlaybackSnapshot {
        player.state.shuffleMode = enabled ? .songs : .off
        return currentSnapshot()
    }

    public func setRepeat(_ setting: MusicRepeatSetting) async throws -> MusicPlaybackSnapshot {
        switch setting {
        case .off: player.state.repeatMode = MusicPlayer.RepeatMode.none
        case .one: player.state.repeatMode = .one
        case .all: player.state.repeatMode = .all
        }
        return currentSnapshot()
    }

    public func status() async -> MusicPlaybackSnapshot {
        await snapshotWithAdvancementEvidence(maxTicks: 2)
    }

    // MARK: - Playlists

    /// MusicKit's library WRITE surface (`MusicLibrary.createPlaylist`/`add`/`edit`) is
    /// `@available(macOS, unavailable)`, so on macOS reads go through `MusicLibraryRequest` and
    /// writes go through the Apple Music REST API via `MusicDataRequest` (which signs requests with
    /// the same developer/user tokens). Removing tracks and deleting playlists have no public API on
    /// any platform — callers get a typed unsupported error path via the tool layer, never a fake
    /// success.

    public func libraryPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] {
        try await ensureAuthorized()
        do {
            return try await Self.fetchLibraryPlaylists(limit: max(1, min(limit, 100)))
        } catch {
            throw Self.mapped(error)
        }
    }

    public func createPlaylist(name: String, description: String?) async throws -> MusicPlaylistSummary {
        try await ensureAuthorized()
        var attributes: [String: Any] = ["name": name]
        if let description, !description.isEmpty {
            attributes["description"] = description
        }
        let body: [String: Any] = ["attributes": attributes]
        var urlRequest = URLRequest(url: Self.libraryPlaylistsURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let response: (data: Data, httpStatus: Int)
        do {
            response = try await Self.musicAPIResponse(urlRequest)
        } catch {
            throw Self.mapped(error)
        }
        if let created = Self.parsePlaylistSummaries(from: response.data).first {
            return created
        }
        // The write reply was ambiguous (no playlist in the body). Confirm by reading the library:
        // a matching playlist means the create actually landed; its absence makes this a provably
        // failed create, reported with the exact cause instead of an empty mystery.
        if let confirmed = (try? await Self.fetchLibraryPlaylists(limit: 100))?.first(where: { $0.name == name }) {
            return confirmed
        }
        throw MusicPlaybackError.requestFailed(
            Self.playlistCreateFailureDetail(name: name, httpStatus: response.httpStatus, body: response.data)
        )
    }

    /// The failure detail when a playlist create returned no playlist: names the HTTP status, the
    /// response body (or its absence), and the verification-read result, plus a do-not-retry
    /// directive — a failure summary must state the exact cause, and this one must also stop the
    /// planner from re-issuing the same doomed call.
    static func playlistCreateFailureDetail(name: String, httpStatus: Int, body: Data) -> String {
        let bodyDetail = body.isEmpty
            ? "an empty body"
            : "body: \(String(decoding: body.prefix(300), as: UTF8.self))"
        return "Playlist create for \"\(name)\" failed: the Apple Music API returned HTTP \(httpStatus) "
            + "with \(bodyDetail), and a follow-up library read found no playlist named \"\(name)\". "
            + "Do not retry the same call — report this exact cause to the user."
    }

    public func addToPlaylist(playlistID: String, songIDs: [String]) async throws {
        try await ensureAuthorized()
        guard !songIDs.isEmpty else {
            throw MusicPlaybackError.requestFailed("No song ids given to add to playlist \(playlistID).")
        }
        let body: [String: Any] = ["data": songIDs.map { ["id": $0, "type": "songs"] }]
        var urlRequest = URLRequest(
            url: Self.libraryPlaylistsURL.appendingPathComponent(playlistID).appendingPathComponent("tracks")
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            _ = try await Self.musicAPIResponse(urlRequest)
        } catch {
            throw Self.mapped(error)
        }
    }

    public func playlistEntries(playlistID: String, limit: Int) async throws -> [MusicPlaylistEntry] {
        try await ensureAuthorized()
        var components = URLComponents(
            url: Self.libraryPlaylistsURL.appendingPathComponent(playlistID).appendingPathComponent("tracks"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: String(max(1, min(limit, 100))))]
        guard let url = components?.url else {
            throw MusicPlaybackError.requestFailed("Could not build the playlist tracks URL for \(playlistID).")
        }
        let data: Data
        do {
            data = try await Self.musicAPIResponse(URLRequest(url: url)).data
        } catch let error as MusicDataRequest.Error where error.status == 404 {
            // An empty library playlist 404s on /tracks rather than returning an empty list.
            return []
        } catch {
            throw Self.mapped(error)
        }
        return Self.parsePlaylistEntries(from: data)
    }

    private static let libraryPlaylistsURL = URL(string: "https://api.music.apple.com/v1/me/library/playlists")!

    /// Both wire parsers are lenient on extra fields and strict on the ones they report — they parse
    /// the Apple Music API's documented `data[].attributes` shape.
    static func parsePlaylistSummaries(from data: Data) -> [MusicPlaylistSummary] {
        struct Wire: Decodable {
            struct Item: Decodable {
                struct Attributes: Decodable { var name: String? }
                var id: String
                var attributes: Attributes?
            }
            var data: [Item]
        }
        let items = (try? JSONDecoder().decode(Wire.self, from: data))?.data ?? []
        return items.map { MusicPlaylistSummary(id: $0.id, name: $0.attributes?.name ?? $0.id) }
    }

    static func parsePlaylistEntries(from data: Data) -> [MusicPlaylistEntry] {
        struct Wire: Decodable {
            struct Item: Decodable {
                struct Attributes: Decodable {
                    var name: String?
                    var artistName: String?
                }
                var attributes: Attributes?
            }
            var data: [Item]
        }
        let items = (try? JSONDecoder().decode(Wire.self, from: data))?.data ?? []
        return items.compactMap { item in
            guard let name = item.attributes?.name else { return nil }
            return MusicPlaylistEntry(title: name, artist: item.attributes?.artistName ?? "")
        }
    }

    /// Runs an Apple Music API request signed by MusicKit (developer + user tokens), keeping the
    /// HTTP status so an ambiguous write can be reported with its exact cause. nonisolated so the
    /// non-Sendable request machinery stays within one region (same rule as the player helpers).
    private nonisolated static func musicAPIResponse(_ urlRequest: URLRequest) async throws -> (data: Data, httpStatus: Int) {
        let response = try await MusicDataRequest(urlRequest: urlRequest).response()
        return (response.data, response.urlResponse.statusCode)
    }

    private nonisolated static func fetchLibraryPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] {
        var request = MusicLibraryRequest<Playlist>()
        request.limit = limit
        let response = try await request.response()
        return response.items.map { MusicPlaylistSummary(id: $0.id.rawValue, name: $0.name) }
    }

    private nonisolated static func fetchLibraryPlaylist(id: String) async throws -> Playlist? {
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        return try await request.response().items.first
    }

    // MARK: - Internals

    /// The player's async methods are nonisolated on a non-Sendable class, so a main-actor caller
    /// cannot await them on a stored reference without "sending" the player across the boundary.
    /// These helpers resolve `.shared` inside the nonisolated region, keeping the instance local.
    private nonisolated static func startPlayback() async throws {
        try await ApplicationMusicPlayer.shared.play()
    }

    private nonisolated static func advanceQueue(forward: Bool) async throws {
        if forward {
            try await ApplicationMusicPlayer.shared.skipToNextEntry()
        } else {
            try await ApplicationMusicPlayer.shared.skipToPreviousEntry()
        }
    }

    private nonisolated static func insertIntoQueue(_ item: some PlayableMusicItem, next: Bool) async throws {
        try await ApplicationMusicPlayer.shared.queue.insert(item, position: next ? .afterCurrentEntry : .tail)
    }

    private func ensureAuthorized() async throws {
        switch MusicAuthorization.currentStatus {
        case .authorized:
            return
        case .notDetermined:
            let status = await MusicAuthorization.request()
            guard status == .authorized else {
                throw MusicPlaybackError.notAuthorized(
                    "Media & Apple Music access was not granted (status: \(status))."
                )
            }
        case .denied:
            throw MusicPlaybackError.notAuthorized(
                "Media & Apple Music access is denied for this app. Enable it in "
                    + "System Settings → Privacy & Security → Media & Apple Music."
            )
        case .restricted:
            throw MusicPlaybackError.notAuthorized(
                "Media & Apple Music access is restricted on this Mac (parental controls or a profile)."
            )
        @unknown default:
            throw MusicPlaybackError.notAuthorized(
                "Media & Apple Music access is unavailable (status: \(MusicAuthorization.currentStatus))."
            )
        }
    }

    private func ensureSubscribed() async throws {
        let subscription: MusicSubscription
        do {
            subscription = try await MusicSubscription.current
        } catch {
            throw Self.mapped(error)
        }
        guard subscription.canPlayCatalogContent else {
            throw MusicPlaybackError.subscriptionRequired(
                "This Mac's Apple ID cannot play Apple Music catalog content — no active subscription, "
                    + "or Music is not signed in."
            )
        }
    }

    private func firstCatalogItem<Item: MusicItem & Decodable>(
        _ request: MusicCatalogResourceRequest<Item>,
        id: String
    ) async throws -> Item {
        let response: MusicCatalogResourceResponse<Item>
        do {
            response = try await request.response()
        } catch {
            throw Self.mapped(error)
        }
        guard let item = response.items.first else {
            throw MusicPlaybackError.notFound("No Apple Music catalog item with id \(id).")
        }
        return item
    }

    private func currentSnapshot(positionAdvancing: Bool? = nil) -> MusicPlaybackSnapshot {
        MusicPlaybackSnapshot(
            status: Self.status(from: player.state.playbackStatus),
            title: player.queue.currentEntry?.title,
            artist: player.queue.currentEntry?.subtitle,
            positionSeconds: player.playbackTime,
            positionAdvancing: positionAdvancing,
            shuffleOn: player.state.shuffleMode.map { $0 == .songs },
            repeatSetting: Self.repeatSetting(from: player.state.repeatMode)
        )
    }

    private static func repeatSetting(from mode: MusicPlayer.RepeatMode?) -> MusicRepeatSetting? {
        guard let mode else { return nil }
        switch mode {
        case .none: return .off
        case .one: return .one
        case .all: return .all
        @unknown default: return nil
        }
    }

    /// Samples the position every ~0.7s until it advances or the tick budget runs out. Playback that
    /// is buffering reports position 0 for the first second or two, so a single early sample would
    /// misread a fine start as a failure.
    private func snapshotWithAdvancementEvidence(maxTicks: Int) async -> MusicPlaybackSnapshot {
        let initialPosition = player.playbackTime
        var lastPosition = initialPosition
        for _ in 0..<maxTicks {
            try? await Task.sleep(nanoseconds: 700_000_000)
            lastPosition = player.playbackTime
            if lastPosition > initialPosition {
                return currentSnapshot(positionAdvancing: true)
            }
        }
        return currentSnapshot(positionAdvancing: lastPosition > initialPosition)
    }

    private static func status(from playbackStatus: MusicPlayer.PlaybackStatus) -> MusicPlaybackSnapshot.Status {
        switch playbackStatus {
        case .playing: return .playing
        case .paused: return .paused
        case .stopped: return .stopped
        case .interrupted: return .interrupted
        case .seekingForward, .seekingBackward: return .seeking
        @unknown default: return .unknown
        }
    }

    /// Maps a MusicKit failure to the exact actionable cause. Matching is on typed error values;
    /// the token-error fallback inspects the error's own text only to classify a framework error
    /// string, never user input.
    private static func mapped(_ error: Error) -> MusicPlaybackError {
        if let error = error as? MusicPlaybackError {
            return error
        }
        if let apiError = error as? MusicDataRequest.Error {
            let detail = apiError.detailText.isEmpty ? apiError.title : apiError.detailText
            switch apiError.status {
            case 401, 403:
                return .notAuthorized(
                    "Apple Music API rejected the request (HTTP \(apiError.status): \(detail)) — "
                        + "the user token or library permission is missing."
                )
            case 404:
                return .notFound("Apple Music API found nothing at that id (HTTP 404: \(detail)).")
            default:
                return .requestFailed("Apple Music API error (HTTP \(apiError.status): \(detail)).")
            }
        }
        if let tokenError = error as? MusicTokenRequestError {
            switch tokenError {
            case .developerTokenRequestFailed:
                return .developerTokenUnavailable(
                    "MusicKit could not get a developer token. The app must be signed with a real "
                        + "development identity (not ad-hoc) and its bundle id must have the MusicKit "
                        + "app service enabled in the Apple Developer portal."
                )
            case .userNotSignedIn:
                return .subscriptionRequired("No Apple ID is signed in for Apple Music on this Mac.")
            case .privacyAcknowledgementRequired:
                return .subscriptionRequired(
                    "Apple Music needs its privacy prompt acknowledged — open the Music app once and accept it."
                )
            case .permissionDenied:
                return .notAuthorized(
                    "Media & Apple Music access is denied for this app. Enable it in "
                        + "System Settings → Privacy & Security → Media & Apple Music."
                )
            default:
                return .requestFailed("Apple Music token request failed: \(tokenError).")
            }
        }
        return .requestFailed("Apple Music request failed: \(error.localizedDescription)")
    }
}
