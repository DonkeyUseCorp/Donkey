import AppKit
import DonkeyContracts
import DonkeyRuntime

/// The menu bar entry point: a status item with the Donkey glyph whose menu carries "Go to App",
/// the update section — with an install item whenever a Sparkle background check has an update
/// waiting — and Quit. The menu is rebuilt each time it opens, so it always reflects the current
/// update state without push updates from the app delegate.
@MainActor
final class DonkeyStatusItemController: NSObject, NSMenuDelegate {
    /// The hosted app "Go to App" opens — the Cut app, same destination as the billing page's host.
    private static let appURL = URL(string: "https://donkeycut.com/app")!

    private let statusItem: NSStatusItem
    private let checkForUpdates: () -> Void
    private let installUpdate: () -> Void

    /// Latest update-checker state; drives the update section of the menu. Setting it while the menu
    /// is open refreshes the update row in place, so a user-triggered check spins and resolves without
    /// the menu having to be reopened.
    var updateState: UserQueryUpdateState? {
        didSet { refreshLiveUpdateItem() }
    }

    /// The update row of the currently-open menu, held so state changes can refresh it in place. Weak:
    /// the menu owns the view, and it drops away when the menu is next rebuilt.
    private weak var liveUpdateView: UpdateMenuItemView?

    init(
        checkForUpdates: @escaping () -> Void,
        installUpdate: @escaping () -> Void
    ) {
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
        populateMenuItems(in: menu)
    }

    /// The shared item set — Go to App, the update section, and Quit. The status-item menu is
    /// exactly this; the app main menu appends it after About.
    func populateMenuItems(in menu: NSMenu) {
        menu.addItem(makeItem(title: "Go to App", action: #selector(goToAppAction)))

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
    /// a spinning progress line while checking or installing, and "Update App" once a check has an
    /// update waiting — choosing it downloads, installs, quits, and relaunches automatically.
    ///
    /// The row is a custom view so a click keeps the menu open and spins in place instead of
    /// dismissing it; `liveUpdateView` holds it so later state changes refresh it live.
    private func updateItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = UpdateMenuItemView { [weak self] in self?.handleUpdateItemClick() }
        applyUpdatePresentation(to: view)
        item.view = view
        liveUpdateView = view
        return item
    }

    /// The title / clickability / busy triple the update row shows for the current checker state.
    private func updatePresentation() -> (title: String, isClickable: Bool, isBusy: Bool) {
        switch updateState?.status {
        case .available:
            let title = updateState?.latestVersion.map { "Update App (\($0))" } ?? "Update App"
            return (title, true, false)
        case .checking:
            return ("Checking for Updates…", false, true)
        case .installing:
            return ("Updating…", false, true)
        default:
            return ("Check for Updates", true, false)
        }
    }

    private func applyUpdatePresentation(to view: UpdateMenuItemView) {
        let presentation = updatePresentation()
        view.configure(
            title: presentation.title,
            isClickable: presentation.isClickable,
            isBusy: presentation.isBusy
        )
    }

    private func refreshLiveUpdateItem() {
        guard let liveUpdateView else { return }
        applyUpdatePresentation(to: liveUpdateView)
    }

    /// Route an update-row tap by the current state: install a waiting update, or start a check.
    /// While a check or install is running the row is non-clickable, so no tap arrives here.
    private func handleUpdateItemClick() {
        switch updateState?.status {
        case .available:
            installUpdate()
        case .checking, .installing:
            break
        default:
            checkForUpdates()
        }
    }

    @objc private func goToAppAction(_ sender: Any?) {
        NSWorkspace.shared.open(Self.appURL)
    }

    @objc private func quitAction(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    /// The donkey glyph as a template image: pure black plus alpha, so the system recolors it
    /// for light/dark menu bars and the selected state (Apple's status-item guideline).
    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        for resource in ["menu-bar-icon", "menu-bar-icon@2x"] {
            guard let url = DonkeyResourceBundle.app?.url(forResource: resource, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else { continue }
            representation.size = image.size
            image.addRepresentation(representation)
        }
        image.isTemplate = true
        return image
    }
}
