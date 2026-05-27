import DonkeyContracts
import Foundation
import Sparkle

@MainActor
protocol DonkeyUpdateChecking: AnyObject {
    var currentVersion: String { get }
    var updateStateChanged: ((UserQueryUpdateState) -> Void)? { get set }

    func start()
    func checkForUpdatesInBackground()
    func showUpdateUI()
}

@MainActor
final class SparkleUpdateController: NSObject, DonkeyUpdateChecking, SPUUpdaterDelegate {
    private var updaterController: SPUStandardUpdaterController?

    var updateStateChanged: ((UserQueryUpdateState) -> Void)?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ??
            "0.1.0"
    }

    func start() {
        guard updaterController == nil else { return }
        guard isSparkleConfigured else {
            updateStateChanged?(
                UserQueryUpdateState(
                    status: .unavailable,
                    currentVersion: currentVersion,
                    message: "Sparkle feed not configured"
                )
            )
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    func checkForUpdatesInBackground() {
        guard let updaterController else {
            updateStateChanged?(
                UserQueryUpdateState(
                    status: .unavailable,
                    currentVersion: currentVersion,
                    message: "Updater unavailable"
                )
            )
            return
        }

        updateStateChanged?(
            UserQueryUpdateState(
                status: .checking,
                currentVersion: currentVersion
            )
        )
        updaterController.updater.checkForUpdatesInBackground()
    }

    func showUpdateUI() {
        guard let updaterController else {
            checkForUpdatesInBackground()
            return
        }

        updaterController.checkForUpdates(nil)
    }

    private var isSparkleConfigured: Bool {
        let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String

        return feedURL?.isEmpty == false && publicKey?.isEmpty == false
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateStateChanged?(
            UserQueryUpdateState(
                status: .available,
                currentVersion: currentVersion,
                latestVersion: item.displayVersionString
            )
        )
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        updateStateChanged?(
            UserQueryUpdateState(
                status: .upToDate,
                currentVersion: currentVersion,
                message: error.localizedDescription
            )
        )
    }
}
