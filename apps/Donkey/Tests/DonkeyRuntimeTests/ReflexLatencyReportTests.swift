import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct ReflexLatencyReportTests {
    @Test
    func reportBuilderComputesPercentilesRatesDroppedFramesAndWorstTraces() {
        let traces = [
            trace(index: 1, softwareLoopMS: 10, fallbackReason: nil),
            trace(index: 2, softwareLoopMS: 20, fallbackReason: "staleSignal"),
            trace(index: 3, softwareLoopMS: 30, fallbackReason: nil),
            trace(index: 4, softwareLoopMS: 40, fallbackReason: nil)
        ]

        let report = ReflexLatencyReportBuilder.build(
            from: traces,
            mode: .endToEndDryRun,
            droppedFrameCount: 2,
            metadata: ["targetID": "target-1"]
        )

        #expect(report.traceCount == 4)
        #expect(report.softwareLoopMS.p50 == 20)
        #expect(report.softwareLoopMS.p95 == 30)
        #expect(report.softwareLoopMS.p99 == 30)
        #expect(report.captureMS.p50 == 1)
        #expect(report.perceptionMS.p50 == 2)
        #expect(report.decisionMS.p50 == 1)
        #expect(report.inputMS.p50 == 1)
        #expect(isClose(report.captureFPS, to: 100))
        #expect(isClose(report.perceptionFPS, to: 100))
        #expect(isClose(report.controllerTickRate, to: 100))
        #expect(report.droppedFrameCount == 2)
        #expect(report.staleActionCount == 1)
        #expect(report.worstTraces.first?.traceID == "trace-4")
        #expect(report.metadata["targetID"] == "target-1")
    }

    @Test
    func reportFormatterPrintsCliFriendlyLines() {
        let report = ReflexLatencyReportBuilder.build(
            from: [trace(index: 1, softwareLoopMS: 10, fallbackReason: nil)],
            mode: .captureOnly,
            droppedFrameCount: 1
        )

        let lines = ReflexLatencyReportFormatter.lines(for: report)

        #expect(lines.contains("reflex latency report"))
        #expect(lines.contains("mode=captureOnly"))
        #expect(lines.contains("traceCount=1"))
        #expect(lines.contains("droppedFrameCount=1"))
        #expect(lines.contains("softwareLoopMS=p50=10.00,p95=10.00,p99=10.00"))
    }

    @Test
    func replayBenchmarkProducesDryRunReportFromSyntheticTraces() async {
        let report = await ReflexReplayBenchmark(
            mode: .controllerOnly,
            frameCount: 3
        )
        .run()

        #expect(report.mode == .controllerOnly)
        #expect(report.traceCount == 3)
        #expect(report.softwareLoopMS.p95 != nil)
        #expect(report.metadata["frameCount"] == "3")
    }

    @Test
    func debugParserAcceptsDryRunLatencyReportCommand() throws {
        let command = try ManualCaptureDebugCommandParser.parse(
            arguments: [
                "Donkey",
                "--",
                "--dry-run-latency-report",
                "--frame-count",
                "12",
                "--benchmark-mode",
                "controllerOnly"
            ]
        )

        #expect(command == .dryRunLatencyReport(
            DryRunLatencyReportDebugOptions(
                frameCount: 12,
                mode: .controllerOnly
            )
        ))
    }

    private func trace(
        index: Int,
        softwareLoopMS: UInt64,
        fallbackReason: String?
    ) -> ReflexTraceRecord {
        let baseMS = UInt64(index * 10)
        var metadata: [String: String] = [:]
        if let fallbackReason {
            metadata["action.fallback"] = "true"
            metadata["fallbackReason"] = fallbackReason
        }

        return ReflexTraceRecord(
            traceID: "trace-\(index)",
            frameID: "frame-\(index)",
            stateID: "state-\(index)",
            actionID: "action-\(index)",
            timestamps: ReflexTraceTimeline(
                captureStart: timestamp(baseMS),
                captureEnd: timestamp(baseMS + 1),
                perceptionStart: timestamp(baseMS + 1),
                perceptionEnd: timestamp(baseMS + 3),
                statePublished: timestamp(baseMS + 3),
                controllerStart: timestamp(baseMS + 3),
                controllerEnd: timestamp(baseMS + 4),
                actionEnqueued: timestamp(baseMS + softwareLoopMS),
                inputExecuted: timestamp(baseMS + softwareLoopMS + 1)
            ),
            controllerPolicy: "policy",
            confidence: 0.9,
            metadata: metadata
        )
    }

    private func timestamp(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: milliseconds * 1_000_000
        )
    }

    private func isClose(_ value: Double?, to expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 0.0001
    }
}
