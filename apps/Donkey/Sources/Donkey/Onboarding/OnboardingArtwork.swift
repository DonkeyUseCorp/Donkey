// What fills an onboarding slide's artwork region, and the data the notch mocks
// read off. The live mocks themselves live in their own files
// (`OnboardingNotchMock`, `OnboardingSignInMock`, `OnboardingInputMock`), built
// on the shared `OnboardingMockKit`.

import SwiftUI

// MARK: - Mock data

/// One mocked conversation shown in the notch. Mirrors the fields the real notch
/// reads off `UserQueryConversation`: the prompt (echoed in the collapsed chin),
/// a live status line (the expanded subtext), an accent, and how long it has
/// "already" been running when the slide appears so the timer starts mid-task.
struct OnboardingMockConversation: Identifiable, Sendable {
    let id: String
    /// Index into the shared accent palette; colours the pointer for this task.
    var accentIndex: Int
    /// The user's prompt — what the collapsed notch reads back while running.
    var prompt: String
    /// The live narration line shown as the expanded row's subtext.
    var status: String
    /// Seconds already elapsed when the slide is shown, so the clock starts part-way.
    var elapsedOffset: TimeInterval
    /// Running tasks get a lit pointer and a ticking clock; finished ones a silhouette.
    var isRunning: Bool = true
}

/// Which live mock fills a slide's artwork region.
enum OnboardingArtwork {
    /// Static image loaded by `imageName` (the default; unchanged behaviour).
    case image
    /// Looping notch: collapse → pointer in → expand → dwell → collapse.
    case notchMock([OnboardingMockConversation])
    /// Static, wider expanded conversation panel; no collapsed pill or pointer.
    case notchPanel([OnboardingMockConversation])
    /// Pointer flies in, the notch expands and stays, then it clicks the composer
    /// and leaves the caret blinking.
    case notchComposer([OnboardingMockConversation])
    /// Pointer expands the notch, clicks the composer, types a command, clicks
    /// send, then vanishes while the task runs.
    case notchCompose([OnboardingMockConversation])
    /// The Donkey command field typing out each command in turn, with a colored
    /// pointer that flies in to click send.
    case inputMock([String])
    /// Sign-in: the screen edge with a collapsed notch at top; the field types a
    /// prompt, the pointer sends it, and it runs in the collapsed notch.
    case signInMock([String])
    /// "Ask anything": a ⌘+⌘ summon, then the field appears and types each prompt.
    case inputSummon([String])
}
