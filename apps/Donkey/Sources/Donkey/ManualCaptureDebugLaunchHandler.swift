import DonkeyContracts
import DonkeyRuntime
import Foundation

@MainActor
struct ManualCaptureDebugLaunchHandler {
    static func shouldHandle(arguments: [String]) -> Bool {
        ManualCaptureDebugCommandParser.containsDebugCommand(arguments: arguments)
    }

    func run(arguments: [String]) async -> Int32 {
        do {
            guard let command = try ManualCaptureDebugCommandParser.parse(arguments: arguments) else {
                return 0
            }

            switch command {
            case .listWindowCandidates:
                printLines(
                    ManualCaptureDebugCommandFormatter.lines(
                        for: MacWindowResolver().enumerateCandidateList()
                    )
                )
                return 0
            case .manualCapture(let options):
                let artifactStore = try LocalRunArtifactStore()
                let service = ManualTargetContextCaptureService(artifactStore: artifactStore)
                let runID = options.runID ?? "manual-\(UUID().uuidString)"
                let traceID = options.traceID ?? "trace-\(UUID().uuidString)"
                let session = RunSession(
                    id: runID,
                    userGoal: "manual capture debug",
                    targetID: targetID(for: options.selection)
                )
                let result = try await service.capture(
                    session: session,
                    selection: options.selection,
                    traceID: traceID
                )
                let runDirectory = try await artifactStore.runDirectory(for: result.traceSummary.runID)

                printLines(
                    ManualCaptureDebugCommandFormatter.lines(
                        for: result,
                        runDirectory: runDirectory
                    )
                )
                return 0
            case .dryRunLatencyReport(let options):
                let report = await ReflexReplayBenchmark(
                    mode: options.mode,
                    frameCount: options.frameCount
                )
                .run()
                printLines(ReflexLatencyReportFormatter.lines(for: report))
                return 0
            }
        } catch {
            printError(ManualCaptureDebugCommandFormatter.errorLine(for: error))
            return 1
        }
    }

    private func targetID(for selection: MacWindowSelectionRequest) -> String {
        if let windowID = selection.windowID {
            return "window-\(windowID)"
        }

        return "focused-or-frontmost-window"
    }

    private func printLines(_ lines: [String]) {
        for line in lines {
            print(line)
        }
    }

    private func printError(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }
}
