import AppKit
import DonkeyContracts

/// The menu bar entry point: a status item with the Donkey glyph whose menu follows the
/// session — "Go to App" and "Log out" while signed in, "Log in" while signed out — plus an
/// install item whenever a Sparkle background check has an update waiting. The menu is rebuilt
/// each time it opens, so it always reflects the current auth and update state without push
/// updates from the app delegate.
@MainActor
final class DonkeyStatusItemController: NSObject, NSMenuDelegate {
    /// The hosted app "Go to App" opens — the Cut app, same destination as the billing page's host.
    private static let appURL = URL(string: "https://donkeycut.com/app")!

    private let statusItem: NSStatusItem
    private let isSignedIn: () -> Bool
    private let logIn: () -> Void
    private let logOut: () -> Void
    private let checkForUpdates: () -> Void
    private let installUpdate: () -> Void

    /// Latest update-checker state; drives the update section of the menu.
    var updateState: UserQueryUpdateState?

    init(
        isSignedIn: @escaping () -> Bool,
        logIn: @escaping () -> Void,
        logOut: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void,
        installUpdate: @escaping () -> Void
    ) {
        self.isSignedIn = isSignedIn
        self.logIn = logIn
        self.logOut = logOut
        self.checkForUpdates = checkForUpdates
        self.installUpdate = installUpdate
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    deinit {
        MainActor.assumeIsolated {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if isSignedIn() {
            menu.addItem(makeItem(title: "Go to App", action: #selector(goToAppAction)))
            menu.addItem(makeItem(title: "Log out", action: #selector(logOutAction)))
        } else {
            menu.addItem(makeItem(title: "Log in", action: #selector(logInAction)))
        }

        menu.addItem(.separator())
        menu.addItem(updateItem())

        menu.addItem(.separator())
        menu.addItem(makeItem(title: "Quit Donkey", action: #selector(quitAction), keyEquivalent: "q"))
    }

    private func makeItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    /// The update section's single item, following the checker state: "Check for Updates" at rest,
    /// a disabled progress line while checking or installing, and "Update App" once a check has an
    /// update waiting — choosing it downloads, installs, quits, and relaunches automatically.
    private func updateItem() -> NSMenuItem {
        switch updateState?.status {
        case .available:
            let title = updateState?.latestVersion.map { "Update App (\($0))" } ?? "Update App"
            return makeItem(title: title, action: #selector(installUpdateAction))
        case .checking:
            return NSMenuItem(title: "Checking for Updates…", action: nil, keyEquivalent: "")
        case .installing:
            return NSMenuItem(title: "Updating…", action: nil, keyEquivalent: "")
        default:
            return makeItem(title: "Check for Updates", action: #selector(checkForUpdatesAction))
        }
    }

    @objc private func goToAppAction(_ sender: Any?) {
        NSWorkspace.shared.open(Self.appURL)
    }

    @objc private func logInAction(_ sender: Any?) {
        logIn()
    }

    @objc private func logOutAction(_ sender: Any?) {
        logOut()
    }

    @objc private func checkForUpdatesAction(_ sender: Any?) {
        checkForUpdates()
    }

    @objc private func installUpdateAction(_ sender: Any?) {
        installUpdate()
    }

    @objc private func quitAction(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    /// The donkey glyph as a template image: pure black plus alpha, so the system recolors it
    /// for light/dark menu bars and the selected state (Apple's status-item guideline).
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 21, height: 21))
        for resource in ["menu-bar-icon", "menu-bar-icon@2x"] {
            guard let url = Bundle.module.url(forResource: resource, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else { continue }
            representation.size = image.size
            image.addRepresentation(representation)
        }
        image.isTemplate = true
        return image
    }
}
