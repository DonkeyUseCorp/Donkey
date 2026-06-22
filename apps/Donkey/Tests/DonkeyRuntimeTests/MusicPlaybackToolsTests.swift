import DonkeyContracts
import DonkeyHarness
import Foundation
import Testing
@testable import DonkeyRuntime

@Suite
@MainActor
struct MusicPlaybackToolsTests {
    @Test
    func playByQueryReportsVerifiedPlaybackWithEvidence() async {
        let service = FakeMusicService()
        service.searchHits = [
            MusicSearchHit(kind: .song, id: "123", title: "JUMP", artist: "BLACKPINK", album: "JUMP")
        ]
        let provider = MusicPlaybackToolProvider(service: service)

        let result = await run(provider, tool: MusicPlaybackToolProvider.ToolName.play, input: ["query": "blackpink"])

        #expect(result.status == .succeeded)
        #expect(result.summary.contains("JUMP"))
        #expect(result.summary.contains("BLACKPINK"))
        #expect(result.summary.contains("position advancing"))
        #expect(result.observations.facts["music.playing.title"] == "JUMP")
        #expect(service.playedItems.map(\.id) == ["123"])
    }

    @Test
    func playByKindAndIDSkipsSearch() async {
        let service = FakeMusicService()
        let provider = MusicPlaybackToolProvider(service: service)

        let result = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.play,
            input: ["kind": "album", "id": "456"]
        )

        #expect(result.status == .succeeded)
        #expect(service.playedItems.map(\.id) == ["456"])
        #expect(service.searchQueries.isEmpty)
    }

    @Test
    func playWithoutQueryOrIDIsInvalidInput() async {
        let provider = MusicPlaybackToolProvider(service: FakeMusicService())

        let result = await run(provider, tool: MusicPlaybackToolProvider.ToolName.play, input: [:])

        #expect(result.status == .invalidInput)
    }

    @Test
    func playFailureSurfacesTheExactActionableCause() async {
        let service = FakeMusicService()
        service.playError = .developerTokenUnavailable(
            "MusicKit could not get a developer token. The app must be signed with a real "
                + "development identity (not ad-hoc) and its bundle id must have the MusicKit "
                + "app service enabled in the Apple Developer portal."
        )
        service.searchHits = [MusicSearchHit(kind: .song, id: "123", title: "JUMP", artist: "BLACKPINK")]
        let provider = MusicPlaybackToolProvider(service: service)

        let result = await run(provider, tool: MusicPlaybackToolProvider.ToolName.play, input: ["query": "blackpink"])

        #expect(result.status == .failed)
        #expect(result.metadata["reason"] == "developerTokenUnavailable")
        #expect(result.summary.contains("developer token"))
        #expect(result.summary.contains("MusicKit app service"))
    }

    @Test
    func setupClassFailuresCarryAHardStopDirective() async {
        // A signing/consent/subscription failure cannot be fixed by any tool in the run. Without an
        // imperative right in the result, the planner drifts into AppleScript/GUI fallbacks the
        // doctrine forbids (observed live: minutes of osascript attempts after a token failure).
        let causes: [MusicPlaybackError] = [
            .developerTokenUnavailable("no token"),
            .notAuthorized("denied"),
            .subscriptionRequired("no subscription")
        ]
        for cause in causes {
            let service = FakeMusicService()
            service.playError = cause
            service.searchHits = [MusicSearchHit(kind: .song, id: "1", title: "JUMP")]
            let provider = MusicPlaybackToolProvider(service: service)

            let result = await run(provider, tool: MusicPlaybackToolProvider.ToolName.play, input: ["query": "blackpink"])

            #expect(result.status == .failed)
            #expect(result.summary.contains("Do NOT retry"), "missing stop directive for \(cause)")
            #expect(result.summary.contains("run.failSafe"))
        }

        // A transient/not-found failure must NOT carry the stop directive — a better query is a
        // legitimate next step there.
        let service = FakeMusicService()
        service.playError = .notFound("nothing for that query")
        service.searchHits = [MusicSearchHit(kind: .song, id: "1", title: "JUMP")]
        let provider = MusicPlaybackToolProvider(service: service)
        let result = await run(provider, tool: MusicPlaybackToolProvider.ToolName.play, input: ["query": "blackpink"])
        #expect(!result.summary.contains("Do NOT retry"))
    }

    @Test
    func searchListsTypedHits() async {
        let service = FakeMusicService()
        service.searchHits = [
            MusicSearchHit(kind: .song, id: "1", title: "JUMP", artist: "BLACKPINK", album: "JUMP"),
            MusicSearchHit(kind: .album, id: "2", title: "BORN PINK", artist: "BLACKPINK")
        ]
        let provider = MusicPlaybackToolProvider(service: service)

        let result = await run(provider, tool: MusicPlaybackToolProvider.ToolName.search, input: ["query": "blackpink"])

        #expect(result.status == .succeeded)
        #expect(result.summary.contains("song:1 — JUMP (BLACKPINK)"))
        #expect(result.summary.contains("album:2 — BORN PINK (BLACKPINK)"))
    }

    @Test
    func transportRejectsUnknownAction() async {
        let provider = MusicPlaybackToolProvider(service: FakeMusicService())

        let result = await run(provider, tool: MusicPlaybackToolProvider.ToolName.transport, input: ["action": "louder"])

        #expect(result.status == .invalidInput)
    }

    @Test
    func transportPauseReportsResultingState() async {
        let service = FakeMusicService()
        service.snapshot = MusicPlaybackSnapshot(status: .paused, title: "JUMP", artist: "BLACKPINK", positionSeconds: 12.3)
        let provider = MusicPlaybackToolProvider(service: service)

        let result = await run(provider, tool: MusicPlaybackToolProvider.ToolName.transport, input: ["action": "pause"])

        #expect(result.status == .succeeded)
        #expect(service.transportActions == ["pause"])
        #expect(result.summary.contains("paused"))
        #expect(result.summary.contains("12.3s"))
    }

    @Test
    func transportForwardAndRewindDefaultTo15Seconds() async {
        let service = FakeMusicService()
        let provider = MusicPlaybackToolProvider(service: service)

        _ = await run(provider, tool: MusicPlaybackToolProvider.ToolName.transport, input: ["action": "forward"])
        _ = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.transport,
            input: ["action": "rewind", "seconds": "30"]
        )

        #expect(service.transportActions == ["seek(by:15.0)", "seek(by:-30.0)"])
    }

    @Test
    func transportSeekRequiresSeconds() async {
        let service = FakeMusicService()
        let provider = MusicPlaybackToolProvider(service: service)

        let missing = await run(provider, tool: MusicPlaybackToolProvider.ToolName.transport, input: ["action": "seek"])
        #expect(missing.status == .invalidInput)

        let result = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.transport,
            input: ["action": "seek", "seconds": "90"]
        )
        #expect(result.status == .succeeded)
        #expect(service.transportActions == ["seek(to:90.0)"])
    }

    @Test
    func transportShuffleAndRepeatSetModesAndReportState() async {
        let service = FakeMusicService()
        service.snapshot = MusicPlaybackSnapshot(
            status: .playing, positionSeconds: 5.0, shuffleOn: true, repeatSetting: .all
        )
        let provider = MusicPlaybackToolProvider(service: service)

        let shuffle = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.transport,
            input: ["action": "shuffle", "mode": "on"]
        )
        let repeatAll = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.transport,
            input: ["action": "repeat", "mode": "all"]
        )

        #expect(service.transportActions == ["shuffle(on)", "repeat(all)"])
        #expect(shuffle.summary.contains("shuffle on"))
        #expect(repeatAll.summary.contains("repeat all"))

        let badMode = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.transport,
            input: ["action": "repeat", "mode": "twice"]
        )
        #expect(badMode.status == .invalidInput)
    }

    @Test
    func playWithEnqueueQueuesTheTopMatchWithoutInterrupting() async {
        let service = FakeMusicService()
        service.searchHits = [
            MusicSearchHit(kind: .song, id: "123", title: "JUMP", artist: "BLACKPINK")
        ]
        let provider = MusicPlaybackToolProvider(service: service)

        let result = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.play,
            input: ["query": "blackpink jump", "enqueue": "next"]
        )

        #expect(result.status == .succeeded)
        #expect(service.playedItems.isEmpty)
        #expect(service.enqueuedItems.map(\.id) == ["123"])
        #expect(service.enqueuedItems.first?.next == true)
        #expect(result.summary.contains("Queued song \"JUMP\""))
        #expect(result.observations.facts["music.queued.id"] == "123")
    }

    @Test
    func enqueueRejectsStationsAndUnknownPositions() async {
        let service = FakeMusicService()
        service.searchHits = [MusicSearchHit(kind: .station, id: "st.1", title: "BLACKPINK Radio")]
        let provider = MusicPlaybackToolProvider(service: service)

        let station = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.play,
            input: ["query": "blackpink radio", "kind": "station", "enqueue": "last"]
        )
        #expect(station.status == .invalidInput)
        #expect(station.summary.contains("Stations cannot be queued"))

        let badPosition = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.play,
            input: ["query": "blackpink", "enqueue": "soon"]
        )
        #expect(badPosition.status == .invalidInput)
        #expect(service.enqueuedItems.isEmpty)
    }

    @Test
    func statusReportsAdvancementEvidence() async {
        let service = FakeMusicService()
        service.snapshot = MusicPlaybackSnapshot(
            status: .playing, title: "JUMP", artist: "BLACKPINK", positionSeconds: 5.0, positionAdvancing: true
        )
        let provider = MusicPlaybackToolProvider(service: service)

        let result = await run(provider, tool: MusicPlaybackToolProvider.ToolName.status, input: [:])

        #expect(result.status == .succeeded)
        #expect(result.summary.contains("position advancing"))
        #expect(result.observations.facts["music.status"] == "playing")
    }

    @Test
    func playDescriptorMarksItsResultAsEvidence() {
        let play = MusicPlaybackToolProvider.descriptors.first { $0.name == MusicPlaybackToolProvider.ToolName.play }
        #expect(play?.metadata[HarnessToolDescriptor.resultIsEvidenceMetadataKey] == "true")
    }

    @Test
    func playlistReadOnlyMetadataDerivesFromTheDispatchedActions() {
        // The duplicate-action guard's read-only exemption must stay in lockstep with the actual
        // playlist actions: list/entries are pure reads, create/add mutate. Deriving the metadata
        // from PlaylistAction (the same enum the dispatch switch consumes) makes a rename update
        // both sites at once instead of drifting a hand-kept string out of sync.
        let playlist = MusicPlaybackToolProvider.descriptors.first { $0.name == MusicPlaybackToolProvider.ToolName.playlist }
        let declared = playlist?.metadata[HarnessToolDescriptor.readOnlyActionsMetadataKey]
        #expect(declared == "list,entries")

        let exempt = Set(declared?.split(separator: ",").map(String.init) ?? [])
        for action in MusicPlaybackToolProvider.PlaylistAction.allCases {
            #expect(exempt.contains(action.rawValue) == action.isReadOnly)
        }
    }

    @Test
    func topMatchPrefersRequestedKindThenSongFirstOrder() {
        let hits = [
            MusicSearchHit(kind: .playlist, id: "p", title: "80s Hits"),
            MusicSearchHit(kind: .song, id: "s", title: "Some Song"),
            MusicSearchHit(kind: .album, id: "a", title: "Some Album")
        ]

        #expect(MusicKitPlaybackService.topMatch(in: hits, preferredKind: .playlist)?.id == "p")
        #expect(MusicKitPlaybackService.topMatch(in: hits, preferredKind: nil)?.id == "s")
        #expect(MusicKitPlaybackService.topMatch(in: [], preferredKind: nil) == nil)
    }

    @Test
    func searchRunsPipeSeparatedQueriesConcurrentlyInOneCall() async {
        // Filling a playlist must cost one planning step, not one per song: a pipe-separated query
        // fans out concurrently and reports one section per query, including the misses, so partial
        // results stay usable.
        let service = FakeMusicService()
        service.hitsByQuery = [
            "Yellow Coldplay": [MusicSearchHit(kind: .song, id: "111", title: "Yellow", artist: "Coldplay")],
            "Say My Name Destiny's Child": [MusicSearchHit(kind: .song, id: "222", title: "Say My Name", artist: "Destiny's Child")],
            "No Such Song Nobody": []
        ]
        let provider = MusicPlaybackToolProvider(service: service)

        let result = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.search,
            input: ["query": "Yellow Coldplay | Say My Name Destiny's Child | No Such Song Nobody"]
        )

        #expect(result.status == .succeeded)
        #expect(Set(service.searchQueries) == ["Yellow Coldplay", "Say My Name Destiny's Child", "No Such Song Nobody"])
        #expect(result.summary.contains("Searched 3 queries concurrently"))
        #expect(result.summary.contains("song:111"))
        #expect(result.summary.contains("song:222"))
        #expect(result.summary.contains("For \"No Such Song Nobody\": nothing found."))
        #expect(result.observations.facts["music.search.queryCount"] == "3")
        #expect(result.observations.facts["music.search.hitCount"] == "2")
    }

    @Test
    func playlistListShowsIDsAndNames() async {
        let service = FakeMusicService()
        service.playlists = [
            MusicPlaylistSummary(id: "p.111", name: "Workout"),
            MusicPlaylistSummary(id: "p.222", name: "Chill")
        ]
        let provider = MusicPlaybackToolProvider(service: service)

        let result = await run(provider, tool: MusicPlaybackToolProvider.ToolName.playlist, input: ["action": "list"])

        #expect(result.status == .succeeded)
        #expect(result.summary.contains("p.111 — Workout"))
        #expect(result.summary.contains("p.222 — Chill"))
    }

    @Test
    func playlistCreateReportsTheNewIDWithAPIConfirmation() async {
        let service = FakeMusicService()
        let provider = MusicPlaybackToolProvider(service: service)

        let result = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.playlist,
            input: ["action": "create", "name": "Blackpink Mix", "description": "by Donkey"]
        )

        #expect(result.status == .succeeded)
        #expect(service.createdPlaylists.map(\.name) == ["Blackpink Mix"])
        #expect(service.createdPlaylists.first?.description == "by Donkey")
        #expect(result.summary.contains("confirmed by the Apple Music API"))
        #expect(result.observations.facts["music.playlist.created.id"] == "p.new")
    }

    @Test
    func playlistCreateFailureDetailNamesStatusBodyAndVerificationResult() {
        let emptyBody = MusicKitPlaybackService.playlistCreateFailureDetail(
            name: "Best of 2000", httpStatus: 204, body: Data()
        )
        #expect(emptyBody.contains("HTTP 204"))
        #expect(emptyBody.contains("an empty body"))
        #expect(emptyBody.contains("found no playlist named \"Best of 2000\""))
        #expect(emptyBody.contains("Do not retry the same call"))

        let withBody = MusicKitPlaybackService.playlistCreateFailureDetail(
            name: "Best of 2000", httpStatus: 400, body: Data(#"{"errors":[{"title":"Invalid"}]}"#.utf8)
        )
        #expect(withBody.contains("HTTP 400"))
        #expect(withBody.contains(#"{"errors":[{"title":"Invalid"}]}"#))
        #expect(!withBody.contains("an empty body"))
    }

    @Test
    func playlistCreateFailureSurfacesTheExactCauseToThePlanner() async {
        // The live loop: create kept failing with an empty, cause-less message and the planner
        // plausibly retried variants for minutes. The failure the tool relays must carry the HTTP
        // status and the do-not-retry directive verbatim.
        let service = FakeMusicService()
        service.createError = .requestFailed(
            MusicKitPlaybackService.playlistCreateFailureDetail(name: "Best of 2000", httpStatus: 204, body: Data())
        )
        let provider = MusicPlaybackToolProvider(service: service)

        let result = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.playlist,
            input: ["action": "create", "name": "Best of 2000"]
        )

        #expect(result.status == .failed)
        #expect(result.metadata["reason"] == "requestFailed")
        #expect(result.summary.contains("HTTP 204"))
        #expect(result.summary.contains("Do not retry the same call"))
        #expect(service.createdPlaylists.isEmpty)
    }

    @Test
    func playlistAddParsesCommaSeparatedSongIDs() async {
        let service = FakeMusicService()
        let provider = MusicPlaybackToolProvider(service: service)

        let result = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.playlist,
            input: ["action": "add", "playlistID": "p.111", "songIDs": "123, 456 ,789"]
        )

        #expect(result.status == .succeeded)
        #expect(service.addedSongs.count == 1)
        #expect(service.addedSongs.first?.playlistID == "p.111")
        #expect(service.addedSongs.first?.songIDs == ["123", "456", "789"])
        #expect(result.summary.contains("Added 3 song(s)"))
    }

    @Test
    func playlistAddWithoutSongIDsIsInvalidInput() async {
        let provider = MusicPlaybackToolProvider(service: FakeMusicService())

        let result = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.playlist,
            input: ["action": "add", "playlistID": "p.111"]
        )

        #expect(result.status == .invalidInput)
    }

    @Test
    func playlistRemoveIsHonestlyUnsupported() async {
        // Apple ships no API for removing individual tracks. The tool must say so plainly and send the
        // user to the Music app instead of failing generically or pretending.
        let provider = MusicPlaybackToolProvider(service: FakeMusicService())

        let result = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.playlist,
            input: ["action": "remove", "playlistID": "p.111"]
        )

        #expect(result.status == .failed)
        #expect(result.metadata["reason"] == "unsupportedByPlatform")
        #expect(result.summary.contains("no API"))
    }

    @Test
    func playlistDeleteHasNoAPIAndPointsToTheGeneralRowTool() async {
        // Deleting a whole playlist has no Apple API. It is a general GUI row action, not a music tool —
        // `music.playlist` rejects `delete` and points the planner at the app-agnostic `ax.select_and_press`
        // (select the sidebar row + Delete key + confirm dialog), so there is no bespoke per-app delete here.
        let provider = MusicPlaybackToolProvider(service: FakeMusicService())

        let result = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.playlist,
            input: ["action": "delete", "name": "My Mix"]
        )

        #expect(result.status == .failed)
        #expect(result.metadata["reason"] == "noDeleteAPI")
        #expect(result.summary.contains("ax.select_and_press"))
    }

    @Test
    func playlistEntriesListsTitlesAndArtists() async {
        let service = FakeMusicService()
        service.entries = [
            MusicPlaylistEntry(title: "JUMP", artist: "BLACKPINK"),
            MusicPlaylistEntry(title: "Pink Venom", artist: "BLACKPINK")
        ]
        let provider = MusicPlaybackToolProvider(service: service)

        let result = await run(
            provider,
            tool: MusicPlaybackToolProvider.ToolName.playlist,
            input: ["action": "entries", "playlistID": "p.111"]
        )

        #expect(result.status == .succeeded)
        #expect(result.summary.contains("JUMP — BLACKPINK"))
        #expect(result.summary.contains("Pink Venom — BLACKPINK"))
    }

    @Test
    func playlistWireParsersReadTheAppleMusicAPIShape() {
        let createResponse = Data("""
        {"data":[{"id":"p.abc","type":"library-playlists","attributes":{"name":"Blackpink Mix"}}]}
        """.utf8)
        let summaries = MusicKitPlaybackService.parsePlaylistSummaries(from: createResponse)
        #expect(summaries == [MusicPlaylistSummary(id: "p.abc", name: "Blackpink Mix")])

        let tracksResponse = Data("""
        {"data":[
          {"id":"i.1","attributes":{"name":"JUMP","artistName":"BLACKPINK"}},
          {"id":"i.2","attributes":{"name":"Pink Venom","artistName":"BLACKPINK"}}
        ]}
        """.utf8)
        let entries = MusicKitPlaybackService.parsePlaylistEntries(from: tracksResponse)
        #expect(entries == [
            MusicPlaylistEntry(title: "JUMP", artist: "BLACKPINK"),
            MusicPlaylistEntry(title: "Pink Venom", artist: "BLACKPINK")
        ])

        #expect(MusicKitPlaybackService.parsePlaylistSummaries(from: Data("not json".utf8)).isEmpty)
    }

    // MARK: - Helpers

    private func run(
        _ provider: MusicPlaybackToolProvider,
        tool: String,
        input: [String: String]
    ) async -> HarnessToolResult {
        let tools = provider.makeTools()
        let harnessTool = tools.first { $0.descriptor.name == tool }!
        let context = HarnessToolExecutionContext(
            taskID: "task-1",
            call: HarnessToolCall(name: tool, input: input),
            descriptor: harnessTool.descriptor,
            worldModel: HarnessWorldModel(),
            grantedPermissions: []
        )
        return await harnessTool.execute(context)
    }
}

@MainActor
private final class FakeMusicService: MusicPlaybackServicing {
    var searchHits: [MusicSearchHit] = []
    /// Per-query results for batched-search tests; falls back to `searchHits` when a query is absent.
    var hitsByQuery: [String: [MusicSearchHit]] = [:]
    var snapshot = MusicPlaybackSnapshot(status: .playing, positionSeconds: 1.4, positionAdvancing: true)
    var playError: MusicPlaybackError?

    private(set) var searchQueries: [String] = []
    private(set) var playedItems: [(kind: MusicSearchHit.Kind, id: String)] = []
    private(set) var transportActions: [String] = []
    private(set) var enqueuedItems: [(kind: MusicSearchHit.Kind, id: String, next: Bool)] = []

    func search(query: String, limit: Int) async throws -> [MusicSearchHit] {
        searchQueries.append(query)
        return hitsByQuery[query] ?? searchHits
    }

    func play(kind: MusicSearchHit.Kind, id: String) async throws -> MusicPlaybackSnapshot {
        if let playError { throw playError }
        playedItems.append((kind, id))
        return snapshot
    }

    func playTopMatch(query: String, preferredKind: MusicSearchHit.Kind?) async throws
        -> (hit: MusicSearchHit, snapshot: MusicPlaybackSnapshot) {
        searchQueries.append(query)
        if let playError { throw playError }
        guard let hit = MusicKitPlaybackService.topMatch(in: searchHits, preferredKind: preferredKind) else {
            throw MusicPlaybackError.notFound("nothing for \(query)")
        }
        playedItems.append((hit.kind, hit.id))
        return (hit, snapshot)
    }

    func pause() async throws -> MusicPlaybackSnapshot {
        transportActions.append("pause")
        return snapshot
    }

    func resume() async throws -> MusicPlaybackSnapshot {
        transportActions.append("resume")
        return snapshot
    }

    func stop() async throws -> MusicPlaybackSnapshot {
        transportActions.append("stop")
        return snapshot
    }

    func skipToNext() async throws -> MusicPlaybackSnapshot {
        transportActions.append("next")
        return snapshot
    }

    func skipToPrevious() async throws -> MusicPlaybackSnapshot {
        transportActions.append("previous")
        return snapshot
    }

    func enqueue(kind: MusicSearchHit.Kind, id: String, next: Bool) async throws -> MusicPlaybackSnapshot {
        if let playError { throw playError }
        enqueuedItems.append((kind, id, next))
        return snapshot
    }

    func seek(toSeconds: Double) async throws -> MusicPlaybackSnapshot {
        transportActions.append("seek(to:\(toSeconds))")
        return snapshot
    }

    func seek(bySeconds: Double) async throws -> MusicPlaybackSnapshot {
        transportActions.append("seek(by:\(bySeconds))")
        return snapshot
    }

    func setShuffle(_ enabled: Bool) async throws -> MusicPlaybackSnapshot {
        transportActions.append("shuffle(\(enabled ? "on" : "off"))")
        return snapshot
    }

    func setRepeat(_ setting: MusicRepeatSetting) async throws -> MusicPlaybackSnapshot {
        transportActions.append("repeat(\(setting.rawValue))")
        return snapshot
    }

    func status() async -> MusicPlaybackSnapshot {
        snapshot
    }

    var playlists: [MusicPlaylistSummary] = []
    var entries: [MusicPlaylistEntry] = []
    var createError: MusicPlaybackError?
    private(set) var createdPlaylists: [(name: String, description: String?)] = []
    private(set) var addedSongs: [(playlistID: String, songIDs: [String])] = []

    func libraryPlaylists(limit: Int) async throws -> [MusicPlaylistSummary] {
        playlists
    }

    func createPlaylist(name: String, description: String?) async throws -> MusicPlaylistSummary {
        if let createError { throw createError }
        createdPlaylists.append((name, description))
        return MusicPlaylistSummary(id: "p.new", name: name)
    }

    func addToPlaylist(playlistID: String, songIDs: [String]) async throws {
        addedSongs.append((playlistID, songIDs))
    }

    func playlistEntries(playlistID: String, limit: Int) async throws -> [MusicPlaylistEntry] {
        entries
    }
}
