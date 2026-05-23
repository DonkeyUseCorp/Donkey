import AppKit
import SwiftUI

@MainActor
final class DonkeyLoginWindowController: NSWindowController {
    private let authCoordinator: DonkeyAuthCoordinator

    init(authCoordinator: DonkeyAuthCoordinator) {
        self.authCoordinator = authCoordinator

        let contentView = DonkeyLoginView(authCoordinator: authCoordinator)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 820, height: 680),
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

    var body: some View {
        ZStack {
            Color(red: 0.13, green: 0.13, blue: 0.12)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 68)

                DonkeyBurstMark()
                    .frame(width: 86, height: 86)
                    .padding(.bottom, 58)

                Text("Donkey for Mac")
                    .font(.system(size: 48, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .padding(.bottom, 18)

                Text("Sign in to start using Donkey on this Mac.")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(0.58))

                Spacer(minLength: 76)

                VStack(spacing: 16) {
                    Button {
                        authCoordinator.beginGoogleSignIn()
                    } label: {
                        HStack(spacing: 14) {
                            GoogleLetterMark()
                                .frame(width: 25, height: 25)
                            Text(buttonTitle)
                                .font(.system(size: 23, weight: .semibold))
                        }
                        .foregroundStyle(.black.opacity(0.82))
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(buttonIsDisabled ? 0.68 : 0.96))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(buttonIsDisabled)
                    .accessibilityLabel("Continue with Google")

                    statusText
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(statusColor)
                        .frame(height: 20)
                }
                .frame(width: 560)
                .padding(.bottom, 70)
            }
            .padding(.horizontal, 52)
        }
    }

    private var buttonTitle: String {
        switch authCoordinator.phase {
        case .openingBrowser:
            return "Opening Google..."
        case .waitingForCallback:
            return "Waiting for Google..."
        case .exchangingSession:
            return "Signing in..."
        default:
            return "Continue with Google"
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

private struct DonkeyBurstMark: View {
    private let rayCount = 12

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.87, green: 0.43, blue: 0.28))

            ForEach(0..<rayCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(.white)
                    .frame(width: 6, height: 54)
                    .offset(y: -21)
                    .rotationEffect(.degrees(Double(index) * (360 / Double(rayCount))))
            }
        }
        .shadow(color: .black.opacity(0.24), radius: 20, y: 14)
    }
}

private struct GoogleLetterMark: View {
    var body: some View {
        Text("G")
            .font(.system(size: 25, weight: .bold, design: .rounded))
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
    }
}
