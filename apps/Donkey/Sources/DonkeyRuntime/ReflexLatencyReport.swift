import DonkeyContracts
import Foundation

public enum ReflexReplayBenchmarkMode: String, Codable, Equatable, Sendable {
    case captureOnly
    case controllerOnly
    case endToEndDryRun
}

public struct ReflexLatencyPercentiles: Codable, Equatable, Sendable {
    public var p50: Double?
    public var p95: Double?
    public var p99: Double?

    public init(p50: Double? = nil, p95: Double? = nil, p99: Double? = nil) {
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
    }
}

public struct ReflexWorstTrace: Codable, Equatable, Sendable {
    public var traceID: String
    public var frameID: String
    public var softwareLoopMS: Double?

    public init(traceID: String, frameID: String, softwareLoopMS: Double?) {
        self.traceID = traceID
        self.frameID = frameID
        self.softwareLoopMS = softwareLoopMS
    }
}

public struct ReflexLatencyReport: Codable, Equatable, Sendable {
    public var mode: ReflexReplayBenchmarkMode
    public var traceCount: Int
    public var softwareLoopMS: ReflexLatencyPercentiles
    public var captureMS: ReflexLatencyPercentiles
    public var perceptionMS: ReflexLatencyPercentiles
    public var decisionMS: ReflexLatencyPercentiles
    public var inputMS: ReflexLatencyPercentiles
    public var captureFPS: Double?
    public var perceptionFPS: Double?
    public var controllerTickRate: Double?
    public var droppedFrameCount: Int
    public var staleActionCount: Int
    public var worstTraces: [ReflexWorstTrace]
    public var metadata: [String: String]

    public init(
        mode: ReflexReplayBenchmarkMode,
        traceCount: Int,
        softwareLoopMS: ReflexLatencyPercentiles,
        captureMS: ReflexLatencyPercentiles,
        perceptionMS: ReflexLatencyPercentiles,
        decisionMS: ReflexLatencyPercentiles,
        inputMS: ReflexLatencyPercentiles,
        captureFPS: Double? = nil,
        perceptionFPS: Double? = nil,
        controllerTickRate: Double? = nil,
        droppedFrameCount: Int = 0,
        staleActionCount: Int = 0,
        worstTraces: [ReflexWorstTrace] = [],
        metadata: [String: String] = [:]
    ) {
        self.mode = mode
        self.traceCount = traceCount
        self.softwareLoopMS = softwareLoopMS
        self.captureMS = captureMS
        self.perceptionMS = perceptionMS
        self.decisionMS = decisionMS
        self.inputMS = inputMS
        self.captureFPS = captureFPS
        self.perceptionFPS = perceptionFPS
        self.controllerTickRate = controllerTickRate
        self.droppedFrameCount = droppedFrameCount
        self.staleActionCount = staleActionCount
        self.worstTraces = worstTraces
        self.metadata = metadata
    }
}

public struct ReflexBenchmarkBaseline: Codable, Equatable, Sendable {
    public var targetID: String
    public var machineClass: String
    public var report: ReflexLatencyReport

    public init(
        targetID: String,
        machineClass: String,
        report: ReflexLatencyReport
    ) {
        self.targetID = targetID
        self.machineClass = machineClass
        self.report = report
    }
}

public enum ReflexLatencyReportBuilder {
    public static func build(
        from traces: [ReflexTraceRecord],
        mode: ReflexReplayBenchmarkMode = .endToEndDryRun,
        droppedFrameCount: Int = 0,
        metadata: [String: String] = [:]
    ) -> ReflexLatencyReport {
        ReflexLatencyReport(
            mode: mode,
            traceCount: traces.count,
            softwareLoopMS: percentiles(traces.compactMap(\.latencyBreakdown.softwareLoopMS)),
            captureMS: percentiles(traces.compactMap(\.latencyBreakdown.captureMS)),
            perceptionMS: percentiles(traces.compactMap(\.latencyBreakdown.perceptionMS)),
            decisionMS: percentiles(traces.compactMap(\.latencyBreakdown.decisionMS)),
            inputMS: percentiles(traces.compactMap(\.latencyBreakdown.inputMS)),
            captureFPS: rate(
                count: traces.count,
                first: traces.compactMap(\.timestamps.captureEnd).first,
                last: traces.compactMap(\.timestamps.captureEnd).last
            ),
            perceptionFPS: rate(
                count: traces.count,
                first: traces.compactMap(\.timestamps.perceptionEnd).first,
                last: traces.compactMap(\.timestamps.perceptionEnd).last
            ),
            controllerTickRate: rate(
                count: traces.count,
                first: traces.compactMap(\.timestamps.controllerEnd).first,
                last: traces.compactMap(\.timestamps.controllerEnd).last
            ),
            droppedFrameCount: droppedFrameCount,
            staleActionCount: staleActionCount(in: traces),
            worstTraces: worstTraces(in: traces),
            metadata: metadata
        )
    }

    private static func percentiles(_ values: [Double]) -> ReflexLatencyPercentiles {
        guard !values.isEmpty else { return ReflexLatencyPercentiles() }

        let sorted = values.sorted()
        return ReflexLatencyPercentiles(
            p50: percentile(sorted, fraction: 0.50),
            p95: percentile(sorted, fraction: 0.95),
            p99: percentile(sorted, fraction: 0.99)
        )
    }

    private static func percentile(
        _ sortedValues: [Double],
        fraction: Double
    ) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        let index = min(
            sortedValues.count - 1,
            Int(Double(sortedValues.count - 1) * fraction)
        )
        return sortedValues[index]
    }

    private static func rate(
        count: Int,
        first: RunTraceTimestamp?,
        last: RunTraceTimestamp?
    ) -> Double? {
        guard count > 1,
              let first,
              let last,
              let spanMS = first.milliseconds(until: last),
              spanMS > 0
        else {
            return nil
        }

        return Double(count - 1) / (spanMS / 1_000)
    }

    private static func staleActionCount(in traces: [ReflexTraceRecord]) -> Int {
        traces.filter { trace in
            trace.metadata["action.fallback"] == "true"
                && trace.metadata["fallbackReason"] == "staleSignal"
        }
        .count
    }

    private static func worstTraces(in traces: [ReflexTraceRecord]) -> [ReflexWorstTrace] {
        traces
            .sorted {
                ($0.latencyBreakdown.softwareLoopMS ?? -.infinity)
                    > ($1.latencyBreakdown.softwareLoopMS ?? -.infinity)
            }
            .prefix(5)
            .map {
                ReflexWorstTrace(
                    traceID: $0.traceID,
                    frameID: $0.frameID,
                    softwareLoopMS: $0.latencyBreakdown.softwareLoopMS
                )
            }
    }
}

public enum ReflexLatencyReportFormatter {
    public static func lines(for report: ReflexLatencyReport) -> [String] {
        [
            "reflex latency report",
            "mode=\(report.mode.rawValue)",
            "traceCount=\(report.traceCount)",
            "softwareLoopMS=\(format(report.softwareLoopMS))",
            "captureMS=\(format(report.captureMS))",
            "perceptionMS=\(format(report.perceptionMS))",
            "decisionMS=\(format(report.decisionMS))",
            "inputMS=\(format(report.inputMS))",
            "captureFPS=\(format(report.captureFPS))",
            "perceptionFPS=\(format(report.perceptionFPS))",
            "controllerTickRate=\(format(report.controllerTickRate))",
            "droppedFrameCount=\(report.droppedFrameCount)",
            "staleActionCount=\(report.staleActionCount)",
            "worstTraces=\(report.worstTraces.map { "\($0.traceID):\($0.frameID):\(format($0.softwareLoopMS))" }.joined(separator: ","))"
        ]
    }

    private static func format(_ percentiles: ReflexLatencyPercentiles) -> String {
        "p50=\(format(percentiles.p50)),p95=\(format(percentiles.p95)),p99=\(format(percentiles.p99))"
    }

    private static func format(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.2f", value)
    }
}

public struct ReflexReplayBenchmark: Sendable {
    public var mode: ReflexReplayBenchmarkMode
    public var frameCount: Int
    public var droppedFrameCount: Int

    public init(
        mode: ReflexReplayBenchmarkMode = .endToEndDryRun,
        frameCount: Int = 30,
        droppedFrameCount: Int = 0
    ) {
        self.mode = mode
        self.frameCount = frameCount
        self.droppedFrameCount = droppedFrameCount
    }

    public func run() async -> ReflexLatencyReport {
        let coordinator = RunCoordinator()
        let frames = (0..<frameCount).map { index in
            HotLoopFrame(
                id: "benchmark-frame-\(index + 1)",
                traceID: "benchmark-trace-\(index + 1)",
                targetID: "benchmark-target",
                capturedAt: timestamp(milliseconds: UInt64(index * 16)),
                sourceKind: .synthetic,
                windowBounds: HotLoopRect(x: 0, y: 0, width: 400, height: 300, space: .screen),
                crop: HotLoopCrop(
                    id: "benchmark-crop",
                    bounds: HotLoopRect(x: 0, y: 0, width: 400, height: 300, space: .window),
                    outputSize: HotLoopSize(width: 400, height: 300, space: .crop)
                ),
                pixelSize: HotLoopSize(width: 400, height: 300, space: .window),
                metadata: [
                    "tapTargetX": "0.4",
                    "tapTargetY": "0.5",
                    "tapTargetWidth": "0.1",
                    "tapTargetHeight": "0.1",
                    "signalConfidence": "0.85"
                ]
            )
        }
        let loop = DryRunReflexLoop(
            coordinator: coordinator,
            frameSource: RecordedFrameSource(frames: frames)
        )
        let result = await loop.run(
            session: RunSession(
                id: "benchmark-session",
                userGoal: "benchmark dry-run loop",
                targetID: "benchmark-target"
            )
        )

        return await ReflexLatencyReportBuilder.build(
            from: coordinator.reflexTraces(),
            mode: mode,
            droppedFrameCount: result.droppedFrameCount + droppedFrameCount,
            metadata: [
                "frameCount": String(frameCount)
            ]
        )
    }

    private func timestamp(milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: milliseconds * 1_000_000
        )
    }
}
