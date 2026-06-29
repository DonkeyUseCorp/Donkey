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
    /// slide falls back to the card's flat cream fill.
    let background: OnboardingSlideBackground?
    /// What fills the artwork region: a static image by default, or a live mock
    /// (the screen edge with the collapsed→expanded notch) on the slides that
    /// demo the app.
    let artwork: OnboardingArtwork

    init(
        id: UUID = UUID(),
        imageName: String,
        imageBundle: Bundle? = nil,
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        tableName: String? = nil,
        stringsBundle: Bundle? = nil,
        background: OnboardingSlideBackground? = nil,
        artwork: OnboardingArtwork = .image
    ) {
        self.id = id
        self.imageName = imageName
        self.imageBundle = imageBundle
        self.title = title
        self.description = description
        self.tableName = tableName
        self.stringsBundle = stringsBundle
        self.background = background
        self.artwork = artwork
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

/// The onboarding card mirrors the donkeyuse.com landing palette — a warm cream
/// surface, near-black ink for text and borders, and a coral primary action —
/// rather than a dark card with a blue glow. Values track `site`'s theme.ts.
enum OnboardingPalette {
    /// Page surface — landing `BG` #F5EFE0.
    static let cream = Color(red: 0.961, green: 0.937, blue: 0.878)
    /// A lighter cream for the top of the slide wash — landing cream #FAF6EC.
    static let creamLight = Color(red: 0.980, green: 0.965, blue: 0.925)
    /// Text, borders, shadows — landing `BLACK` #0F0E0D.
    static let ink = Color(red: 0.059, green: 0.055, blue: 0.051)
    /// Secondary body copy — landing body gray #454545.
    static let bodyGray = Color(red: 0.271, green: 0.271, blue: 0.271)
    /// Primary action — landing `CORAL` #EC7868.
    static let coral = Color(red: 0.925, green: 0.471, blue: 0.408)
}

/// A per-slide backdrop over the shared cream wash. Every slide shares the same
/// wash; only the spotlight distinguishes them — its position moves and its
/// intensity brightens and dims as the walkthrough advances.
struct OnboardingSlideBackground: Sendable {
    /// Where the spotlight bloom sits over the shared cream wash.
    var bloomCenter: UnitPoint
    /// Bloom strength, 0...1. Spread widely across slides so the brightness
    /// shift reads clearly from one slide to the next.
    var bloomIntensity: Double

    /// The colour the wash resolves to at the bottom edge — matched to the card
    /// fill so the gradient seams invisibly into the text panel below.
    static let baseFill = OnboardingPalette.cream
}

struct OnboardingSlideBackgroundView: View {
    let background: OnboardingSlideBackground

    /// The shared cream wash. Every slide uses these exact colours; only the
    /// spotlight (position + intensity) changes between slides.
    private static let washTop = OnboardingPalette.creamLight
    private static let washMiddle = OnboardingPalette.cream
    /// A soft coral spotlight — the landing accent, screened over the cream so a
    /// strong bloom warms the slide without reading as a glow.
    private static let bloomColor = OnboardingPalette.coral

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Self.washTop, location: 0.0),
                    .init(color: Self.washMiddle, location: 0.72),
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
                .background(OnboardingPalette.cream)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(OnboardingPalette.ink, lineWidth: 2)
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

            artworkLayer(for: pages[currentIndex])
                .frame(width: width, height: imageHeight)
                .id(currentIndex)
                .transition(.opacity)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: OnboardingPalette.cream.opacity(0.15), location: 0.25),
                    .init(color: OnboardingPalette.cream.opacity(0.45), location: 0.50),
                    .init(color: OnboardingPalette.cream.opacity(0.80), location: 0.75),
                    .init(color: OnboardingPalette.cream, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // Bottom-anchored, so a shorter height lowers where the fade begins — pulling the dark barrier
            // down while the solid bottom still seams into the panel. Sits independently of the dots below.
            .frame(height: 80)
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
                .tracking(-0.8)
                .multilineTextAlignment(.center)
                .foregroundStyle(OnboardingPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(currentPage.description, tableName: currentPage.tableName, bundle: currentPage.resolvedStringsBundle)
                .font(.system(size: 18))
                .multilineTextAlignment(.center)
                .foregroundStyle(OnboardingPalette.bodyGray)
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
                .foregroundStyle(OnboardingPalette.ink)
                .frame(width: 220, height: Self.capsuleButtonHeight)
                .background(Capsule(style: .continuous).fill(OnboardingPalette.coral))
                .overlay(Capsule(style: .continuous).strokeBorder(OnboardingPalette.ink, lineWidth: 2))
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
            .foregroundStyle(OnboardingPalette.bodyGray)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Icon button (glass circle)

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OnboardingPalette.ink)
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(Color.white)
                        .overlay { Circle().strokeBorder(OnboardingPalette.ink, lineWidth: 1.5) }
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

    /// The artwork region's content: the live notch mock on demo slides,
    /// otherwise the slide's static image.
    @ViewBuilder
    private func artworkLayer(for page: OnboardingPage) -> some View {
        switch page.artwork {
        case .image:
            image(for: page)
                .resizable()
                .scaledToFit()
        case .notchMock(let conversations):
            OnboardingNotchMock(conversations: conversations, mode: .loop)
        case .notchPanel(let conversations):
            OnboardingNotchMock(conversations: conversations, mode: .expandedPanel)
        case .notchComposer(let conversations):
            OnboardingNotchMock(conversations: conversations, mode: .openComposer)
        case .notchCompose(let conversations):
            OnboardingNotchMock(conversations: conversations, mode: .composeAndRun)
        case .inputMock(let commands):
            OnboardingInputMock(commands: commands)
        case .signInMock(let commands):
            OnboardingSignInMock(commands: commands)
        case .inputSummon(let commands):
            OnboardingInputMock(commands: commands, mode: .commandSummon)
        }
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
                .tracking(-0.8)
                .multilineTextAlignment(.center)
                .foregroundStyle(OnboardingPalette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(page.description, tableName: page.tableName, bundle: page.resolvedStringsBundle)
                .font(.system(size: 18))
                .multilineTextAlignment(.center)
                .foregroundStyle(OnboardingPalette.bodyGray)
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
                        .fill(isCurrent ? OnboardingPalette.ink.opacity(0.95) : OnboardingPalette.ink.opacity(0.28))
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

/// The slides shown on first launch. Each slide's artwork is a live mock (see
/// `OnboardingArtwork`): the sign-in and "ask" slides type out example commands
/// in the Donkey field, the others drop the notch out of the screen edge and run
/// a task. A slide left as `.image` instead loads `imageName` from the app
/// resource bundle — drop a 16:10 image into
/// `apps/Donkey/Sources/Donkey/Resources/` and register it in `Package.swift`.
enum OnboardingTour {
    /// Example commands the input-field mock types out, drawn from the eval
    /// fixtures — concrete, everyday tasks a user actually wants done.
    static let exampleCommands: [String] = [
        "give me a markdown of donkeyuse.com",
        "create a playlist with the top 10 songs from 2021",
        "turn on dark mode and enable Night Shift",
        "extract the table from q3-figures.pdf into a CSV",
        "split book.pdf into one file per chapter"
    ]

    /// The sign-in landing — the first slide when signed out. Its call-to-action
    /// is the injected Google sign-in footer plus an Explore link into the
    /// walkthrough, which ends on the closing slide's own Google button.
    static let signInPage = OnboardingPage(
        imageName: "onboarding-signin",
        imageBundle: DonkeyResourceBundle.app,
        title: "Sign in to Donkey",
        description: "Continue with Google to put Donkey to work on your Mac.",
        background: OnboardingSlideBackground(bloomCenter: UnitPoint(x: 0.50, y: 0.16), bloomIntensity: 0.95),
        artwork: .signInMock(exampleCommands)
    )

    /// The walkthrough body — reached by Explore (signed out) or shown directly
    /// (signed-in replay), and followed by the closing slide in both flows.
    static let walkthroughPages: [OnboardingPage] = [
        OnboardingPage(
            imageName: "onboarding-welcome",
            imageBundle: DonkeyResourceBundle.app,
            title: "Meet Donkey",
            description: "The workhorse for your Mac. Tell it what you want done — then go do something else.",
            background: OnboardingSlideBackground(bloomCenter: UnitPoint(x: 0.26, y: 0.30), bloomIntensity: 0.30),
            artwork: .notchCompose([
                OnboardingMockConversation(
                    id: "welcome-running",
                    accentIndex: 3,
                    prompt: "summarize report.pdf into a one-page brief and save it to my Desktop",
                    status: "Reading the PDF",
                    elapsedOffset: 0
                ),
                OnboardingMockConversation(
                    id: "welcome-idle",
                    accentIndex: 6,
                    prompt: "split book.pdf into one file per chapter",
                    status: "Done",
                    elapsedOffset: 0,
                    isRunning: false
                )
            ])
        ),
        OnboardingPage(
            imageName: "onboarding-ask",
            imageBundle: DonkeyResourceBundle.app,
            title: "Ask it for anything",
            description: "Fill out PDFs, create a website, clip a YouTube video. Command it and Donkey works out the rest.",
            background: OnboardingSlideBackground(bloomCenter: UnitPoint(x: 0.74, y: 0.18), bloomIntensity: 0.60),
            artwork: .inputSummon(Self.exampleCommands)
        ),
        OnboardingPage(
            imageName: "onboarding-parallel",
            imageBundle: DonkeyResourceBundle.app,
            title: "Hand it three jobs at once",
            description: "Donkey runs several conversations in parallel, so nothing waits in line. Kick off a task, start another, come back when they're done.",
            background: OnboardingSlideBackground(bloomCenter: UnitPoint(x: 0.80, y: 0.22), bloomIntensity: 0.80),
            artwork: .notchPanel([
                OnboardingMockConversation(
                    id: "parallel-1",
                    accentIndex: 0,
                    prompt: "fill out f1120.pdf using 1120data.txt",
                    status: "Filling the form fields",
                    elapsedOffset: 47
                ),
                OnboardingMockConversation(
                    id: "parallel-2",
                    accentIndex: 3,
                    prompt: "compare the pricing of the top 3 note-taking apps and write me a summary doc on my Desktop",
                    status: "Comparing the options",
                    elapsedOffset: 19
                ),
                OnboardingMockConversation(
                    id: "parallel-3",
                    accentIndex: 4,
                    prompt: "download the audio from https://www.youtube.com/watch?v=v8u_7PPEzZE as an mp3",
                    status: "Downloading the audio",
                    elapsedOffset: 6
                )
            ])
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
        background: OnboardingSlideBackground(bloomCenter: UnitPoint(x: 0.46, y: 0.16), bloomIntensity: 1.00),
        artwork: .notchComposer([
            OnboardingMockConversation(
                id: "ready-1",
                accentIndex: 6,
                prompt: "extract the audio from meeting.mov as an mp3 and give me a transcript with the action items pulled out",
                status: "Writing the transcript",
                elapsedOffset: 12
            )
        ])
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
