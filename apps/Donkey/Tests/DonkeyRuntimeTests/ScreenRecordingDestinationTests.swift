@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct ScreenRecordingDestinationTests {
    private static let referenceDate = Date(timeIntervalSince1970: 1_753_100_645) // 2025-07-21 in UTC

    @Test
    func fileNameFollowsQuickTimeShape() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 7, day: 21, hour: 15, minute: 24, second: 5))!

        let name = ScreenRecordingDestination.fileName(for: date)

        #expect(name == "Screen Recording 2026-07-21 at 15.24.05")
    }

    @Test
    func firstFileUsesTheBareName() {
        let directory = URL(fileURLWithPath: "/tmp/desktop")
        let url = ScreenRecordingDestination.uniqueURL(
            in: directory,
            baseName: "Screen Recording 2026-07-21 at 15.24.05",
            ext: "mov",
            fileExists: { _ in false }
        )

        #expect(url.lastPathComponent == "Screen Recording 2026-07-21 at 15.24.05.mov")
    }

    @Test
    func collidingNamesGainAnIncrementingSuffix() {
        let directory = URL(fileURLWithPath: "/tmp/desktop")
        let taken: Set<String> = [
            "Screen Recording 2026-07-21 at 15.24.05.mov",
            "Screen Recording 2026-07-21 at 15.24.05 (2).mov"
        ]

        let url = ScreenRecordingDestination.uniqueURL(
            in: directory,
            baseName: "Screen Recording 2026-07-21 at 15.24.05",
            ext: "mov",
            fileExists: { taken.contains($0.lastPathComponent) }
        )

        #expect(url.lastPathComponent == "Screen Recording 2026-07-21 at 15.24.05 (3).mov")
    }
}
