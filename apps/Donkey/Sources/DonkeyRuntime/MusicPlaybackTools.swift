import DonkeyContracts
import DonkeyHarness
import Foundation

/// Native music tools registered into a `HarnessToolRegistry`: catalog search, playback, transport,
/// and playback state — all through the platform music framework, never by launching, focusing,
/// scripting, or clicking the Music app. Playback results carry their own verification (the play
/// position sampled until it advances), so a successful `music.play` is completion evidence by
/// itself and the planner can `run.complete` without a separate observation step.
@MainActor
public final class MusicPlaybackToolProvider {
    public enum ToolName {
        public static let search = "music.search"
        public static let play = "music.play"
        public static let transport = "music.transport"
        public static let status = "music.status"
        public static let playlist = "music.playlist"
    }

    /// The `music.playlist` operations, as one typed source of truth. The descriptor's action
    /// schema, the read-only exemption metadata the duplicate-action guard reads, and the dispatch
    /// switch all derive from these cases — so renaming or adding an action updates every site at
    /// once instead of silently drifting a hand-kept "list,entries" string out of sync.
    enum PlaylistAction: String, CaseIterable {
        case list, create, add, entries

        /// Pure reads (verification, not side effects) the duplicate-action guard must never block.
        var isReadOnly: Bool {
            switch self {
            case .list, .entries: return true
            case .create, .add: return false
            }
        }

        /// Human-facing `a | b | c` list for schemas and error messages.
        static var schemaList: String { allCases.map(\.rawValue).joined(separator: " | ") }

        /// Comma-separated read-only action values for `readOnlyActionsMetadataKey`.
        static var readOnlyMetadataValue: String {
            allCases.filter(\.isReadOnly).map(\.rawValue).joined(separator: ",")
        }
    }

    private let service: any MusicPlaybackServicing

    public init(service: any MusicPlaybackServicing) {
        self.service = service
    }

    public static var descriptors: [HarnessToolDescriptor] {
        [
            HarnessToolDescriptor(
                name: ToolName.search,
                pluginID: "media.music",
                summary: "Search the Apple Music catalog (songs, albums, playlists, stations) and return playable hits with typed ids. Use only when the right item is ambiguous — music.play with a query already plays the top match. For several lookups (filling a playlist), put ALL the queries in ONE call separated by \" | \" — they run concurrently; never search one song per step.",
                inputSchema: [
                    "query": "Plain words naming the music — no command phrases like \"play\". Several queries separated by \" | \" run concurrently in one call.",
                    "limit": "Max results per kind (default 5; defaults to 1 per query for multi-query calls)."
                ],
                optionalInputKeys: ["limit"],
                outputSchema: ["hits": "kind:id — title (artist), in catalog relevance order."],
                safetyClass: .readOnly
            ),
            HarnessToolDescriptor(
                name: ToolName.play,
                pluginID: "media.music",
                summary: "Play Apple Music natively — THE way to start any music playback; never script or click the Music app. Give a plain-words query (plays the top match) or a kind+id from music.search. Success means playback was verified (position advancing) — complete the run on it. With enqueue, queues the item instead of interrupting what's playing.",
                inputSchema: [
                    "query": "Plain words naming the music, e.g. \"blackpink\" or \"my heart will go on celine dion\".",
                    "kind": "song | album | playlist | station — with id, plays that exact item; with query, prefers that kind.",
                    "id": "Catalog id from music.search (requires kind).",
                    "enqueue": "next | last — queue it instead of playing now (current song keeps playing). Stations can't be queued."
                ],
                optionalInputKeys: ["query", "kind", "id", "enqueue"],
                safetyClass: .reversible,
                verificationHints: ["success already includes verified playback (position advanced)"],
                metadata: [HarnessToolDescriptor.resultIsEvidenceMetadataKey: "true"]
            ),
            HarnessToolDescriptor(
                name: ToolName.transport,
                pluginID: "media.music",
                summary: "Control native music playback: pause, resume, stop, next, previous, fast-forward/rewind, seek, shuffle, repeat.",
                inputSchema: [
                    "action": "pause | resume | stop | next | previous | forward | rewind | seek | shuffle | repeat",
                    "seconds": "forward/rewind amount (default 15), or the seek target measured from the start of the song.",
                    "mode": "shuffle: on | off — repeat: off | one | all."
                ],
                optionalInputKeys: ["seconds", "mode"],
                safetyClass: .reversible,
                metadata: [HarnessToolDescriptor.resultIsEvidenceMetadataKey: "true"]
            ),
            HarnessToolDescriptor(
                name: ToolName.status,
                pluginID: "media.music",
                summary: "Read native playback state: what's playing, position, and whether the position is advancing.",
                outputSchema: ["state": "status, title, artist, position, advancing"],
                safetyClass: .readOnly
            ),
            HarnessToolDescriptor(
                name: ToolName.playlist,
                pluginID: "media.music",
                summary: "Manage Apple Music library playlists natively: list them, create one, add catalog songs (ids from music.search), or read a playlist's entries. Play one via music.play kind=playlist id=<id>. Removing tracks and deleting playlists are NOT possible (no Apple API) — tell the user instead of attempting it.",
                inputSchema: [
                    "action": PlaylistAction.schemaList,
                    "name": "Playlist name (create).",
                    "description": "Playlist description (create, optional).",
                    "playlistID": "Library playlist id from action=list or create (add, entries).",
                    "songIDs": "Comma-separated catalog song ids from music.search (add).",
                    "limit": "Max items returned (list/entries, default 25)."
                ],
                optionalInputKeys: ["name", "description", "playlistID", "songIDs", "limit"],
                safetyClass: .reversible,
                metadata: [
                    HarnessToolDescriptor.resultIsEvidenceMetadataKey: "true",
                    HarnessToolDescriptor.readOnlyActionsMetadataKey: PlaylistAction.readOnlyMetadataValue
                ]
            )
        ]
    }

    public func makeTools() -> [HarnessTool] {
        Self.descriptors.map { descriptor in
            HarnessTool(descriptor: descriptor) { context in
                await self.execute(context)
            }
        }
    }

    private func execute(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        switch context.call.name {
        case ToolName.search: return await search(context)
        case ToolName.play: return await play(context)
        case ToolName.transport: return await transport(context)
        case ToolName.status: return await status(context)
        case ToolName.playlist: return await playlist(context)
        default:
            return result(context, status: .unknownTool, summary: "Unknown music tool.", reason: "unknownMusicTool")
        }
    }

    /// Most queries a batched search needs in one call — enough for any playlist-sized lookup
    /// while bounding the fan-out against the catalog API.
    private static let maxBatchQueries = 15

    private func search(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let queryInput = trimmed(context.call.input["query"]) else {
            return result(context, status: .invalidInput, summary: "music.search requires a query.", reason: "missingQuery")
        }
        let queries = queryInput.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let firstQuery = queries.first else {
            return result(context, status: .invalidInput, summary: "music.search requires a query.", reason: "missingQuery")
        }
        guard queries.count <= Self.maxBatchQueries else {
            return result(
                context,
                status: .invalidInput,
                summary: "music.search accepts at most \(Self.maxBatchQueries) queries per call — split the rest into a second call.",
                reason: "tooManyQueries"
            )
        }
        // Batched lookups default to the top hit per query — the playlist-filling case wants one id
        // per song, not five candidates each.
        let limit = context.call.input["limit"].flatMap(Int.init) ?? (queries.count > 1 ? 1 : 5)
        if queries.count == 1 {
            do {
                let hits = try await service.search(query: firstQuery, limit: limit)
                guard !hits.isEmpty else {
                    return result(
                        context,
                        status: .failed,
                        summary: "Apple Music catalog search found nothing for \"\(firstQuery)\".",
                        reason: "noResults"
                    )
                }
                let lines = hits.map { Self.line(for: $0) }
                return result(
                    context,
                    status: .succeeded,
                    summary: "Found \(hits.count) playable item(s) for \"\(firstQuery)\":\n" + lines.joined(separator: "\n"),
                    reason: "searched",
                    facts: ["music.search.query": firstQuery, "music.search.hitCount": String(hits.count)]
                )
            } catch {
                return failure(context, error: error)
            }
        }
        // Several queries in one call run concurrently — one planning step finds every song for a
        // playlist instead of burning a full inference per lookup. The actor only serializes the
        // cheap setup; the catalog requests themselves overlap on the network. A query that finds
        // nothing or fails is reported inline so partial results stay usable.
        let outcomes = await withTaskGroup(of: (Int, Result<[MusicSearchHit], any Error>).self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask {
                    await (index, self.searchOutcome(query: query, limit: limit))
                }
            }
            var collected: [(Int, Result<[MusicSearchHit], any Error>)] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected.sorted { $0.0 < $1.0 }
        }
        var sections: [String] = []
        var totalHits = 0
        var missed = 0
        for (index, outcome) in outcomes {
            let query = queries[index]
            switch outcome {
            case let .success(hits) where !hits.isEmpty:
                totalHits += hits.count
                sections.append("For \"\(query)\":\n" + hits.map { Self.line(for: $0) }.joined(separator: "\n"))
            case .success:
                missed += 1
                sections.append("For \"\(query)\": nothing found.")
            case let .failure(error):
                missed += 1
                let detail = (error as? MusicPlaybackError)?.description ?? String(describing: error)
                sections.append("For \"\(query)\": search failed — \(detail)")
            }
        }
        guard totalHits > 0 else {
            return result(
                context,
                status: .failed,
                summary: "Apple Music catalog search found nothing for any of the \(queries.count) queries:\n"
                    + sections.joined(separator: "\n"),
                reason: "noResults"
            )
        }
        let missedNote = missed > 0 ? ", \(missed) with no result" : ""
        return result(
            context,
            status: .succeeded,
            summary: "Searched \(queries.count) queries concurrently (\(totalHits) hit(s)\(missedNote)):\n"
                + sections.joined(separator: "\n"),
            reason: "searched",
            facts: ["music.search.queryCount": String(queries.count), "music.search.hitCount": String(totalHits)]
        )
    }

    private func searchOutcome(query: String, limit: Int) async -> Result<[MusicSearchHit], any Error> {
        do {
            return .success(try await service.search(query: query, limit: limit))
        } catch {
            return .failure(error)
        }
    }

    private func play(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        let query = trimmed(context.call.input["query"])
        let id = trimmed(context.call.input["id"])
        let kind = trimmed(context.call.input["kind"]).flatMap(MusicSearchHit.Kind.init(rawValue:))
        if let enqueue = trimmed(context.call.input["enqueue"]) {
            return await self.enqueue(context, position: enqueue, query: query, kind: kind, id: id)
        }
        do {
            let played: MusicSearchHit
            let snapshot: MusicPlaybackSnapshot
            if let id, let kind {
                snapshot = try await service.play(kind: kind, id: id)
                played = MusicSearchHit(
                    kind: kind,
                    id: id,
                    title: snapshot.title ?? id,
                    artist: snapshot.artist ?? ""
                )
            } else if let query {
                (played, snapshot) = try await service.playTopMatch(query: query, preferredKind: kind)
            } else {
                return result(
                    context,
                    status: .invalidInput,
                    summary: "music.play needs a query (plays the top match) or kind+id from music.search.",
                    reason: "missingQueryOrID"
                )
            }
            return result(
                context,
                status: .succeeded,
                summary: "Playing \(played.kind.rawValue) \"\(played.title)\""
                    + (played.artist.isEmpty ? "" : " by \(played.artist)")
                    + " — verified, position advancing (\(Self.position(snapshot))).",
                reason: "played",
                facts: [
                    "music.playing.kind": played.kind.rawValue,
                    "music.playing.id": played.id,
                    "music.playing.title": played.title,
                    "music.playing.artist": played.artist
                ]
            )
        } catch {
            return failure(context, error: error)
        }
    }

    /// Resolves the target (exact kind+id, or the top match for a query) and queues it without
    /// interrupting playback. Stations are rejected up front — queueing one replaces the queue.
    private func enqueue(
        _ context: HarnessToolExecutionContext,
        position: String,
        query: String?,
        kind: MusicSearchHit.Kind?,
        id: String?
    ) async -> HarnessToolResult {
        guard position == "next" || position == "last" else {
            return result(
                context,
                status: .invalidInput,
                summary: "music.play enqueue must be next or last, not \"\(position)\".",
                reason: "unknownEnqueuePosition"
            )
        }
        do {
            let target: MusicSearchHit
            if let id, let kind {
                target = MusicSearchHit(kind: kind, id: id, title: id)
            } else if let query {
                let hits = try await service.search(query: query, limit: 10)
                guard let hit = MusicKitPlaybackService.topMatch(in: hits, preferredKind: kind) else {
                    throw MusicPlaybackError.notFound(
                        "Apple Music catalog search found nothing queueable for \"\(query)\"."
                    )
                }
                target = hit
            } else {
                return result(
                    context,
                    status: .invalidInput,
                    summary: "music.play with enqueue needs a query or kind+id from music.search.",
                    reason: "missingQueryOrID"
                )
            }
            guard target.kind != .station else {
                return result(
                    context,
                    status: .invalidInput,
                    summary: "Stations cannot be queued — a station replaces the queue. Play it with music.play instead.",
                    reason: "stationNotQueueable"
                )
            }
            let snapshot = try await service.enqueue(kind: target.kind, id: target.id, next: position == "next")
            return result(
                context,
                status: .succeeded,
                summary: "Queued \(target.kind.rawValue) \"\(target.title)\""
                    + (target.artist.isEmpty ? "" : " by \(target.artist)")
                    + " to play \(position) — confirmed; now \(Self.describe(snapshot)).",
                reason: "queued",
                facts: ["music.queued.kind": target.kind.rawValue, "music.queued.id": target.id]
            )
        } catch {
            return failure(context, error: error)
        }
    }

    private func transport(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        let actions = "pause | resume | stop | next | previous | forward | rewind | seek | shuffle | repeat"
        guard let action = trimmed(context.call.input["action"]) else {
            return result(
                context,
                status: .invalidInput,
                summary: "music.transport requires an action: \(actions).",
                reason: "missingAction"
            )
        }
        let seconds = trimmed(context.call.input["seconds"]).flatMap(Double.init)
        let mode = trimmed(context.call.input["mode"])
        do {
            let snapshot: MusicPlaybackSnapshot
            switch action {
            case "pause": snapshot = try await service.pause()
            case "resume": snapshot = try await service.resume()
            case "stop": snapshot = try await service.stop()
            case "next": snapshot = try await service.skipToNext()
            case "previous": snapshot = try await service.skipToPrevious()
            case "forward": snapshot = try await service.seek(bySeconds: seconds ?? 15)
            case "rewind": snapshot = try await service.seek(bySeconds: -(seconds ?? 15))
            case "seek":
                guard let seconds else {
                    return result(
                        context,
                        status: .invalidInput,
                        summary: "music.transport action=seek requires seconds — the target position from the start of the song.",
                        reason: "missingSeconds"
                    )
                }
                snapshot = try await service.seek(toSeconds: seconds)
            case "shuffle":
                guard mode == "on" || mode == "off" else {
                    return result(
                        context,
                        status: .invalidInput,
                        summary: "music.transport action=shuffle requires mode: on | off.",
                        reason: "missingMode"
                    )
                }
                snapshot = try await service.setShuffle(mode == "on")
            case "repeat":
                guard let setting = mode.flatMap(MusicRepeatSetting.init(rawValue:)) else {
                    return result(
                        context,
                        status: .invalidInput,
                        summary: "music.transport action=repeat requires mode: off | one | all.",
                        reason: "missingMode"
                    )
                }
                snapshot = try await service.setRepeat(setting)
            default:
                return result(
                    context,
                    status: .invalidInput,
                    summary: "Unknown music.transport action \"\(action)\" — use \(actions).",
                    reason: "unknownAction"
                )
            }
            return result(
                context,
                status: .succeeded,
                summary: "Transport \(action) done — \(Self.describe(snapshot)).",
                reason: action
            )
        } catch {
            return failure(context, error: error)
        }
    }

    private func status(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        let snapshot = await service.status()
        return result(
            context,
            status: .succeeded,
            summary: "Playback state: \(Self.describe(snapshot)).",
            reason: "status",
            facts: ["music.status": snapshot.status.rawValue]
        )
    }

    private func playlist(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let rawAction = trimmed(context.call.input["action"]) else {
            return result(
                context,
                status: .invalidInput,
                summary: "music.playlist requires an action: \(PlaylistAction.schemaList).",
                reason: "missingAction"
            )
        }
        guard let action = PlaylistAction(rawValue: rawAction) else {
            // remove/delete are real Apple-platform gaps (no API); anything else is a typo.
            if rawAction == "remove" || rawAction == "delete" {
                return result(
                    context,
                    status: .failed,
                    summary: "Removing tracks or deleting playlists is not possible — Apple provides no API for it. "
                        + "Tell the user to do that in the Music app; do not retry.",
                    reason: "unsupportedByPlatform"
                )
            }
            return result(
                context,
                status: .invalidInput,
                summary: "Unknown music.playlist action \"\(rawAction)\" — use \(PlaylistAction.schemaList).",
                reason: "unknownAction"
            )
        }
        let limit = context.call.input["limit"].flatMap(Int.init) ?? 25
        do {
            switch action {
            case .list:
                let playlists = try await service.libraryPlaylists(limit: limit)
                guard !playlists.isEmpty else {
                    return result(context, status: .succeeded, summary: "The music library has no playlists yet.", reason: "listed")
                }
                let lines = playlists.map { "\($0.id) — \($0.name)" }
                return result(
                    context,
                    status: .succeeded,
                    summary: "Library playlists (\(playlists.count)):\n" + lines.joined(separator: "\n"),
                    reason: "listed",
                    facts: ["music.playlist.count": String(playlists.count)]
                )
            case .create:
                guard let name = trimmed(context.call.input["name"]) else {
                    return result(context, status: .invalidInput, summary: "music.playlist action=create requires a name.", reason: "missingName")
                }
                let created = try await service.createPlaylist(
                    name: name,
                    description: trimmed(context.call.input["description"])
                )
                return result(
                    context,
                    status: .succeeded,
                    summary: "Created playlist \"\(created.name)\" (id \(created.id)) — confirmed by the Apple Music API.",
                    reason: "created",
                    facts: ["music.playlist.created.id": created.id, "music.playlist.created.name": created.name]
                )
            case .add:
                guard let playlistID = trimmed(context.call.input["playlistID"]) else {
                    return result(context, status: .invalidInput, summary: "music.playlist action=add requires a playlistID.", reason: "missingPlaylistID")
                }
                let songIDs = (context.call.input["songIDs"] ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !songIDs.isEmpty else {
                    return result(
                        context,
                        status: .invalidInput,
                        summary: "music.playlist action=add requires songIDs — comma-separated catalog song ids from music.search.",
                        reason: "missingSongIDs"
                    )
                }
                try await service.addToPlaylist(playlistID: playlistID, songIDs: songIDs)
                return result(
                    context,
                    status: .succeeded,
                    summary: "Added \(songIDs.count) song(s) to playlist \(playlistID) — confirmed by the Apple Music API.",
                    reason: "added",
                    facts: ["music.playlist.added.count": String(songIDs.count)]
                )
            case .entries:
                guard let playlistID = trimmed(context.call.input["playlistID"]) else {
                    return result(context, status: .invalidInput, summary: "music.playlist action=entries requires a playlistID.", reason: "missingPlaylistID")
                }
                let entries = try await service.playlistEntries(playlistID: playlistID, limit: limit)
                guard !entries.isEmpty else {
                    return result(context, status: .succeeded, summary: "Playlist \(playlistID) is empty.", reason: "entries")
                }
                let lines = entries.map { $0.artist.isEmpty ? $0.title : "\($0.title) — \($0.artist)" }
                return result(
                    context,
                    status: .succeeded,
                    summary: "Playlist \(playlistID) entries (\(entries.count)):\n" + lines.joined(separator: "\n"),
                    reason: "entries"
                )
            }
        } catch {
            return failure(context, error: error)
        }
    }

    // MARK: - Formatting

    private static func line(for hit: MusicSearchHit) -> String {
        var line = "\(hit.kind.rawValue):\(hit.id) — \(hit.title)"
        if !hit.artist.isEmpty { line += " (\(hit.artist))" }
        if !hit.album.isEmpty { line += " [album: \(hit.album)]" }
        return line
    }

    private static func describe(_ snapshot: MusicPlaybackSnapshot) -> String {
        var parts = [snapshot.status.rawValue]
        if let title = snapshot.title, !title.isEmpty {
            let artist = snapshot.artist.flatMap { $0.isEmpty ? nil : " by \($0)" } ?? ""
            parts.append("\"\(title)\"\(artist)")
        }
        parts.append("at \(position(snapshot))")
        if let advancing = snapshot.positionAdvancing {
            parts.append(advancing ? "position advancing" : "position NOT advancing")
        }
        if let shuffleOn = snapshot.shuffleOn {
            parts.append("shuffle \(shuffleOn ? "on" : "off")")
        }
        if let repeatSetting = snapshot.repeatSetting {
            parts.append("repeat \(repeatSetting.rawValue)")
        }
        return parts.joined(separator: ", ")
    }

    private static func position(_ snapshot: MusicPlaybackSnapshot) -> String {
        String(format: "%.1fs", snapshot.positionSeconds)
    }

    /// Failure summaries carry the service's exact actionable cause (`MusicPlaybackError`
    /// descriptions name the missing permission, subscription, or signing requirement). Setup-class
    /// causes additionally carry a hard stop directive: no other tool in the run can fix a signing,
    /// consent, or subscription problem, and without the directive the planner drifts into
    /// AppleScript/GUI fallbacks the music doctrine forbids (observed: minutes of osascript attempts
    /// after a developer-token failure).
    private func failure(_ context: HarnessToolExecutionContext, error: Error) -> HarnessToolResult {
        let reason: String
        var isSetupProblem = false
        switch error as? MusicPlaybackError {
        case .notAuthorized:
            reason = "notAuthorized"
            isSetupProblem = true
        case .subscriptionRequired:
            reason = "subscriptionRequired"
            isSetupProblem = true
        case .developerTokenUnavailable:
            reason = "developerTokenUnavailable"
            isSetupProblem = true
        case .notFound: reason = "notFound"
        case .playbackDidNotStart: reason = "playbackDidNotStart"
        case .requestFailed, nil: reason = "requestFailed"
        }
        var summary = String(describing: error as? MusicPlaybackError ?? .requestFailed(error.localizedDescription))
        if isSetupProblem {
            summary += " STOP: this is a machine/account setup problem no tool in this run can fix. "
                + "Do NOT retry, and do NOT fall back to AppleScript, the Music app GUI, or a web "
                + "player. Tell the user this exact reason with conversation.respond, then run.failSafe."
        }
        return result(
            context,
            status: .failed,
            summary: summary,
            reason: reason
        )
    }

    private func result(
        _ context: HarnessToolExecutionContext,
        status: HarnessToolResultStatus,
        summary: String,
        reason: String,
        facts: [String: String] = [:]
    ) -> HarnessToolResult {
        var allFacts = facts
        if status == .succeeded {
            allFacts["lastAcceptedTool"] = context.call.name
        }
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: status,
            summary: summary,
            observations: HarnessObservationDelta(facts: allFacts),
            metadata: ["reason": reason, "source": "musickit"]
        )
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
