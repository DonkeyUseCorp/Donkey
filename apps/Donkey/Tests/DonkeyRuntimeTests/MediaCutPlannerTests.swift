import DonkeyRuntime
import Foundation
import Testing

/// Deterministic math for the cut engine — the part that must be exactly right, tested directly with no
/// ffmpeg and no model. Covers the inversion (removals → keeps), every floor/merge/clamp rule, parsing
/// silencedetect output and a transcript into removal spans, and the exact ffmpeg filtergraph.
@Suite
struct MediaCutPlannerTests {
    // Loose float compare for the span arithmetic.
    private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

    private func spans(_ pairs: [(Double, Double)]) -> [MediaTimeSpan] {
        pairs.map { MediaTimeSpan(start: $0.0, end: $0.1) }
    }

    // No floors/merge, so this is pure inversion.
    private let exact = MediaCutPlanner.Parameters(
        fillerPadSec: 0, keepPauseSec: 0, mergeGapSec: 0, minRemovalSec: 0, minKeepSec: 0
    )

    private func expectKeeps(_ keeps: [MediaTimeSpan], _ expected: [(Double, Double)], _ label: String) {
        #expect(keeps.count == expected.count, "[\(label)] count: got \(keeps.map { ($0.start, $0.end) })")
        for (index, pair) in expected.enumerated() where index < keeps.count {
            #expect(near(keeps[index].start, pair.0) && near(keeps[index].end, pair.1),
                    "[\(label)] span \(index): got (\(keeps[index].start), \(keeps[index].end)), want \(pair)")
        }
    }

    // MARK: keepSegments — inversion

    @Test func singleMiddleRemoval() {
        let keeps = MediaCutPlanner.keepSegments(removing: spans([(3, 4)]), duration: 10, parameters: exact)
        expectKeeps(keeps, [(0, 3), (4, 10)], "middle")
    }

    @Test func noRemovalsKeepsWholeFile() {
        let keeps = MediaCutPlanner.keepSegments(removing: [], duration: 10, parameters: exact)
        expectKeeps(keeps, [(0, 10)], "none")
    }

    @Test func removalAtStart() {
        let keeps = MediaCutPlanner.keepSegments(removing: spans([(0, 2)]), duration: 10, parameters: exact)
        expectKeeps(keeps, [(2, 10)], "start")
    }

    @Test func removalAtEnd() {
        let keeps = MediaCutPlanner.keepSegments(removing: spans([(8, 10)]), duration: 10, parameters: exact)
        expectKeeps(keeps, [(0, 8)], "end")
    }

    @Test func removalCoveringEverythingLeavesNothing() {
        let keeps = MediaCutPlanner.keepSegments(removing: spans([(0, 10)]), duration: 10, parameters: exact)
        #expect(keeps.isEmpty)
    }

    @Test func overlappingRemovalsMerge() {
        let keeps = MediaCutPlanner.keepSegments(removing: spans([(2, 5), (3, 6)]), duration: 10, parameters: exact)
        expectKeeps(keeps, [(0, 2), (6, 10)], "overlap")
    }

    @Test func unsortedRemovalsHandled() {
        let keeps = MediaCutPlanner.keepSegments(removing: spans([(8, 9), (2, 3)]), duration: 10, parameters: exact)
        expectKeeps(keeps, [(0, 2), (3, 8), (9, 10)], "unsorted")
    }

    @Test func removalsClampedToDuration() {
        let keeps = MediaCutPlanner.keepSegments(removing: spans([(8, 999)]), duration: 10, parameters: exact)
        expectKeeps(keeps, [(0, 8)], "clamp")
    }

    // MARK: keepSegments — floors & merge

    @Test func mergeWithinGap() {
        let params = MediaCutPlanner.Parameters(keepPauseSec: 0, mergeGapSec: 0.04, minRemovalSec: 0, minKeepSec: 0)
        // Gap between removals is 0.02 ≤ 0.04 → merged into one, so no micro-keep between them.
        let keeps = MediaCutPlanner.keepSegments(removing: spans([(3, 4), (4.02, 5)]), duration: 10, parameters: params)
        expectKeeps(keeps, [(0, 3), (5, 10)], "merge")
    }

    @Test func noMergeBeyondGap() {
        let params = MediaCutPlanner.Parameters(keepPauseSec: 0, mergeGapSec: 0.04, minRemovalSec: 0, minKeepSec: 0)
        // Gap 0.1 > 0.04 → kept apart, so the 0.1s sliver between survives.
        let keeps = MediaCutPlanner.keepSegments(removing: spans([(3, 4), (4.1, 5)]), duration: 10, parameters: params)
        expectKeeps(keeps, [(0, 3), (4, 4.1), (5, 10)], "nomerge")
    }

    @Test func removalShorterThanFloorIgnored() {
        let params = MediaCutPlanner.Parameters(keepPauseSec: 0, mergeGapSec: 0, minRemovalSec: 0.05, minKeepSec: 0)
        let keeps = MediaCutPlanner.keepSegments(removing: spans([(3, 3.03)]), duration: 10, parameters: params)
        expectKeeps(keeps, [(0, 10)], "tinyRemoval")
    }

    @Test func keepSliverShorterThanFloorDropped() {
        let params = MediaCutPlanner.Parameters(keepPauseSec: 0, mergeGapSec: 0, minRemovalSec: 0, minKeepSec: 0.02)
        // [0,3] and [3.01,10] are both REMOVED, leaving only the 0.01s gap [3,3.01] which is below
        // minKeep → dropped. Nothing survives.
        let keeps = MediaCutPlanner.keepSegments(removing: spans([(0, 3), (3.01, 10)]), duration: 10, parameters: params)
        #expect(keeps.isEmpty, "tinyKeep: got \(keeps.map { ($0.start, $0.end) })")
    }

    @Test func zeroDurationYieldsNothing() {
        #expect(MediaCutPlanner.keepSegments(removing: spans([(0, 1)]), duration: 0, parameters: exact).isEmpty)
    }

    // MARK: silenceSpans

    @Test func silenceSpansParsedAndShrunk() {
        let text = """
        [silencedetect @ 0x6000] silence_start: 18.512
        [silencedetect @ 0x6000] silence_end: 19.430 | silence_duration: 0.918
        [silencedetect @ 0x6000] silence_start: 95.204
        [silencedetect @ 0x6000] silence_end: 96.880 | silence_duration: 1.676
        """
        let result = MediaCutPlanner.silenceSpans(fromSilenceDetect: text, keepPauseSec: 0.15)
        #expect(result.count == 2)
        #expect(near(result[0].start, 18.662) && near(result[0].end, 19.280))
        #expect(near(result[1].start, 95.354) && near(result[1].end, 96.730))
    }

    @Test func silenceRunningToEndOfFileHasOpenEnd() {
        let result = MediaCutPlanner.silenceSpans(fromSilenceDetect: "silence_start: 5.0", keepPauseSec: 0)
        #expect(result.count == 1)
        #expect(near(result[0].start, 5.0))
        #expect(result[0].end == Double.greatestFiniteMagnitude)
    }

    @Test func silenceShorterThanTwicePauseDropped() {
        // A 0.1s silence with a 0.15s pause each side would invert — it is dropped, not emitted backwards.
        let text = "silence_start: 4.0\nsilence_end: 4.1"
        #expect(MediaCutPlanner.silenceSpans(fromSilenceDetect: text, keepPauseSec: 0.15).isEmpty)
    }

    // MARK: fillerSpans

    @Test func fillerSpansMatchLexiconCaseAndPunctuationInsensitive() {
        let json = """
        { "words": [
          { "text": "so", "start": 2.8, "end": 3.1 },
          { "text": "Um,", "start": 3.1, "end": 3.42 },
          { "text": "uh", "start": 7.8, "end": 8.05 },
          { "text": "idea", "start": 4.0, "end": 4.5 }
        ] }
        """
        let result = MediaCutPlanner.fillerSpans(
            fromTranscriptJSON: Data(json.utf8),
            lexicon: MediaCutPlanner.defaultFillerLexicon,
            padSec: 0.03
        )
        #expect(result.count == 2)
        #expect(near(result[0].start, 3.07) && near(result[0].end, 3.45))
        #expect(near(result[1].start, 7.77) && near(result[1].end, 8.08))
    }

    @Test func fillerSpansEmptyOnMalformedJSON() {
        #expect(MediaCutPlanner.fillerSpans(fromTranscriptJSON: Data("not json".utf8), lexicon: ["um"], padSec: 0).isEmpty)
    }

    // MARK: explicitSpans

    @Test func explicitSpansParsed() {
        let result = MediaCutPlanner.explicitSpans(fromList: "1.2-3.4, 5-6.0")
        #expect(result.count == 2)
        #expect(near(result[0].start, 1.2) && near(result[0].end, 3.4))
        #expect(near(result[1].start, 5.0) && near(result[1].end, 6.0))
    }

    @Test func explicitSpansToleratesUnitsAndSkipsGarbage() {
        let result = MediaCutPlanner.explicitSpans(fromList: "3.0s-4.0s, nonsense, 8-7")
        // "8-7" is end<=start and skipped; "nonsense" skipped; only the units span survives.
        #expect(result.count == 1)
        #expect(near(result[0].start, 3.0) && near(result[0].end, 4.0))
    }

    // MARK: filterGraph

    @Test func filterGraphBothStreams() {
        let graph = MediaCutPlanner.filterGraph(keeping: spans([(0, 3), (4, 10)]), hasVideo: true, hasAudio: true)
        let expected = """
        [0:v]trim=start=0.000:end=3.000,setpts=PTS-STARTPTS[v0];
        [0:a]atrim=start=0.000:end=3.000,asetpts=PTS-STARTPTS[a0];
        [0:v]trim=start=4.000:end=10.000,setpts=PTS-STARTPTS[v1];
        [0:a]atrim=start=4.000:end=10.000,asetpts=PTS-STARTPTS[a1];
        [v0][a0][v1][a1]concat=n=2:v=1:a=1[v][a]
        """
        #expect(graph == expected)
    }

    @Test func filterGraphVideoOnly() {
        let graph = MediaCutPlanner.filterGraph(keeping: spans([(0, 3)]), hasVideo: true, hasAudio: false)
        let expected = """
        [0:v]trim=start=0.000:end=3.000,setpts=PTS-STARTPTS[v0];
        [v0]concat=n=1:v=1:a=0[v]
        """
        #expect(graph == expected)
    }

    @Test func filterGraphAudioOnly() {
        let graph = MediaCutPlanner.filterGraph(keeping: spans([(0, 3)]), hasVideo: false, hasAudio: true)
        let expected = """
        [0:a]atrim=start=0.000:end=3.000,asetpts=PTS-STARTPTS[a0];
        [a0]concat=n=1:v=0:a=1[a]
        """
        #expect(graph == expected)
    }

    @Test func filterGraphEmptyWhenNothingKept() {
        #expect(MediaCutPlanner.filterGraph(keeping: [], hasVideo: true, hasAudio: true).isEmpty)
    }
}
