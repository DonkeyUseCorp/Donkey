import Foundation

/// Locates a SwiftPM-generated resource bundle (`<Package>_<Target>.bundle`) inside a packaged,
/// code-signed macOS app.
///
/// The compiler-generated `Bundle.module` accessor only looks for the bundle at
/// `Bundle.main.bundleURL` — the `.app` root — and `fatalError`s when it is absent. A signed,
/// notarized app may not keep loose content at the bundle root (codesign rejects it as "unsealed
/// contents present in the bundle root"), so packaging stages these bundles under
/// `Contents/Resources`. Reaching for `Bundle.module` in the shipped app therefore traps on first
/// access. This resolver searches the signing-valid locations instead and returns nil rather than
/// crashing when a bundle is genuinely missing.
public enum DonkeyResourceBundle {
    /// The bundle named `name` (with or without the `.bundle` suffix), or nil if it cannot be found.
    /// Searches `Contents/Resources` first (the packaged app) and then the executable's own
    /// directory (the `swift build` / `swift run` layout), which together cover release and dev.
    public static func named(_ name: String) -> Bundle? {
        let fileName = name.hasSuffix(".bundle") ? name : name + ".bundle"
        let searchRoots = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        for root in searchRoots {
            if let bundle = Bundle(url: root.appendingPathComponent(fileName)) {
                return bundle
            }
        }
        return nil
    }

    /// The DonkeyRuntime target's own resource bundle (`bundled-tools.json`, the local-app finder
    /// profiles, and the BuiltInSkills tree).
    public static let runtime = named("Donkey_DonkeyRuntime")

    /// The Donkey executable target's resource bundle (app icon, sign-in art, theme).
    public static let app = named("Donkey_Donkey")
}
