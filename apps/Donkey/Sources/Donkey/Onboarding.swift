// Donkey's first-run onboarding slideshow: a feature walkthrough presented in a
// borderless, draggable, card-sized floating window on launch.
//
// Adapted from TourKit (https://github.com/rampatra/TourKit), MIT License,
// Copyright (c) 2026 Ram Patra. The MIT permission notice is preserved per its
// terms; everything here is renamed and maintained as part of Donkey.

import DonkeyRuntime
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A single onboarding slide: artwork plus a headline and supporting copy.
struct OnboardingPage: Identifiable, Hashable, @unchecked Sendable {
    let id: UUID
    let imageName: String
    let imageBundle: Bundle?
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    /// Optional `.strings` / `.xcstrings` table name used to look up `title` and
    /// `description`. When `nil`, the default `Localizable` table is used.
    let tableName: String?
    /// Bundle used to look up localized strings for `title` and `description`.
    /// When `nil`, falls back to `imageBundle`, which is typically the caller's
    /// module bundle.
    let stringsBundle: Bundle?
    /// Per-slide gradient backdrop rendered behind the artwork. When `nil`, the
    /// slide falls back to the card's flat dark fill.
    let background: OnboardingSlideBackground?

    init(
        id: UUID = UUID(),
        imageName: String,
        imageBundle: Bundle? = nil,
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        tableName: String? = nil,
        stringsBundle: Bundle? = nil,
        background: OnboardingSlideBackground? = nil
    ) {
        self.id = id
        self.imageName = imageName
        self.imageBundle = imageBundle
        self.title = title
        self.description = description
        self.tableName = tableName
        self.stringsBundle = stringsBundle
        self.background = background
    }

    /// Bundle used for localized string lookup. Prefers `stringsBundle`, then
    /// `imageBundle`, else `nil` (SwiftUI default).
    var resolvedStringsBundle: Bundle? {
        stringsBundle ?? imageBundle
    }

    static func == (lhs: OnboardingPage, rhs: OnboardingPage) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// A per-slide gradient backdrop. Every slide shares the same blue wash; only
/// the spotlight distinguishes them — its position moves and its intensity
/// visibly brightens and dims as the walkthrough advances.
struct OnboardingSlideBackground: Sendable {
    /// Where the spotlight bloom sits over the shared blue wash.
    var bloomCenter: UnitPoint
    /// Bloom strength, 0...1. Spread widely across slides so the brightness
    /// shift reads clearly from one slide to the next.
    var bloomIntensity: Double

    /// The colour the wash resolves to at the bottom edge — matched to the card
    /// fill so the gradient seams invisibly into the text panel below.
    static let baseFill = Color(white: 0.10)
}

struct OnboardingSlideBackgroundView: View {
    let background: OnboardingSlideBackground

    /// The shared blue wash. Every slide uses these exact colours; only the
    /// spotlight (position + intensity) changes between slides.
    private static let washTop = Color(red: 0.16, green: 0.38, blue: 0.96)
    private static let washMiddle = Color(red: 0.07, green: 0.17, blue: 0.52)
    /// Bright sky-blue spotlight — kept blue rather than white so a strong bloom
    /// glows without washing the hue out.
    private static let bloomColor = Color(red: 0.60, green: 0.82, blue: 1.0)

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Self.washTop, location: 0.0),
                    .init(color: Self.washMiddle, location: 0.55),
                    .init(color: OnboardingSlideBackground.baseFill, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    Self.bloomColor.opacity(background.bloomIntensity),
                    .clear
                ],
                center: background.bloomCenter,
                startRadius: 0,
                endRadius: 420
            )
            .blendMode(.screen)
        }
        // Flatten the blend into its own layer so the bloom screens only over
        // this slide's wash, never over the artwork or controls above it.
        .drawingGroup()
    }
}

struct OnboardingSlideshowView: View {
    let pages: [OnboardingPage]
    /// Fixed content width of the slideshow card. The image region's height
    /// is `width / imageAspectRatio` and is locked once at init time, so
    /// every slide renders its artwork at exactly the same absolute size.
    let width: CGFloat
    let continueButtonTitle: LocalizedStringKey
    let finishButtonTitle: LocalizedStringKey
    let buttonTableName: String?
    let buttonBundle: Bundle?
    let onFinish: (() -> Void)?
    /// Dismisses the card without finishing the tour. Wired to the top-right
    /// close button so the user always has a way out — including a signed-out
    /// user who doesn't want to sign in right now.
    let onClose: (() -> Void)?
    /// When non-nil, the FIRST slide is the sign-in landing — it renders this
    /// footer (Donkey's Google button) with an "Explore" link beneath — and the
    /// final feature slide renders the same footer so it takes the user straight
    /// into sign-in. When `nil`, the tour is a plain walkthrough ending in the
    /// finish button.
    let signInFooter: (() -> AnyView)?
    @Environment(\.dismiss) private var dismiss
    @State var currentIndex: Int

    init(
        pages: [OnboardingPage],
        width: CGFloat = 660,
        initialPageIndex: Int = 0,
        continueButtonTitle: LocalizedStringKey = "Continue",
        finishButtonTitle: LocalizedStringKey = "Done",
        buttonTableName: String? = nil,
        buttonBundle: Bundle? = nil,
        onFinish: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        signInFooter: (() -> AnyView)? = nil
    ) {
        self.pages = pages
        self.width = width
        self.continueButtonTitle = continueButtonTitle
        self.finishButtonTitle = finishButtonTitle
        self.buttonTableName = buttonTableName
        self.buttonBundle = buttonBundle
        self.onFinish = onFinish
        self.onClose = onClose
        self.signInFooter = signInFooter
        _currentIndex = State(initialValue: Self.clamped(initialPageIndex, pageCount: pages.count))
    }

    /// Absolute pixel height of the image region, rounded to whole points
    /// so the artwork's edges never anti-alias against the card background.
    var imageHeight: CGFloat {
        (width / Self.imageAspectRatio).rounded()
    }

    var body: some View {
        Group {
            if pages.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    imageSection
                    bottomPanel
                }
                .background(Color(white: 0.10))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
            }
        }
        .frame(width: width)
        // Left/right arrow keys page through the slides. Hidden buttons carry the
        // shortcuts so they fire whenever the card window is key, without having to
        // manage first-responder focus. They page only — never the finish/sign-in
        // action — and clamp at the first and last slide.
        .background {
            ZStack {
                Button("") { goToPage(currentIndex - 1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { goToPage(currentIndex + 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        // Purely visual animation: drives the slide cross-fade and the
        // page-indicator's active-dot slide. Layout size never changes
        // because the hosting window is locked to the tallest slide.
        .animation(.easeInOut(duration: 0.25), value: currentIndex)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No onboarding pages")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: - Image section (top ~55%)

    /// Recommended onboarding artwork aspect ratio (width : height).
    ///
    /// `imageHeight = width / imageAspectRatio` is locked at init time so
    /// the image is rendered at a stable absolute size on every slide.
    static let imageAspectRatio: CGFloat = 16.0 / 10.0

    private var imageSection: some View {
        // Only the artwork participates in the cross-fade. The gradient
        // and page indicator are siblings of the transitioning image in
        // this ZStack so they stay at full opacity across slide changes;
        // if they were `.overlay`s on the image they'd be part of its
        // `.id + .transition(.opacity)` subtree and visibly fade out and
        // back in at the transition's midpoint.
        ZStack(alignment: .top) {
            if let background = pages[currentIndex].background {
                OnboardingSlideBackgroundView(background: background)
                    .frame(width: width, height: imageHeight)
                    .id(currentIndex)
                    .transition(.opacity)
            }

            image(for: pages[currentIndex])
                .resizable()
                .scaledToFit()
                .frame(width: width, height: imageHeight)
                .id(currentIndex)
                .transition(.opacity)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color(white: 0.10).opacity(0.15), location: 0.25),
                    .init(color: Color(white: 0.10).opacity(0.45), location: 0.50),
                    .init(color: Color(white: 0.10).opacity(0.80), location: 0.75),
                    .init(color: Color(white: 0.10), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 220)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)

            OnboardingPageIndicator(totalPages: pages.count, currentIndex: currentIndex) { index in
                goToPage(index)
            }
            // Bottom padding is 6 rather than 14 because each dot now carries a
            // 24pt-tall hit band centred on its 8pt visual; the extra 8pt below
            // the dot offsets the smaller pad so the dots sit where they did.
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            topControls
        }
        .frame(width: width, height: imageHeight)
    }

    // MARK: - Bottom panel (dark area with text + button)

    private var bottomPanel: some View {
        let currentPage = pages[currentIndex]

        return VStack(spacing: 0) {
            Text(currentPage.title, tableName: currentPage.tableName, bundle: currentPage.resolvedStringsBundle)
                .font(.system(size: 28, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text(currentPage.description, tableName: currentPage.tableName, bundle: currentPage.resolvedStringsBundle)
                .font(.system(size: 18))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white.opacity(0.70))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            if usesFooterAction {
                if isLastPage {
                    // Closing footer slide (no subtitle): center the CTA so its
                    // gap from the title is about half the bottom-pinned distance.
                    Spacer(minLength: 0)
                    footerActionArea
                    Spacer(minLength: 0)
                } else {
                    // Sign-in footer pins to the card's baseline so the Google
                    // button always lands in the same place.
                    Spacer(minLength: 24)
                    footerActionArea
                        .frame(height: Self.primaryRegionHeight, alignment: .bottom)
                }
            } else {
                // Walkthrough slides sit the Continue button a fixed, tighter
                // gap below the copy and let the slack fall to the bottom. The
                // closing slide halves that gap again to sit Done under the title.
                Color.clear.frame(height: isLastPage ? Self.walkthroughActionGap / 2 : Self.walkthroughActionGap)
                capsuleButton(isLastPage ? finishButtonTitle : continueButtonTitle, action: advance)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Per-slide identity so title, description, and button cross-fade
        // as one unit alongside the image above.
        .id(currentIndex)
        .transition(.opacity)
    }

    // MARK: - Top controls (back / close overlaying the image)

    private var topControls: some View {
        HStack {
            iconButton(systemName: "chevron.left") {
                goBack()
            }
            .opacity(currentIndex > 0 ? 1 : 0)
            .allowsHitTesting(currentIndex > 0)

            Spacer()

            // Always-available escape hatch: closes the card on any slide, so a
            // signed-out user who isn't ready to sign in can still dismiss it.
            iconButton(systemName: "xmark") {
                if let onClose {
                    onClose()
                } else {
                    dismiss()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    // MARK: - Primary CTA

    /// Fixed height reserved for the footer action (the sign-in / closing footer:
    /// Google button + status + Explore link). Footer slides reserve it and
    /// bottom-align their button so it always lands on the same card baseline.
    static let primaryRegionHeight: CGFloat = 96

    /// Height of the pill Continue / Done button.
    static let capsuleButtonHeight: CGFloat = 42

    /// Gap between the copy and the Continue button on walkthrough slides —
    /// roughly half the old spacing. Those slides no longer bottom-pin the
    /// button: it sits just under the copy and the slack falls to the bottom.
    static let walkthroughActionGap: CGFloat = 40

    /// Whether the current slide is the sign-in landing — the first slide, only
    /// when a sign-in footer was injected (signed-out flow).
    private var isSignInSlide: Bool {
        signInFooter != nil && currentIndex == 0
    }

    /// Footer slides keep the bottom-pinned Google button: the sign-in landing
    /// (first slide) and, signed out, the closing slide. Every other slide is a
    /// walkthrough slide that uses the tighter, top-aligned Continue button.
    private var usesFooterAction: Bool {
        signInFooter != nil && (currentIndex == 0 || isLastPage)
    }

    @ViewBuilder
    private var footerActionArea: some View {
        if let signInFooter {
            if isSignInSlide {
                // Sign-in landing: the Google button, with an Explore link
                // beneath that drops into the feature tour.
                VStack(spacing: 12) {
                    signInFooter()
                    exploreLink
                }
            } else {
                // The signed-out tour ends on the Google button itself, so the
                // closing slide takes the user straight into sign-in.
                signInFooter()
            }
        }
    }

    private func capsuleButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title, tableName: buttonTableName, bundle: buttonBundle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 220, height: Self.capsuleButtonHeight)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.10, green: 0.60, blue: 1.0),
                                    Color(red: 0.04, green: 0.46, blue: 0.96)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .clipShape(Capsule(style: .continuous))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    /// "Explore Donkey ›" link under the sign-in button; jumps into the feature
    /// tour, which walks forward and ends back at this sign-in slide.
    private var exploreLink: some View {
        Button(action: exploreFeatures) {
            HStack(spacing: 4) {
                Text("Explore Donkey")
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.72))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Icon button (glass circle)

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 32, height: 32)
                .background {
                    if #available(macOS 26.0, iOS 26.0, *) {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay {
                                Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                            }
                    } else {
                        Circle().fill(Color.white.opacity(0.15))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    var isLastPage: Bool {
        currentIndex == pages.count - 1
    }

    static func clamped(_ index: Int, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return max(0, min(index, pageCount - 1))
    }

    func advance() {
        if isLastPage {
            if let onFinish {
                onFinish()
            } else {
                dismiss()
            }
        } else {
            currentIndex += 1
        }
    }

    func goBack() {
        let newIndex = max(0, currentIndex - 1)
        guard newIndex != currentIndex else { return }
        currentIndex = newIndex
    }

    /// From the sign-in landing, drop into the feature tour (the first feature
    /// slide sits right after the sign-in slide).
    func exploreFeatures() {
        let target = min(1, pages.count - 1)
        guard target != currentIndex else { return }
        currentIndex = target
    }

    /// Jump straight to a slide, used by the clickable page-indicator dots.
    func goToPage(_ index: Int) {
        let target = Self.clamped(index, pageCount: pages.count)
        guard target != currentIndex else { return }
        currentIndex = target
    }

    private func image(for page: OnboardingPage) -> Image {
        if let bundle = page.imageBundle,
           let image = platformImage(named: page.imageName, in: bundle) {
            #if canImport(AppKit)
            return Image(nsImage: image)
            #elseif canImport(UIKit)
            return Image(uiImage: image)
            #else
            return Image(page.imageName, bundle: page.imageBundle)
            #endif
        }

        return Image(page.imageName, bundle: page.imageBundle)
    }

    #if canImport(AppKit)
    private func platformImage(named name: String, in bundle: Bundle) -> NSImage? {
        if let direct = bundle.image(forResource: name) {
            return direct
        }

        let nsName = NSImage.Name((name as NSString).deletingPathExtension)
        if let catalogImage = bundle.image(forResource: nsName) {
            return catalogImage
        }

        return loadImageFromResourceFile(named: name, in: bundle)
    }
    #elseif canImport(UIKit)
    private func platformImage(named name: String, in bundle: Bundle) -> UIImage? {
        if let direct = UIImage(named: name, in: bundle, compatibleWith: nil) {
            return direct
        }

        return loadImageFromResourceFile(named: name, in: bundle)
    }
    #endif

    #if canImport(AppKit)
    private func loadImageFromResourceFile(named name: String, in bundle: Bundle) -> NSImage? {
        if let resourceURL = resourceURL(named: name, in: bundle) {
            return NSImage(contentsOf: resourceURL)
        }
        return nil
    }
    #elseif canImport(UIKit)
    private func loadImageFromResourceFile(named name: String, in bundle: Bundle) -> UIImage? {
        guard let resourceURL = resourceURL(named: name, in: bundle),
              let data = try? Data(contentsOf: resourceURL) else {
            return nil
        }
        return UIImage(data: data)
    }
    #endif

    private func resourceURL(named name: String, in bundle: Bundle) -> URL? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let url = bundle.url(forResource: base, withExtension: ext) {
            return url
        }

        for candidateExt in ["png", "jpg", "jpeg", "heic", "tiff", "gif", "webp"] {
            if let url = bundle.url(forResource: name, withExtension: candidateExt) {
                return url
            }
        }

        return nil
    }
}

#if canImport(AppKit)

/// Presents an `OnboardingSlideshowView` inside a transparent, card-sized, draggable macOS window.
///
/// The window has no title bar, no visible chrome, a transparent background, and is sized
/// to match the onboarding card. It can be dragged around by its background and participates in
/// Mission Control / App Exposé like a normal window.
@MainActor
final class OnboardingWindowController {
    private final class HostWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private var window: NSWindow?
    private var windowDelegate: WindowDelegate?

    init() {}

    /// Presents the onboarding window. If a window is already visible, it is brought to the front.
    ///
    /// When the final slide shows the standard finish button, tapping it runs `onFinish` and then
    /// closes the window. When a `signInFooter` is injected (Donkey's Google sign-in), slide 0 is the
    /// sign-in landing and the window stays up until the caller closes it — typically once sign-in
    /// completes. `initialPageIndex` chooses the slide to open on (e.g. the sign-in landing vs. the tour).
    @discardableResult
    func present(
        pages: [OnboardingPage],
        width: CGFloat = 660,
        initialPageIndex: Int = 0,
        continueButtonTitle: LocalizedStringKey = "Continue",
        finishButtonTitle: LocalizedStringKey = "Done",
        buttonTableName: String? = nil,
        buttonBundle: Bundle? = nil,
        onFinish: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        signInFooter: (() -> AnyView)? = nil
    ) -> NSWindow {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }

        let dismiss: () -> Void = { [weak self] in
            self?.close()
        }

        // Lock the window to the tallest slide's natural content height so
        // every slide renders in the same card size: the absolute image
        // region up top, and a bottom panel whose title, description, and
        // button pin to the top, centre, and bottom of the remaining space
        // respectively. Shorter slides simply get more breathing room.
        let imageHeight = width / OnboardingSlideshowView.imageAspectRatio
        let maxPanelHeight = Self.maxBottomPanelHeight(
            pages: pages,
            width: width,
            hasSignInFooter: signInFooter != nil
        )
        let totalHeight = max(imageHeight + maxPanelHeight, 1)

        let rootView = OnboardingSlideshowView(
            pages: pages,
            width: width,
            initialPageIndex: initialPageIndex,
            continueButtonTitle: continueButtonTitle,
            finishButtonTitle: finishButtonTitle,
            buttonTableName: buttonTableName,
            buttonBundle: buttonBundle,
            onFinish: {
                onFinish?()
                dismiss()
            },
            onClose: {
                dismiss()
            },
            signInFooter: signInFooter
        )

        let contentSize = CGSize(width: width, height: totalHeight)
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: contentSize)

        let window = HostWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
        window.contentView = hosting
        window.center()

        let delegate = WindowDelegate { [weak self] in
            self?.window = nil
            self?.windowDelegate = nil
            onDismiss?()
        }
        window.delegate = delegate
        self.windowDelegate = delegate

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        return window
    }

    /// Returns the tallest bottom-panel natural height across all pages.
    ///
    /// The slideshow window is locked to `imageHeight + maxPanelHeight` so
    /// every slide renders inside the same card footprint: shorter slides
    /// simply get more vertical breathing room between their title,
    /// description, and button (which pin to top, centre, and bottom of the
    /// panel respectively).
    private static func maxBottomPanelHeight(
        pages: [OnboardingPage],
        width: CGFloat,
        hasSignInFooter: Bool
    ) -> CGFloat {
        guard !pages.isEmpty else { return 0 }

        return pages.enumerated().map { index, page in
            let usesFooterAction = hasSignInFooter && (index == 0 || index == pages.count - 1)
            let sizingView = OnboardingBottomPanelSizingView(page: page, usesFooterAction: usesFooterAction)
                .frame(width: width)

            let hosting = NSHostingView(rootView: sizingView)
            hosting.layoutSubtreeIfNeeded()
            return hosting.fittingSize.height
        }.max() ?? 0
    }

    /// Closes the onboarding window if it is currently presented.
    func close() {
        window?.close()
        window = nil
        windowDelegate = nil
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
    }
}

/// A layout-equivalent stand-in for `OnboardingSlideshowView`'s bottom panel used
/// purely to pre-measure its intrinsic height. Mirrors the real panel's
/// modifier chain so `NSHostingView.fittingSize` matches what the actual
/// slideshow will render at runtime.
private struct OnboardingBottomPanelSizingView: View {
    let page: OnboardingPage
    let usesFooterAction: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(page.title, tableName: page.tableName, bundle: page.resolvedStringsBundle)
                .font(.system(size: 28, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text(page.description, tableName: page.tableName, bundle: page.resolvedStringsBundle)
                .font(.system(size: 18))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white.opacity(0.70))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            if usesFooterAction {
                Spacer(minLength: 24)
                Color.clear
                    .frame(height: OnboardingSlideshowView.primaryRegionHeight)
            } else {
                Color.clear
                    .frame(height: OnboardingSlideshowView.walkthroughActionGap
                        + OnboardingSlideshowView.capsuleButtonHeight)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }
}

#endif

struct OnboardingPageIndicator: View {
    let totalPages: Int
    let currentIndex: Int
    /// Invoked with the tapped slide index when a dot is clicked.
    let onSelect: (Int) -> Void

    /// Visual gap between dots. It is baked into each dot's hit target rather
    /// than the HStack spacing, so the space between dots reads the same while
    /// the area immediately around each dot stays clickable.
    private static let gap: CGFloat = 7

    init(totalPages: Int, currentIndex: Int, onSelect: @escaping (Int) -> Void) {
        self.totalPages = totalPages
        self.currentIndex = currentIndex
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<totalPages, id: \.self) { index in
                let isCurrent = index == currentIndex
                let dotWidth: CGFloat = isCurrent ? 24 : 8
                Button {
                    onSelect(index)
                } label: {
                    Capsule(style: .continuous)
                        .fill(isCurrent ? Color.white.opacity(0.95) : Color.white.opacity(0.32))
                        .frame(width: dotWidth, height: 8)
                        // Grow the hit target around the small dot — the gap to
                        // its neighbour plus a comfortable vertical band — without
                        // changing how the dot itself looks.
                        .frame(width: dotWidth + Self.gap, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go to page \(index + 1)")
                .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
            }
        }
    }
}

// MARK: - Default onboarding content

/// The slides shown on first launch. Artwork is loaded from the app resource
/// bundle by `imageName`; the named images don't ship yet, so each slide
/// currently renders with an empty (dark) artwork area. To add screenshots,
/// drop 16:10 images into `apps/Donkey/Sources/Donkey/Resources/`, register
/// them as `.copy(...)` resources in `Package.swift`, and name them to match
/// the `imageName` values below.
enum OnboardingTour {
    /// The sign-in landing — the first slide when signed out. Its call-to-action
    /// is the injected Google sign-in footer plus an Explore link into the
    /// walkthrough, which ends on the closing slide's own Google button.
    static let signInPage = OnboardingPage(
        imageName: "onboarding-signin",
        imageBundle: DonkeyResourceBundle.app,
        title: "Sign in to Donkey",
        description: "Continue with Google to put Donkey to work on your Mac.",
        background: OnboardingSlideBackground(bloomCenter: UnitPoint(x: 0.50, y: 0.16), bloomIntensity: 0.95)
    )

    /// The walkthrough body — reached by Explore (signed out) or shown directly
    /// (signed-in replay), and followed by the closing slide in both flows.
    static let walkthroughPages: [OnboardingPage] = [
        OnboardingPage(
            imageName: "onboarding-welcome",
            imageBundle: DonkeyResourceBundle.app,
            title: "Meet Donkey",
            description: "The workhorse for your Mac. Tell it what you want done — then go do something else.",
            background: OnboardingSlideBackground(bloomCenter: UnitPoint(x: 0.26, y: 0.30), bloomIntensity: 0.30)
        ),
        OnboardingPage(
            imageName: "onboarding-ask",
            imageBundle: DonkeyResourceBundle.app,
            title: "Ask it for anything",
            description: "Fill out PDFs, create a website, clip a YouTube video. Command it and Donkey works out the rest.",
            background: OnboardingSlideBackground(bloomCenter: UnitPoint(x: 0.74, y: 0.18), bloomIntensity: 0.60)
        ),
        OnboardingPage(
            imageName: "onboarding-apps",
            imageBundle: DonkeyResourceBundle.app,
            title: "It works your apps for you",
            description: "Donkey clicks, types, and navigates across the apps you already use.",
            background: OnboardingSlideBackground(bloomCenter: UnitPoint(x: 0.50, y: 0.40), bloomIntensity: 0.50)
        ),
        OnboardingPage(
            imageName: "onboarding-parallel",
            imageBundle: DonkeyResourceBundle.app,
            title: "Hand it three jobs at once",
            description: "Donkey runs several conversations in parallel, so nothing waits in line. Kick off a task, start another, come back when they're done.",
            background: OnboardingSlideBackground(bloomCenter: UnitPoint(x: 0.80, y: 0.22), bloomIntensity: 0.80)
        )
    ]

    /// The closing slide that ends both flows. Signed out, it shows the injected
    /// Google button (sign in straight from the tour's end); signed in, it ends
    /// the replay with the Done button.
    static let readyPage = OnboardingPage(
        imageName: "onboarding-ready",
        imageBundle: DonkeyResourceBundle.app,
        title: "Donkey is ready to work",
        description: "",
        background: OnboardingSlideBackground(bloomCenter: UnitPoint(x: 0.46, y: 0.16), bloomIntensity: 1.00)
    )

    /// Signed out: the sign-in landing leads the walkthrough, which ends on the
    /// closing slide's Google button. Signed in: the walkthrough ends on the
    /// closing slide's Done button. The sign-in slide is always index 0 when
    /// present, which the slideshow relies on for the Explore flow.
    static func pages(isSignedIn: Bool) -> [OnboardingPage] {
        if isSignedIn {
            return walkthroughPages + [readyPage]
        } else {
            return [signInPage] + walkthroughPages + [readyPage]
        }
    }
}
