// cut-stt — on-device speech-to-text with word timestamps.
//
// Wraps Apple's SpeechAnalyzer/SpeechTranscriber (macOS 26+, the engine
// behind Voice Memos transcripts): fully local, no permission needed for
// file input. Compiled on demand by server/transcribe.ts.
//
//   usage: cut-stt <audio-file> [locale]
//   stdout: {"locale":"en-US","words":[{"t0":0.12,"t1":0.48,"w":"Hello"}]}

import AVFoundation
import Foundation
import Speech

struct Word: Codable {
  let t0: Double
  let t1: Double
  let w: String
}

struct Output: Codable {
  let locale: String
  let words: [Word]
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

@main
struct Main {
  static func main() async {
    guard CommandLine.arguments.count >= 2 else { fail("usage: cut-stt <audio-file> [locale]") }
    let path = CommandLine.arguments[1]
    let localeId = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "en-US"
    let locale = Locale(identifier: localeId)

    do {
      let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: [.audioTimeRange]
      )

      // First run per locale downloads the on-device model; no-op afterwards.
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
      }

      let analyzer = SpeechAnalyzer(modules: [transcriber])
      let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))

      let collector = Task {
        var words: [Word] = []
        for try await result in transcriber.results {
          for run in result.text.runs {
            guard let range = run.audioTimeRange else { continue }
            let text = String(result.text[run.range].characters)
              .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            words.append(Word(t0: range.start.seconds, t1: range.end.seconds, w: text))
          }
        }
        return words
      }

      if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
      } else {
        await analyzer.cancelAndFinishNow()
      }

      let words = try await collector.value
      let out = Output(locale: locale.identifier(.bcp47), words: words)
      let data = try JSONEncoder().encode(out)
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
      fail("cut-stt: \(error)")
    }
  }
}
