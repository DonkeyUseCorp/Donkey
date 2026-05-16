import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct OffTheShelfVisionPerceptionTests {
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
}
