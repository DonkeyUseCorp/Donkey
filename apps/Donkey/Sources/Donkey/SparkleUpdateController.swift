import DonkeyContracts
import Foundation
import Sparkle

@MainActor
protocol DonkeyUpdateChecking: AnyObject {
    var currentVersion: String { get }
    var updateStateChanged: ((UserQueryUpdateState) -> Void)? { get set }

    func start()
    func checkForUpdatesInBackground()
    func installAvailableUpdate()
}

/// Drives Sparkle with no windows. A background check that finds an update surfaces the notch
/// "Update Available" button; tapping it (`installAvailableUpdate`) downloads, installs, and
/// relaunches silently. Sparkle's standard update dialog is never shown.
@MainActor
final class SparkleUpdateController: NSObject, DonkeyUpdateChecking, SPUUserDriver {
    private var updater: SPUUpdater?
    /// The install decision Sparkle hands us when it finds an update. We hold it until the user
    /// taps the notch button, then answer `.install` to begin the silent download.
    private var pendingInstall: ((SPUUserUpdateChoice) -> Void)?

    var updateStateChanged: ((UserQueryUpdateState) -> Void)?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ??
            "0.1.0"
    }

    func start() {
        guard updater == nil else { return }
        guard isSparkleConfigured else {
            emit(.unavailable, message: "Sparkle feed not configured")
            return
        }

        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: self,
            delegate: nil
        )
        do {
            try updater.start()
            self.updater = updater
        } catch {
            emit(.unavailable, message: error.localizedDescription)
        }
    }

    func checkForUpdatesInBackground() {
        guard let updater else {
            emit(.unavailable, message: "Updater unavailable")
            return
        }

        emit(.checking)
        updater.checkForUpdatesInBackground()
    }

    /// The user tapped the notch button. Resume the update Sparkle already found and let it run to
    /// completion silently; if nothing is pending, kick a fresh background check.
    func installAvailableUpdate() {
        guard let pendingInstall else {
            checkForUpdatesInBackground()
            return
        }

        self.pendingInstall = nil
        pendingInstall(.install)
    }

    private var isSparkleConfigured: Bool {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String

        return feedURL?.isEmpty == false && publicKey?.isEmpty == false
    }

    private func emit(
        _ status: UserQueryUpdateStatus,
        latestVersion: String? = nil,
        message: String? = nil
    ) {
        updateStateChanged?(
            UserQueryUpdateState(
                status: status,
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                message: message
            )
        )
    }

    // MARK: - SPUUserDriver

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        // Hold the decision and light up the notch button instead of installing immediately.
        pendingInstall = reply
        emit(.available, latestVersion: appcastItem.displayVersionString)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error) async {
        emit(.upToDate, message: error.localizedDescription)
    }

    func showUpdaterError(_ error: any Error) async {
        pendingInstall = nil
        emit(.failed, message: error.localizedDescription)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {}

    func showDownloadDidStartExtractingUpdate() {}

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.install)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {}

    func dismissUpdateInstallation() {
        pendingInstall = nil
    }
}
