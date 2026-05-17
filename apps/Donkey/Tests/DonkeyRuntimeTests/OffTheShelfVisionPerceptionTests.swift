import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct OffTheShelfVisionPerceptionTests {
    @Test
    func modelCatalogIncludesLatestYOLOForScreenshotSegmentation() throws {
        let candidate = try #require(OffTheShelfVisionModelCatalog.defaultCandidate(
            signalKind: .segmentation,
            inputSource: .screenshot
        ))

        #expect(candidate.family == "YOLO26")
        #expect(candidate.modelName == "yolo26n-seg.pt")
        #expect(candidate.signalKind == .segmentation)
        #expect(candidate.preferredInputSource == .crop)
        #expect(candidate.componentID == "screenshot-segmentation-yolo26")
        #expect(candidate.metadata["latestYOLOFamilyVerified"] == "YOLO26")
        #expect(candidate.metadata["requiresLocalBenchmark"] == "true")
        #expect(candidate.docsURL.absoluteString == "https://docs.ultralytics.com/models/yolo26/")
    }

    @Test
    func metadataCodecRoundTripsLocalVisionEvidence() throws {
        let metadata = RecordedOffTheShelfVisionMetadataCodec.encode(signals: [
            recordedSignal(kind: .detector, id: "detector-signal", modelID: "yolo-nano-local"),
            recordedSignal(kind: .ocr, id: "ocr-signal", modelID: "vision-text-local")
        ])

        let signals = RecordedOffTheShelfVisionMetadataCodec.decode(from: metadata)

        #expect(metadata["vision.offTheShelf.rawPixelsExposed"] == "false")
        #expect(signals.map(\.kind) == [.detector, .ocr])
        #expect(signals.first?.componentID == "component-detector-signal")
        #expect(signals.first?.observations.first?.bounds == HotLoopRect(
            x: 0.42,
            y: 0.58,
            width: 0.12,
            height: 0.08,
            space: .normalizedTarget
        ))
    }

    @Test
    func adapterBuildsSignalsFromRecordedOffTheShelfVisionOutput() async throws {
        let frame = fixtureFrame(signals: [
            recordedSignal(
                kind: .template,
                id: "template-signal",
                modelID: "button-template-v1",
                preprocessMS: 2,
                modelInferenceMS: 3,
                adapterOverheadMS: 1
            )
        ])

        let signals = await OffTheShelfVisionPerceptionAdapter().perceive(frame: frame)
        let signal = try #require(signals.first)
        let observation = try #require(signal.observations.first)

        #expect(signal.kind == "template")
        #expect(signal.metadata["vision.localEvidence"] == "true")
        #expect(signal.metadata["rawPixelsExposed"] == "false")
        #expect(signal.metadata["latency.preprocessMS"] == "2.0")
        #expect(signal.metadata["latency.modelInferenceMS"] == "3.0")
        #expect(signal.sourceAgeMS(at: timestamp(16)) == 6)
        #expect(observation.metadata["vision.modelID"] == "button-template-v1")
        #expect(observation.bounds?.space == .normalizedTarget)
    }

    @Test
    func dryRunLoopActsFromLocalVisionEvidenceAndRecordsLatency() async throws {
        let coordinator = RunCoordinator()
        let frame = fixtureFrame(signals: [
            recordedSignal(
                kind: .detector,
                id: "detector-signal",
                modelID: "yolo-nano-local",
                preprocessMS: 3,
                modelInferenceMS: 7,
                adapterOverheadMS: 1
            )
        ])
        let loop = DryRunReflexLoop(
            coordinator: coordinator,
            frameSource: RecordedFrameSource(frames: [frame]),
            perceptionAdapter: OffTheShelfVisionPerceptionAdapter(),
            worldStateProjector: OffTheShelfVisionWorldStateProjector(),
            controllerPolicy: DeterministicControllerPolicy()
        )

        let result = await loop.run(
            session: RunSession(
                id: "session-local-vision",
                userGoal: "tap detected play button",
                targetID: "target-visual-game"
            )
        )

        let trace = try #require(await coordinator.latestReflexTrace())
        let report = await ReflexLatencyReportBuilder.build(from: coordinator.reflexTraces())

        #expect(result.processedFrameCount == 1)
        #expect(result.latestWorldState?.metadata["vision.localEvidence"] == "true")
        #expect(result.latestAction?.kind == .tapTarget)
        #expect(result.latestAction?.metadata["vision.modelID"] == "yolo-nano-local")
        #expect(trace.latencyBreakdown.preprocessMS == 3)
        #expect(trace.latencyBreakdown.modelInferenceMS == 7)
        #expect(trace.latencyBreakdown.perceptionMS == 11)
        #expect(trace.metadata["vision.localEvidence"] == "true")
        #expect(trace.metadata["vision.signalKind"] == "detector")
        #expect(report.modelInferenceMS.p95 == 7)
        #expect(report.decisionMS.p95 == 1)
    }

    @Test
    func yoloScreenshotSegmentationRunnerProducesRecordedLocalEvidence() async throws {
        let runner = YOLOScreenshotSegmentationRunner(
            backend: FakeScreenshotSegmentationBackend(),
            now: fixedClock([100, 118])
        )
        let result = try await runner.run(
            ScreenshotSegmentationRequest(
                traceID: "trace-yolo",
                frameID: "frame-yolo",
                targetID: "target-yolo",
                cropID: "crop-search",
                cropBounds: HotLoopRect(x: 0, y: 0, width: 320, height: 180, space: .window),
                pixelSize: HotLoopSize(width: 320, height: 180, space: .crop)
            )
        )
        let decoded = RecordedOffTheShelfVisionMetadataCodec.decode(from: result.metadata)
        let signal = try #require(decoded.first)

        #expect(result.model.id == "ultralytics-yolo26n-seg-screenshot")
        #expect(signal.kind == .segmentation)
        #expect(signal.modelID == "ultralytics-yolo26n-seg-screenshot")
        #expect(signal.cropID == "crop-search")
        #expect(signal.preprocessMS == 3)
        #expect(signal.modelInferenceMS == 9)
        #expect(signal.adapterOverheadMS == 6)
        #expect(signal.observations.first?.label == "search-field")
        #expect(signal.metadata["requiresLocalBenchmark"] == "true")
    }

    private func recordedSignal(
        kind: OffTheShelfVisionSignalKind,
        id: String,
        modelID: String,
        preprocessMS: Double = 1,
        modelInferenceMS: Double = 4,
        adapterOverheadMS: Double = 1
    ) -> RecordedOffTheShelfVisionSignal {
        RecordedOffTheShelfVisionSignal(
            id: id,
            kind: kind,
            componentID: "component-\(id)",
            modelID: modelID,
            cropID: "gameplay-crop",
            confidence: 0.88,
            observations: [
                RecordedOffTheShelfVisionObservation(
                    id: "observation-\(id)",
                    label: "play-button",
                    bounds: HotLoopRect(
                        x: 0.42,
                        y: 0.58,
                        width: 0.12,
                        height: 0.08,
                        space: .normalizedTarget
                    ),
                    confidence: 0.82,
                    metadata: [
                        "templateID": "play-button-template"
                    ]
                )
            ],
            preprocessMS: preprocessMS,
            modelInferenceMS: modelInferenceMS,
            adapterOverheadMS: adapterOverheadMS
        )
    }

    private func fixtureFrame(signals: [RecordedOffTheShelfVisionSignal]) -> HotLoopFrame {
        HotLoopFrame(
            id: "frame-local-vision",
            traceID: "trace-local-vision",
            targetID: "target-visual-game",
            capturedAt: timestamp(10),
            sourceKind: .recorded,
            windowBounds: HotLoopRect(x: 0, y: 0, width: 390, height: 844, space: .screen),
            crop: HotLoopCrop(
                id: "gameplay-crop",
                bounds: HotLoopRect(x: 0, y: 120, width: 390, height: 600, space: .window),
                outputSize: HotLoopSize(width: 390, height: 600, space: .crop)
            ),
            pixelSize: HotLoopSize(width: 390, height: 844, space: .window),
            metadata: RecordedOffTheShelfVisionMetadataCodec.encode(signals: signals)
        )
    }

    private func timestamp(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: milliseconds * 1_000_000
        )
    }

    private func fixedClock(_ milliseconds: [UInt64]) -> @Sendable () -> RunTraceTimestamp {
        let clock = FixedVisionClock(milliseconds: milliseconds)
        return {
            clock.next()
        }
    }
}

private final class FixedVisionClock: @unchecked Sendable {
    private var milliseconds: [UInt64]
    private var index = 0

    init(milliseconds: [UInt64]) {
        self.milliseconds = milliseconds
    }

    func next() -> RunTraceTimestamp {
        let value = milliseconds[min(index, milliseconds.count - 1)]
        index += 1
        return RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(value) / 1_000),
            monotonicUptimeNanoseconds: value * 1_000_000
        )
    }
}

private struct FakeScreenshotSegmentationBackend: ScreenshotSegmentationBackend {
    func segment(
        request: ScreenshotSegmentationRequest,
        model: OffTheShelfVisionModelCandidate
    ) async throws -> ScreenshotSegmentationBackendResult {
        ScreenshotSegmentationBackendResult(
            masks: [
                ScreenshotSegmentationMask(
                    id: "mask-search",
                    label: "search-field",
                    bounds: HotLoopRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1, space: .normalizedTarget),
                    confidence: 0.87,
                    pointCount: 18
                )
            ],
            preprocessMS: 3,
            modelInferenceMS: 9,
            metadata: ["backend": "fake-yolo"]
        )
    }
}
