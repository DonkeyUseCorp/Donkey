@preconcurrency import ApplicationServices
import AppKit
import AVFoundation
import CoreGraphics
import DonkeyRuntime
import SwiftUI

@MainActor
final class MacPermissionSetupWindowController: NSWindowController, NSWindowDelegate {
    var completed: (() -> Void)?

    private let model: MacPermissionSetupModel
    private var didComplete = false

    init(model: MacPermissionSetupModel = MacPermissionSetupModel()) {
        self.model = model
        let view = MacPermissionSetupView(model: model)
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Enable Donkey Permissions"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 640, height: 600))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        // Continue/Skip just closes the window. Closing — whether from those buttons or the X — is the
        // single place that fires `completed`, so the overlay (notch) starts up regardless of how the
        // user dismisses this window.
        model.completed = { [weak self] in
            self?.close()
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        guard !didComplete else { return }
        didComplete = true
        completed?()
    }

    var permissionsAreReady: Bool {
        model.refresh()
        return model.canContinue
    }

    func showSetup() {
        model.refresh()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class MacPermissionSetupModel: ObservableObject {
    @Published private(set) var statuses: [MacPermissionKind: MacPermissionAuthorizationStatus] = [:]
    @Published private(set) var requestedKinds: Set<MacPermissionKind> = []
    @Published private(set) var requestingKind: MacPermissionKind?

    var completed: (() -> Void)?

    private let requester: any MacPermissionRequesting
    private let defaults: UserDefaults
    private let requestedDefaultsKey = "MacPermissionSetup.RequestedKinds"
    /// True once the screen-recording system prompt has been triggered in this app session. The
    /// first Enable tap should let that prompt stand; only a later tap falls back to System Settings.
    private var didTriggerScreenRecordingPrompt = false

    init(
        requester: any MacPermissionRequesting = SystemMacPermissionRequester(),
        defaults: UserDefaults = .standard
    ) {
        self.requester = requester
        self.defaults = defaults
        requestedKinds = Self.loadRequestedKinds(
            defaults: defaults,
            key: requestedDefaultsKey
        )
        refresh()
    }

    var rows: [MacPermissionRowState] {
        MacPermissionSetupStateResolver(requestedKinds: requestedKinds)
            .rows(statuses: statuses)
    }

    var canContinue: Bool {
        MacPermissionSetupStateResolver(requestedKinds: requestedKinds)
            .allRequiredPermissionsGranted(statuses: statuses)
    }

    func refresh() {
        statuses = Dictionary(
            uniqueKeysWithValues: MacPermissionKind.coreSetup.map { kind in
                (kind, requester.status(for: kind))
            }
        )
    }

    func request(_ kind: MacPermissionKind) async {
        guard requestingKind == nil else { return }

        // Screen recording is special: macOS shows its prompt only on the first
        // CGRequestScreenCaptureAccess() from a not-determined state, and the call returns
        // synchronously still "not granted" while that prompt is on screen. Re-calling it on a
        // later tap just stacks a second identical prompt, and opening System Settings right after
        // the first call would pop the settings window on top of the prompt before the user can
        // answer it. So request exactly once; on any later tap (still not granted) skip the request
        // and route straight to System Settings. That fallback also covers the stale-record case
        // where the first request silently no-ops and no prompt ever appears.
        if kind == .screenRecording, didTriggerScreenRecordingPrompt, statuses[kind] != .granted {
            requester.openSystemSettings(for: kind)
            return
        }

        requestingKind = kind
        rememberRequested(kind)
        let status = await requester.request(kind)
        statuses[kind] = status
        refresh()
        requestingKind = nil

        if kind == .screenRecording, statuses[kind] != .granted {
            didTriggerScreenRecordingPrompt = true
        }
    }

    func openSystemSettings(for kind: MacPermissionKind) {
        requester.openSystemSettings(for: kind)
    }

    func continueIfReady() {
        refresh()
        guard canContinue else { return }
        completed?()
    }

    func skipForNow() {
        completed?()
    }

    private func rememberRequested(_ kind: MacPermissionKind) {
        requestedKinds.insert(kind)
        defaults.set(
            requestedKinds.map(\.rawValue).sorted(),
            forKey: requestedDefaultsKey
        )
    }

    private static func loadRequestedKinds(
        defaults: UserDefaults,
        key: String
    ) -> Set<MacPermissionKind> {
        Set(
            defaults.stringArray(forKey: key)?
                .compactMap(MacPermissionKind.init(rawValue:)) ?? []
        )
    }
}

@MainActor
protocol MacPermissionRequesting {
    func status(for kind: MacPermissionKind) -> MacPermissionAuthorizationStatus
    func request(_ kind: MacPermissionKind) async -> MacPermissionAuthorizationStatus
    func openSystemSettings(for kind: MacPermissionKind)
}

@MainActor
final class SystemMacPermissionRequester: MacPermissionRequesting {
    func status(for kind: MacPermissionKind) -> MacPermissionAuthorizationStatus {
        switch kind {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .granted
            case .notDetermined:
                return .notDetermined
            case .denied, .restricted:
                return .denied
            @unknown default:
                return .denied
            }
        }
    }

    func request(_ kind: MacPermissionKind) async -> MacPermissionAuthorizationStatus {
        switch kind {
        case .accessibility:
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return status(for: kind)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
            return status(for: kind)
        case .microphone:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
            return granted ? .granted : status(for: kind)
        }
    }

    func openSystemSettings(for kind: MacPermissionKind) {
        guard let url = URL(string: settingsURLString(for: kind)) else { return }
        NSWorkspace.shared.open(url)
    }

    private func settingsURLString(for kind: MacPermissionKind) -> String {
        switch kind {
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
    }
}

private struct MacPermissionSetupView: View {
    @ObservedObject var model: MacPermissionSetupModel
    private let permissionRefreshTimer = Timer.publish(
        every: 1,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Enable Donkey Permissions")
                    .font(.system(size: 30, weight: .semibold))
                Text("Donkey needs these Mac permissions before it can reliably understand windows, use voice input, and act on approved local-app workflows.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                ForEach(model.rows) { row in
                    MacPermissionRowView(
                        row: row,
                        isRequesting: model.requestingKind == row.kind,
                        enable: {
                            Task { await model.request(row.kind) }
                        },
                        openSettings: {
                            model.openSystemSettings(for: row.kind)
                        }
                    )
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button("Skip for now") {
                    model.skipForNow()
                }
                .controlSize(.large)

                Spacer()

                Button("Continue") {
                    model.continueIfReady()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!model.canContinue)
            }
        }
        .padding(EdgeInsets(top: 28, leading: 28, bottom: 44, trailing: 28))
        .frame(minWidth: 640, minHeight: 600)
        .onAppear {
            model.refresh()
        }
        .onReceive(permissionRefreshTimer) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}

private struct MacPermissionRowView: View {
    var row: MacPermissionRowState
    var isRequesting: Bool
    var enable: () -> Void
    var openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconBackgroundColor)
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(row.kind.title)
                        .font(.headline)
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }
                Text(row.kind.reason)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.kind.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(actionTitle) {
                switch row.action {
                case .enable:
                    enable()
                case .openSystemSettings:
                    openSettings()
                case .ready:
                    break
                }
            }
            .controlSize(.large)
            .disabled(row.action == .ready || isRequesting)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        switch row.kind {
        case .accessibility:
            return "hand.raised"
        case .screenRecording:
            return "rectangle.on.rectangle"
        case .microphone:
            return "mic"
        }
    }

    private var iconBackgroundColor: Color {
        row.status == .granted ? Color.green.opacity(0.14) : Color.accentColor.opacity(0.14)
    }

    private var iconColor: Color {
        row.status == .granted ? .green : .accentColor
    }

    private var statusText: String {
        switch row.status {
        case .granted:
            return "Ready"
        case .notDetermined:
            return row.kind.isRequired ? "Needed" : "Optional"
        case .denied:
            return row.kind.isRequired ? "Needs Settings" : "Optional"
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .granted:
            return .green
        case .notDetermined:
            return row.kind.isRequired ? .orange : .secondary
        case .denied:
            return row.kind.isRequired ? .red : .secondary
        }
    }

    private var actionTitle: String {
        if isRequesting {
            return "Checking..."
        }

        switch row.action {
        case .enable:
            return "Enable"
        case .ready:
            return "Ready"
        case .openSystemSettings:
            return "Open System Settings"
        }
    }
}
