import AppKit
import DonkeyRuntime
import SwiftUI

@MainActor
final class LocalRuntimeOnboardingWindowController: NSWindowController {
    private let model: LocalRuntimeOnboardingModel

    init(model: LocalRuntimeOnboardingModel = LocalRuntimeOnboardingModel()) {
        self.model = model
        let view = LocalRuntimeOnboardingView(model: model)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Donkey Setup"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 260))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showIfSetupNeeded() {
        Task {
            await model.refresh()
            guard model.needsSetup else { return }
            showWindow(nil)
            window?.center()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@MainActor
final class LocalRuntimeOnboardingModel: ObservableObject {
    @Published private(set) var state: LocalRuntimeSetupViewState = .checking
    @Published private(set) var summary = "Checking Donkey setup..."
    @Published private(set) var detail = "Donkey uses local model runtimes for voice, screenshots, and UI understanding."

    private let manager: LocalModelRuntimeSetupManager
    private var retryRuntimeIDs: [LocalModelRuntimeID] = []

    init(manager: LocalModelRuntimeSetupManager? = nil) {
        self.manager = manager ?? (try! LocalModelRuntimeSetupManager())
    }

    var needsSetup: Bool {
        state != .ready
    }

    var setupButtonTitle: String {
        switch state {
        case .checking:
            return "Checking..."
        case .setupNeeded:
            return "Set Up"
        case .needsAttention:
            return "Retry Setup"
        case .settingUp:
            return "Setting Up..."
        case .ready:
            return "Ready"
        }
    }

    var setupButtonDisabled: Bool {
        state == .checking || state == .settingUp || state == .ready
    }

    func refresh() async {
        state = .checking
        do {
            let statuses = try manager.statuses()
            let missingCount = statuses.filter { $0.state != .installed }.count
            if missingCount == 0 {
                retryRuntimeIDs.removeAll()
                state = .ready
                summary = "Donkey is ready."
                detail = "Required local runtimes are installed and available to the app."
            } else {
                retryRuntimeIDs = statuses
                    .filter { $0.state != .installed }
                    .map(\.spec.id)
                state = .setupNeeded
                summary = "Finish local setup."
                detail = "Donkey will download, verify, install, and health-check the required local runtime packages."
            }
        } catch {
            state = .needsAttention
            summary = "Setup needs attention."
            detail = "Could not read local runtime setup: \(String(describing: error))"
        }
    }

    func setup() async {
        state = .settingUp
        summary = "Setting up Donkey..."
        detail = "Downloading and verifying local runtime packages."

        do {
            let statuses = try manager.statuses()
            let missingRuntimeIDs = statuses
                .filter { $0.state != .installed }
                .map(\.spec.id)
            let runtimeIDsToInstall = manager.instructions()
                .map(\.spec.id)
                .filter { runtimeID in
                    missingRuntimeIDs.contains(runtimeID) || retryRuntimeIDs.contains(runtimeID)
                }

            for (index, runtimeID) in runtimeIDsToInstall.enumerated() {
                do {
                    _ = try await manager.downloadAndInstall(runtimeID: runtimeID)
                } catch LocalModelRuntimeSetupError.manifestMissingDownloadURL {
                    retryRuntimeIDs = Array(runtimeIDsToInstall[index...])
                    openDownloadPage(runtimeID)
                    throw LocalRuntimeOnboardingError.automaticPackageUnavailable
                } catch {
                    retryRuntimeIDs = Array(runtimeIDsToInstall[index...])
                    throw error
                }
            }

            let healthFailures = try await recheckInstalledRuntimes()
            if healthFailures.isEmpty {
                retryRuntimeIDs.removeAll()
                state = .ready
                summary = "Donkey is ready."
                detail = "Local runtimes are installed, verified, and healthy."
            } else {
                retryRuntimeIDs = healthFailures
                state = .needsAttention
                summary = "Setup needs attention."
                detail = "A runtime installed but did not pass its health check. Retry setup to reinstall the failed runtime."
            }
        } catch LocalRuntimeOnboardingError.automaticPackageUnavailable {
            state = .needsAttention
            summary = "Runtime packages are not ready for automatic setup yet."
            detail = "Opened the runtime download page. Retry setup after the compatible package is available; already installed runtimes will be kept."
        } catch {
            state = .needsAttention
            summary = "Setup failed."
            detail = "\(String(describing: error)) Retry setup to continue from the failed runtime."
        }
    }

    private func recheckInstalledRuntimes() async throws -> [LocalModelRuntimeID] {
        var failedRuntimeIDs: [LocalModelRuntimeID] = []
        for instruction in manager.instructions() {
            let report = try await manager.recheckHealth(runtimeID: instruction.spec.id)
            guard report.state == .healthy else {
                failedRuntimeIDs.append(instruction.spec.id)
                continue
            }
        }
        return failedRuntimeIDs
    }

    private func openDownloadPage(_ runtimeID: LocalModelRuntimeID) {
        guard let url = manager.instructions()
            .first(where: { $0.spec.id == runtimeID })?
            .spec
            .downloadPageURL
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

enum LocalRuntimeSetupViewState: Equatable {
    case checking
    case setupNeeded
    case settingUp
    case ready
    case needsAttention
}

private enum LocalRuntimeOnboardingError: Error {
    case automaticPackageUnavailable
}

private struct LocalRuntimeOnboardingView: View {
    @ObservedObject var model: LocalRuntimeOnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set Up Donkey")
                    .font(.title2.weight(.semibold))
                Text(model.summary)
                    .font(.headline)
                Text(model.detail)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(model.setupButtonTitle) {
                    Task { await model.setup() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.setupButtonDisabled)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 260)
        .task {
            await model.refresh()
        }
    }
}
