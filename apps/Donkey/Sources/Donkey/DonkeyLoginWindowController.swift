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
    @State private var screen: DonkeyLoginScreen

    init(authCoordinator: DonkeyAuthCoordinator) {
        self.authCoordinator = authCoordinator
        _screen = State(initialValue: Self.initialScreen(for: authCoordinator.phase))
    }

    var body: some View {
        ZStack {
            Color(red: 0.13, green: 0.13, blue: 0.12)
                .ignoresSafeArea()

            switch screen {
            case .welcome:
                DonkeyWelcomeScreen {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        screen = .googleSignIn
                    }
                }
            case .googleSignIn:
                DonkeyGoogleSignInScreen(
                    authCoordinator: authCoordinator,
                    buttonIsDisabled: buttonIsDisabled,
                    statusColor: statusColor,
                    statusText: { statusText }
                )
            }
        }
        .onChange(of: authCoordinator.phase) { _, phase in
            if phase.requiresGoogleSignInScreen {
                screen = .googleSignIn
            }
        }
    }

    private static func initialScreen(for phase: DonkeyAuthPhase) -> DonkeyLoginScreen {
        phase.requiresGoogleSignInScreen ? .googleSignIn : .welcome
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

private enum DonkeyLoginScreen {
    case welcome
    case googleSignIn
}

private extension DonkeyAuthPhase {
    var requiresGoogleSignInScreen: Bool {
        switch self {
        case .openingBrowser, .waitingForCallback, .exchangingSession, .failed:
            return true
        case .signedOut, .signedIn:
            return false
        }
    }
}

private struct DonkeyWelcomeScreen: View {
    var getStarted: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 118)

            DonkeyAppIconMark()
                .frame(width: 88, height: 88)
                .padding(.bottom, 28)

            Text("Donkey")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.bottom, 10)

            Text("Get Donkey set up on this Mac.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))

            Spacer().frame(height: 132)

            Button(action: getStarted) {
                Text("Get started")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.84))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.96))
                    )
            }
            .buttonStyle(.plain)
            .frame(width: 294)
            .accessibilityLabel("Get started")
            .padding(.bottom, 56)
        }
        .padding(.horizontal, 52)
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

private struct DonkeyAppIconMark: View {
    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.24), radius: 24, y: 16)
    }

    private static let image: NSImage = {
        if let url = DonkeyResourceBundle.app?.url(forResource: "donkey-app-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        return NSApp.applicationIconImage
    }()
}

private struct GoogleContinueAsset: View {
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
