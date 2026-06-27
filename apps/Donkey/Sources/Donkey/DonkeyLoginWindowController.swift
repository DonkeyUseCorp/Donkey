import AppKit
import DonkeyRuntime
import SwiftUI

@MainActor
final class DonkeyLoginWindowController: NSWindowController {
    private let authCoordinator: DonkeyAuthCoordinator

    init(authCoordinator: DonkeyAuthCoordinator) {
        self.authCoordinator = authCoordinator

        let contentView = DonkeyLoginView(authCoordinator: authCoordinator)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Donkey"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.13, green: 0.13, blue: 0.12, alpha: 1)
        window.contentView = NSHostingView(rootView: contentView)
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func showLogin() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct DonkeyLoginView: View {
    @ObservedObject var authCoordinator: DonkeyAuthCoordinator
    init(authCoordinator: DonkeyAuthCoordinator) {
        self.authCoordinator = authCoordinator
    }

    var body: some View {
        ZStack {
            Color(red: 0.13, green: 0.13, blue: 0.12)
                .ignoresSafeArea()

            DonkeyGoogleSignInScreen(
                authCoordinator: authCoordinator,
                buttonIsDisabled: buttonIsDisabled,
                statusColor: statusColor,
                statusText: { statusText }
            )
        }
    }

    private var buttonIsDisabled: Bool {
        switch authCoordinator.phase {
        case .openingBrowser, .waitingForCallback, .exchangingSession:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch authCoordinator.phase {
        case .waitingForCallback:
            Text("Finish sign-in in your browser to continue.")
        case .exchangingSession:
            Text("Creating a secure Mac session...")
        case .failed(let message):
            Text(message)
        default:
            Text("")
        }
    }

    private var statusColor: Color {
        if case .failed = authCoordinator.phase {
            return Color(red: 1.0, green: 0.47, blue: 0.36)
        }

        return .white.opacity(0.54)
    }
}

private struct DonkeyGoogleSignInScreen<StatusText: View>: View {
    @ObservedObject var authCoordinator: DonkeyAuthCoordinator
    var buttonIsDisabled: Bool
    var statusColor: Color
    var statusText: () -> StatusText

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 64)

            Text("Sign In")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)

            Spacer().frame(height: 72)

            VStack(spacing: 18) {
                Button {
                    authCoordinator.beginGoogleSignIn()
                } label: {
                    GoogleContinueAsset()
                        .opacity(buttonIsDisabled ? 0.58 : 1)
                }
                .buttonStyle(.plain)
                .disabled(buttonIsDisabled)
                .accessibilityLabel("Continue with Google")

                statusText()
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(statusColor)
                    .frame(height: 20)
            }
            .frame(width: 360, height: 120)

            Spacer(minLength: 64)
        }
        .padding(.horizontal, 52)
    }
}

/// The sign-in slide's call-to-action inside the onboarding card: the same Google button the login window
/// uses, plus a compact status line that tracks the in-flight sign-in. Tapping it starts the real Google
/// flow; the app delegate closes the onboarding card once `authenticationCompleted` fires.
struct OnboardingGoogleSignInFooter: View {
    @ObservedObject var authCoordinator: DonkeyAuthCoordinator

    var body: some View {
        VStack(spacing: 8) {
            Button {
                authCoordinator.beginGoogleSignIn()
            } label: {
                GoogleContinueAsset()
                    .opacity(buttonIsDisabled ? 0.58 : 1)
            }
            .buttonStyle(.plain)
            .disabled(buttonIsDisabled)
            .accessibilityLabel("Continue with Google")

            statusText
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(height: 14)
        }
    }

    private var buttonIsDisabled: Bool {
        switch authCoordinator.phase {
        case .openingBrowser, .waitingForCallback, .exchangingSession:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch authCoordinator.phase {
        case .waitingForCallback:
            Text("Finish sign-in in your browser to continue.")
        case .exchangingSession:
            Text("Creating a secure Mac session...")
        case .failed(let message):
            Text(message)
        default:
            Text(" ")
        }
    }

    private var statusColor: Color {
        if case .failed = authCoordinator.phase {
            return Color(red: 1.0, green: 0.47, blue: 0.36)
        }

        return .white.opacity(0.54)
    }
}

struct GoogleContinueAsset: View {
    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                GoogleContinueFallback()
            }
        }
        .frame(width: 189, height: 40)
    }

    private static let image: NSImage? = {
        guard let url = DonkeyResourceBundle.app?.url(
            forResource: "google-continue-dark-rounded",
            withExtension: "png"
        ) else {
            return nil
        }

        return NSImage(contentsOf: url)
    }()
}

private struct GoogleContinueFallback: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("G")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.26, green: 0.52, blue: 0.96),
                            Color(red: 0.18, green: 0.66, blue: 0.32),
                            Color(red: 0.98, green: 0.76, blue: 0.18),
                            Color(red: 0.92, green: 0.26, blue: 0.21)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Continue with Google")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.11, green: 0.12, blue: 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.54), lineWidth: 1)
        )
    }
}
