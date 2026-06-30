import AppKit
import DonkeyContracts
import DonkeyHarness
import Foundation
import WebKit

/// Native implementations for the Donkey Command Layer (`DonkeyCommandLayer`).
///
/// These run in-process using AppKit / the bundled AppleScript backend — no
/// screenshots, no Accessibility tree — so the model can act in well under
/// 500ms. The executor is injected into the harness as
/// `HarnessBuiltInToolServices.commandExecutor`.
public enum DonkeyCommandBackends {
    /// Build the closure wired into `HarnessBuiltInToolServices.commandExecutor`.
    /// Returns a result for a recognized command, or `nil` so harness dispatch
    /// falls through to its `unknownTool` handling.
    public static func makeExecutor() -> @Sendable (HarnessToolExecutionContext) async -> HarnessToolResult? {
        { context in await execute(context) }
    }

    @MainActor
    static func execute(_ context: HarnessToolExecutionContext) async -> HarnessToolResult? {
        guard let command = DonkeyCommandLayer.Command(rawValue: context.call.name) else {
            return nil
        }
        switch command {
        case .shellExec:
            return await shellExec(context)
        case .appsList:
            return listApps(context)
        case .appSkill:
            return appSkill(context)
        case .appCommands:
            return await appCommands(context)
        case .skillRun:
            return await runSkillScript(context)
        case .webSnapshot:
            return await webSnapshot(context)
        case .imageRender:
            return await imageRender(context)
        }
    }

    // MARK: - web_snapshot

    /// Render a URL in an offscreen `WKWebView` and save it as a PDF or full-page
    /// PNG. The free, in-app rung of the web-capture ladder: no external browser,
    /// no hosted service. It only reads the page and writes the output file, so it
    /// runs without consent (like `web.fetch`).
    @MainActor
    private static func webSnapshot(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let raw = trimmed(context.call.input["url"]),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return invalidInput(context, "web_snapshot requires a valid http(s) `url`.")
        }
        let format = (trimmed(context.call.input["format"]) ?? "pdf").lowercased()
        guard format == "pdf" || format == "png" else {
            return invalidInput(context, "web_snapshot `format` must be \"pdf\" or \"png\".")
        }
        let destination = snapshotDestination(
            trimmed(context.call.input["destination"]),
            url: url,
            format: format,
            baseDir: workspaceBaseDir(context)
        )

        // An offscreen window backs the web view so layout and rendering actually
        // run (an unattached WKWebView can snapshot blank). The view requests
        // reduced motion (see `captureWebViewConfiguration`) so pages render their
        // settled, fully-revealed state instead of a frozen mid-animation frame.
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 1600),
            configuration: captureWebViewConfiguration()
        )
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        let loader = WebSnapshotLoader()
        webView.navigationDelegate = loader

        let loaded = await loader.load(url, in: webView, timeout: 25)
        guard loaded else {
            return failed(context, "Could not load \(url.absoluteString).", reason: "webSnapshotLoadFailed")
        }
        // Scroll through the page to trigger viewport-gated content (lazy images,
        // reveal-on-scroll), then let layout/JS settle into the reduced-motion
        // final state before capturing.
        await prepareForCapture(webView)

        do {
            let data = try await (format == "pdf" ? exportPDF(webView) : exportPNG(webView))
            guard !data.isEmpty else {
                return failed(context, "web_snapshot produced an empty \(format).", reason: "webSnapshotEmpty")
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        } catch {
            return failed(
                context,
                "web_snapshot could not save the \(format): \(error.localizedDescription)",
                reason: "webSnapshotExportFailed"
            )
        }
        withExtendedLifetime(window) {}
        return success(
            context,
            summary: "Saved \(format.uppercased()) of \(url.absoluteString) → \(destination.path)",
            facts: ["webSnapshot.format": format],
            metadata: ["filePath": destination.path, "format": format]
        )
    }

    /// Resolve the output file URL for `web_snapshot`. Defaults the file name to `<host>.<ext>` and
    /// resolves through the shared workspace-aware rule (see `resolveOutputDestination`).
    private static func snapshotDestination(
        _ destination: String?,
        url: URL,
        format: String,
        baseDir: String?
    ) -> URL {
        let host = url.host?.replacingOccurrences(of: ".", with: "-") ?? "page"
        return resolveOutputDestination(destination, baseDir: baseDir, format: format, defaultName: host)
    }

    /// Configuration for the `web_snapshot` capture view. A document-start user
    /// script makes the page report `prefers-reduced-motion: reduce`, so sites that
    /// honor it (like our own landing page) skip entry animations and render their
    /// final, fully-revealed state. Without this, intro/reveal animations that start
    /// at `opacity: 0` are still hidden when a single static snapshot is taken, so
    /// whole sections capture blank.
    @MainActor
    private static func captureWebViewConfiguration() -> WKWebViewConfiguration {
        let source = """
        (function () {
          var real = window.matchMedia ? window.matchMedia.bind(window) : null;
          function reducedList(query) {
            return {
              matches: /prefers-reduced-motion\\s*:\\s*reduce/.test(query),
              media: query,
              onchange: null,
              addListener: function () {},
              removeListener: function () {},
              addEventListener: function () {},
              removeEventListener: function () {},
              dispatchEvent: function () { return false; }
            };
          }
          window.matchMedia = function (query) {
            if (typeof query === 'string' && query.indexOf('prefers-reduced-motion') !== -1) {
              return reducedList(query);
            }
            return real ? real(query) : reducedList(query);
          };
        })();
        """
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        return configuration
    }

    /// Walk the page top-to-bottom before capturing so viewport-gated content
    /// (lazy images, `IntersectionObserver` reveals) loads, then return to the top.
    /// The trailing sleep lets the scroll pass finish and animations settle into
    /// their reduced-motion final state.
    @MainActor
    private static func prepareForCapture(_ webView: WKWebView) async {
        let scrollSource = """
        (function () {
          var h = Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
          var step = Math.max(window.innerHeight, 600);
          var y = 0;
          var id = setInterval(function () {
            y += step;
            window.scrollTo(0, y);
            if (y >= h) { clearInterval(id); window.scrollTo(0, 0); }
          }, 50);
        })();
        """
        _ = try? await webView.evaluateJavaScript(scrollSource)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }

    @MainActor
    private static func exportPDF(_ webView: WKWebView) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: WKPDFConfiguration()) { result in
                continuation.resume(with: result)
            }
        }
    }

    @MainActor
    private static func exportPNG(_ webView: WKWebView) async throws -> Data {
        // Resize to the full scrollable height so the snapshot captures the whole page.
        if let height = try? await webView.evaluateJavaScript("document.body.scrollHeight") as? CGFloat,
           height > 0 {
            webView.frame.size.height = min(height, 20_000)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: webView.bounds.size)
        // Convert to PNG inside the completion handler so the non-Sendable NSImage never
        // crosses the continuation boundary.
        return try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                guard let image else {
                    continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown))
                    return
                }
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                    return
                }
                continuation.resume(returning: png)
            }
        }
    }

    // MARK: - image_render

    /// Render model-authored HTML/SVG markup into a PNG (or PDF) using the same offscreen
    /// `WKWebView` path as `web_snapshot`. This is the reliable way to CREATE an image of text
    /// or data — an infographic, diagram, chart, poster — because the markup is rendered exactly,
    /// so labels and numbers stay sharp (a generative image model would garble them). Like
    /// `web_snapshot` it only renders and writes a file, so it runs without consent. The output lands in
    /// the conversation workspace (or ~/Downloads when none is set yet); see `resolveOutputDestination`.
    @MainActor
    private static func imageRender(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        // `html` (inline markup) wins when both are supplied; the schema tells the model to omit it when
        // passing `htmlPath`. The htmlPath file is read from inside the workspace only (see resolveInputPath).
        var html: String = ""
        if let htmlInput = trimmed(context.call.input["html"]) {
            html = htmlInput
        } else if let htmlPathInput = trimmed(context.call.input["htmlPath"]) {
            let path = resolveInputPath(htmlPathInput, baseDir: workspaceBaseDir(context))
            do {
                html = try String(contentsOf: path, encoding: .utf8)
            } catch {
                return failed(context, "image_render could not read htmlPath '\(htmlPathInput)': \(error.localizedDescription)", reason: "imageRenderReadFailed")
            }
            guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return invalidInput(context, "image_render's htmlPath file '\(htmlPathInput)' is empty — it must contain the HTML/SVG markup to render.")
            }
        } else {
            return invalidInput(context, "image_render requires either `html` or `htmlPath` — the HTML/SVG markup or path to render.")
        }
        let format = (trimmed(context.call.input["format"]) ?? "png").lowercased()
        guard format == "png" || format == "pdf" else {
            return invalidInput(context, "image_render `format` must be \"png\" or \"pdf\".")
        }
        let width = dimension(context.call.input["width"], lower: 200, upper: 4000) ?? 1200
        let fixedHeight = dimension(context.call.input["height"], lower: 200, upper: 8000)
        let destination = renderDestination(
            trimmed(context.call.input["destination"]),
            format: format,
            baseDir: workspaceBaseDir(context)
        )

        // An offscreen window backs the web view so layout and rendering actually run.
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: fixedHeight ?? 800))
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        let loader = WebSnapshotLoader()
        webView.navigationDelegate = loader

        let loaded = await loader.loadHTML(html, in: webView, timeout: 20)
        guard loaded else {
            return failed(context, "image_render could not render the provided markup.", reason: "imageRenderLoadFailed")
        }
        // Give late layout (fonts, inline SVG) a brief beat to settle before capturing.
        try? await Task.sleep(nanoseconds: 500_000_000)

        do {
            let data = try await (format == "pdf"
                ? exportPDF(webView)
                : exportRenderedPNG(webView, width: width, fixedHeight: fixedHeight))
            guard !data.isEmpty else {
                return failed(context, "image_render produced an empty \(format).", reason: "imageRenderEmpty")
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        } catch {
            return failed(
                context,
                "image_render could not save the \(format): \(error.localizedDescription)",
                reason: "imageRenderExportFailed"
            )
        }
        withExtendedLifetime(window) {}
        return success(
            context,
            summary: "Rendered \(format.uppercased()) → \(destination.path)",
            facts: ["imageRender.format": format],
            metadata: ["filePath": destination.path, "format": format]
        )
    }

    /// Snapshot the rendered markup at the authored width. Height is the caller's fixed value when
    /// given, else the content's natural height (capped) — so an infographic renders at its designed
    /// size instead of a giant scrolling page.
    @MainActor
    private static func exportRenderedPNG(_ webView: WKWebView, width: CGFloat, fixedHeight: CGFloat?) async throws -> Data {
        let height: CGFloat
        if let fixedHeight {
            height = fixedHeight
        } else if let measured = try? await webView.evaluateJavaScript("document.body.scrollHeight") as? CGFloat,
                  measured > 0 {
            height = min(measured, 8000)
        } else {
            height = webView.bounds.size.height
        }
        webView.frame.size = CGSize(width: width, height: height)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: webView.bounds.size)
        // Convert to PNG inside the completion handler so the non-Sendable NSImage never
        // crosses the continuation boundary.
        return try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                guard let image else {
                    continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown))
                    return
                }
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                    return
                }
                continuation.resume(returning: png)
            }
        }
    }

    /// Resolve the output file for `image_render`. Defaults the file name to `image.<ext>` and resolves
    /// through the shared workspace-aware rule (see `resolveOutputDestination`).
    private static func renderDestination(_ destination: String?, format: String, baseDir: String?) -> URL {
        resolveOutputDestination(destination, baseDir: baseDir, format: format, defaultName: "image")
    }

    /// The conversation workspace's current directory, if the runtime has set one. Read from the typed
    /// fact the harness maintains — never from user text.
    private static func workspaceBaseDir(_ context: HarnessToolExecutionContext) -> String? {
        let value = context.worldModel.facts[ConversationWorkspace.baseDirFactKey]
        return (value?.isEmpty == false) ? value : nil
    }

    /// The folders Donkey created for this conversation — its workspace root and current base directory.
    /// Read from the typed workspace facts, never user text. These are the only places a file mutation runs
    /// WITHOUT a consent prompt; a write anywhere else is the user's to approve.
    private static func ownedRoots(_ context: HarnessToolExecutionContext) -> [String] {
        let facts = context.worldModel.facts
        let root = facts[ConversationWorkspace.rootDirFactKey].flatMap { $0.isEmpty ? nil : $0 }
        let base = facts[ConversationWorkspace.baseDirFactKey].flatMap { $0.isEmpty ? nil : $0 }
        var roots: [String] = []
        if let root { roots.append(root) }
        if let base, base != root { roots.append(base) }
        return roots
    }

    /// The seatbelt policy confining a shell spawn. Reads are open (the consent classifier already treats
    /// reads as free) and the network is open (API calls and downloads are common); writes are confined by
    /// the consent outcome. An UNPROMPTED command (a read, a bounded mutator whose operands all sit in an
    /// owned folder, or a jailed interpreter) is held to the owned folders. A command the user APPROVED at a
    /// prompt also gets their home directory writable, so the approved write lands — the kernel still blocks
    /// `/System`, `/usr`, and other users. `nil` when no folder is owned yet, so the spawn runs unconfined
    /// exactly as before the jail existed; the consent prompt is the gate there.
    private static func shellPolicy(owned: [String], consented: Bool) -> SandboxPolicy? {
        guard !owned.isEmpty else { return nil }
        let writable = consented ? owned + [FileManager.default.homeDirectoryForCurrentUser.path] : owned
        return SandboxPolicy(writableRoots: writable, readableRoots: [], allowNetwork: true, allowAllReads: true)
    }

    /// Resolve `image_render`'s `htmlPath` to a URL ALWAYS inside the workspace `baseDir` (or `~/Downloads`
    /// when none is set). image_render runs with no consent prompt and its `htmlPath` can be steered by
    /// content the model ingested, so — exactly like `resolveOutputDestination` on the output side — an
    /// absolute path, a `~` path, or a `..` climb is re-rooted under `base` rather than honored. Neither
    /// side of the tool can reach a file Donkey doesn't own.
    private static func resolveInputPath(_ rawPath: String, baseDir: String?) -> URL {
        let base: URL = {
            if let baseDir, !baseDir.isEmpty {
                return URL(fileURLWithPath: (baseDir as NSString).expandingTildeInPath, isDirectory: true)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
        }()
        let safeComponents = rawPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != ".." && $0 != "." }
        return safeComponents.reduce(base) { $0.appendingPathComponent(String($1)) }
    }

    /// Shared destination rule for the no-consent capture/render tools (`image_render`, `web_snapshot`).
    ///
    /// The result is ALWAYS inside `base` — the conversation workspace `baseDir` when one exists, else
    /// `~/Downloads`. These tools run with no permission prompt and their `destination` can be steered by
    /// content they capture (an injected page or document), so the path must never escape a user directory.
    /// Subfolders survive (`assets/chart.png`), but `..` traversal and absolute paths are re-rooted under
    /// `base` rather than honored — escape is impossible by construction. A nil/empty `destination`
    /// becomes `<base>/<defaultName>.<format>`.
    static func resolveOutputDestination(
        _ destination: String?,
        baseDir: String?,
        format: String,
        defaultName: String
    ) -> URL {
        let base: URL = {
            if let baseDir, !baseDir.isEmpty {
                return URL(fileURLWithPath: (baseDir as NSString).expandingTildeInPath, isDirectory: true)
            }
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
        }()
        func ensuringExtension(_ url: URL) -> URL {
            url.pathExtension.isEmpty ? url.appendingPathExtension(format) : url
        }
        // Keep only the non-traversal path components and re-root them under `base`, so no destination —
        // relative, absolute, or `..`-laden — can resolve outside `base`.
        let safeComponents = (destination ?? "")
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != ".." && $0 != "." }
        guard !safeComponents.isEmpty else {
            return base.appendingPathComponent("\(defaultName).\(format)")
        }
        let confined = safeComponents.reduce(base) { $0.appendingPathComponent(String($1)) }
        return ensuringExtension(confined)
    }

    /// Parse a pixel dimension from a string input, clamped to `[lower, upper]`; `nil` when absent or
    /// not a number.
    private static func dimension(_ value: String?, lower: CGFloat, upper: CGFloat) -> CGFloat? {
        guard let value = trimmed(value), let number = Double(value) else { return nil }
        return Swift.min(Swift.max(CGFloat(number), lower), upper)
    }

    // MARK: - app_commands

    /// Surface the app's REAL AppleScript vocabulary from its parsed scripting dictionary, so the
    /// model writes scripts against declared terminology instead of guessing it. Non-scriptable
    /// apps answer deterministically with the accessibility/vision redirection.
    private static func appCommands(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let app = trimmed(context.call.input["app"]) else {
            return invalidInput(context, "app_commands requires an `app` display name or bundle identifier.")
        }
        let service = AppScriptingDictionaryService.shared
        let lookup = await service.lookup(appName: app, bundleIdentifier: app)

        guard lookup.scriptability != .notScriptable else {
            return success(
                context,
                summary: "\(app) is not AppleScript-scriptable. Do not generate AppleScript for it; drive it with accessibility/vision tools instead.",
                facts: ["appCommands.\(app)": "notScriptable"],
                metadata: ["scriptable": "false", "app": app]
            )
        }
        guard let dictionary = lookup.dictionary else {
            let scriptable = lookup.scriptability == .scriptable ? "true" : "unknown"
            return success(
                context,
                summary: "No scripting dictionary could be read for \(app). Prefer accessibility/vision tools, or shell_exec for system-level actions.",
                facts: ["appCommands.\(app)": "noDictionary"],
                metadata: ["scriptable": scriptable, "app": app]
            )
        }

        let suiteNames = dictionary.suites.map(\.name).joined(separator: ", ")
        if let suiteName = trimmed(context.call.input["suite"]) {
            guard let suiteDigest = await service.suiteDigest(
                appName: app, bundleIdentifier: app, suiteName: suiteName
            ) else {
                return failed(
                    context,
                    "\(app) has no suite named \"\(suiteName)\". Available suites: \(suiteNames).",
                    reason: "suiteNotFound"
                )
            }
            return success(
                context,
                summary: suiteDigest,
                facts: ["appCommands.\(app)": "loaded"],
                metadata: ["scriptable": "true", "app": app, "digest": suiteDigest, "suites": suiteNames]
            )
        }

        return success(
            context,
            summary: lookup.digest,
            facts: ["appCommands.\(app)": "loaded"],
            metadata: ["scriptable": "true", "app": app, "digest": lookup.digest, "suites": suiteNames]
        )
    }

    // MARK: - app_skill

    /// Surface the installed operating playbook for an app, discovered from the
    /// skill packs by display name or bundle id — never from a hardcoded app
    /// list. Apps without a skill report that plainly so the model falls back to
    /// its general tools.
    private static func appSkill(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        guard let app = trimmed(context.call.input["app"]) else {
            return invalidInput(context, "app_skill requires an `app` display name or bundle identifier.")
        }
        // On-demand reads return the FULL playbook: app_skill is the model deliberately loading the
        // guide, unlike the per-step ambient guidance which stays at the default 4k prompt budget.
        guard let descriptor = BuiltInLocalAppSkillPacks.appSkillDescriptor(forApp: app, bundleIdentifier: app),
              let guidance = BuiltInLocalAppSkillPacks.appOperatingGuidance(
                  forApp: app,
                  bundleIdentifier: app,
                  maxCharacters: 12_000
              )
        else {
            return success(
                context,
                summary: "No operating skill is installed for \(app).",
                facts: ["appSkill.\(app)": "notFound"],
                metadata: ["found": "false", "app": app]
            )
        }
        // Advertise the skill's validated scripts so the model can execute a
        // covered workflow directly with skill_run instead of reinventing it.
        let scriptLines = descriptor.scripts.map { script in
            "- skillID=\(descriptor.id) scriptID=\(script.id)\(script.purpose.isEmpty ? "" : " — \(script.purpose)")"
        }
        let scriptsBlock = scriptLines.isEmpty
            ? ""
            : "\n\nValidated scripts (execute with skill_run):\n" + scriptLines.joined(separator: "\n")
        return success(
            context,
            summary: guidance + scriptsBlock,
            facts: ["appSkill.\(app)": "loaded"],
            metadata: [
                "found": "true",
                "app": app,
                "skillID": descriptor.id,
                "scriptIDs": descriptor.scripts.map(\.id).joined(separator: ","),
                "guidance": guidance
            ]
        )
    }

    // MARK: - apps_list

    /// Default and ceiling for the installed-list page size. The installed
    /// catalog can run to ~100+ entries, which overflowed the response cap and
    /// silently dropped the tail; pagination lets the model page deterministically.
    private static let appsDefaultPageSize = 50
    private static let appsMaxPageSize = 200
    /// Char budget for the joined installed names. The page is built to fit this so
    /// the reported `returned`/`hasMore`/`nextOffset` describe exactly the names
    /// emitted — a later truncation can never silently drop names the model was told
    /// it received and would page past.
    private static let appsResponseCharBudget = 3_000
    /// The Spotlight-backed catalog scan (mdfind subprocess + per-app Info.plist
    /// reads) is expensive and barely changes within a session, so reuse it across
    /// paginated calls instead of re-enumerating on every page.
    private static let installedCatalogTTLSeconds: TimeInterval = 60
    @MainActor private static var installedCatalogCache: (expires: Date, apps: [LocalApplicationCatalogCandidate])?

    @MainActor
    private static func cachedInstalledApplications() -> [LocalApplicationCatalogCandidate] {
        let now = Date()
        if let cache = installedCatalogCache, cache.expires > now { return cache.apps }
        let apps = MacLocalAppAvailabilityProvider.installedApplications()
        installedCatalogCache = (now.addingTimeInterval(installedCatalogTTLSeconds), apps)
        return apps
    }

    @MainActor
    private static func listApps(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        let filter = trimmed(context.call.input["filter"])?.lowercased()

        func passesFilter(_ value: String) -> Bool {
            guard let filter else { return true }
            return value.lowercased().contains(filter)
        }

        // Pagination inputs apply to the installed list only (the large one);
        // running apps are few and always returned in full.
        var offset = 0
        if let rawOffset = trimmed(context.call.input["offset"]) {
            guard let parsed = Int(rawOffset), parsed >= 0 else {
                return invalidInput(context, "`offset` must be a non-negative integer (zero-based index into the installed list).")
            }
            offset = parsed
        }

        var limit = appsDefaultPageSize
        if let rawLimit = trimmed(context.call.input["limit"]) {
            guard let parsed = Int(rawLimit), parsed >= 1 else {
                return invalidInput(context, "`limit` must be a positive integer (max \(appsMaxPageSize)).")
            }
            limit = min(parsed, appsMaxPageSize)
        }

        // Reuse the shared Spotlight-backed catalog (names + bundle ids, all the
        // standard search roots — including /System/Applications, so Apple native
        // apps are present) instead of a duplicated directory scan.
        let installedAll = cachedInstalledApplications()
            .filter { passesFilter($0.appName) || ($0.bundleIdentifier.map(passesFilter) ?? false) }
            .map { candidate -> String in
                guard let bundleID = candidate.bundleIdentifier, !bundleID.isEmpty else { return candidate.appName }
                return "\(candidate.appName) (\(bundleID))"
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let installedTotal = installedAll.count
        let pageStart = min(offset, installedTotal)
        // Build the page so what we COUNT is exactly what we EMIT: take up to `limit`
        // names from `pageStart`, but stop early if the joined text would exceed the
        // response budget. `nextOffset`/`hasMore` then describe the real emitted page,
        // not an over-counted slice the response cap would have silently truncated.
        let (installedPage, installedText) = pagedNames(
            installedAll, start: pageStart, maxCount: limit, charBudget: appsResponseCharBudget
        )
        let pageEnd = pageStart + installedPage.count
        let hasMore = pageEnd < installedTotal
        let nextOffset = hasMore ? pageEnd : nil

        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .filter(passesFilter)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        // Self-describing page header so the model can chain pages from the
        // result text alone, without re-deriving the input schema.
        let rangeText = installedTotal == 0
            ? "Installed (0)"
            : "Installed \(pageStart + 1)–\(pageEnd) of \(installedTotal)"
        let moreText = nextOffset.map { " — more available, call apps_list again with offset=\($0) (same filter) for the next page" } ?? ""

        var metadata: [String: String] = [
            "installed": installedText,
            "running": capped(running),
            "installedTotal": String(installedTotal),
            "offset": String(pageStart),
            "limit": String(limit),
            "returned": String(installedPage.count),
            "hasMore": hasMore ? "true" : "false"
        ]
        if let nextOffset { metadata["nextOffset"] = String(nextOffset) }
        if let filter = trimmed(context.call.input["filter"]) { metadata["filter"] = filter }

        return success(
            context,
            summary: "\(rangeText)\(moreText): \(installedText)\nRunning (\(running.count)): \(capped(running))",
            facts: [
                "installedAppCount": String(installedTotal),
                "installedReturnedCount": String(installedPage.count)
            ],
            metadata: metadata
        )
    }

    /// Take up to `maxCount` names starting at `start`, stopping early if the joined
    /// text would exceed `charBudget`, and return the names actually taken alongside
    /// their joined string. The returned count is authoritative: callers derive
    /// `returned`/`hasMore`/`nextOffset` from it so the page header can't claim more
    /// than was emitted. At least one name is always taken (so paging makes progress
    /// even if a single name exceeds the budget).
    private static func pagedNames(
        _ names: [String],
        start: Int,
        maxCount: Int,
        charBudget: Int
    ) -> (page: [String], joined: String) {
        var page: [String] = []
        var joinedLength = 0
        var index = start
        while index < names.count, page.count < maxCount {
            let name = names[index]
            let separatorLength = page.isEmpty ? 0 : 2  // ", "
            let projected = joinedLength + separatorLength + name.count
            if !page.isEmpty, projected > charBudget { break }
            page.append(name)
            joinedLength = projected
            index += 1
        }
        return (page, page.joined(separator: ", "))
    }

    /// Join names, capped so the model response stays bounded.
    private static func capped(_ names: [String], limit: Int = 3_000) -> String {
        var result = ""
        for name in names {
            let next = result.isEmpty ? name : "\(result), \(name)"
            if next.count > limit {
                return result.isEmpty ? String(name.prefix(limit)) : "\(result), …"
            }
            result = next
        }
        return result
    }

    // MARK: - skill_run

    /// Execute a validated script an installed skill ships, looked up by the
    /// skill/script ids the model got from `app_skill` — the generic native
    /// fast path for any skill-covered workflow, with nothing domain-specific.
    private static func runSkillScript(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let skillID = trimmed(context.call.input["skillID"]) else {
            return invalidInput(context, "skill_run requires the `skillID` advertised by app_skill.")
        }
        guard let scriptID = trimmed(context.call.input["scriptID"]) else {
            return invalidInput(context, "skill_run requires the `scriptID` advertised by app_skill.")
        }
        guard let artifact = LocalAppUserQueryHarnessServices
            .builtInValidatedScriptArtifacts()
            .first(where: { $0.id == scriptID && $0.ownerSkillID == skillID }) else {
            return failed(
                context,
                "No validated script \(scriptID) is installed for skill \(skillID). Look the app's skill up with app_skill for the available scripts.",
                reason: "skillScriptUnavailable"
            )
        }
        let outcome = await LocalAppUserQueryHarnessServices.executeSkillScript(artifact: artifact, context: context)
        if outcome.metadata["clarification.required"] == "true" {
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .waitingForUser,
                summary: "The script needs clarification before it can proceed.",
                question: outcome.metadata["clarification.question"] ?? "What exactly should I use?",
                metadata: outcome.metadata.merging(["gate": "clarification"]) { current, _ in current }
            )
        }
        guard outcome.succeeded else {
            // Preserve the script's full output metadata on failure — it may carry an
            // `escalate.app`/`escalate.goal` signal that the runtime's structural feedback loop acts
            // on (hand the unfinished task to the vision agent) instead of dead-ending.
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .failed,
                summary: outcome.summary,
                metadata: outcome.metadata.merging([
                    "reason": outcome.metadata["failureReason"] ?? "skillScriptFailed"
                ]) { current, _ in current }
            )
        }
        // Surface the script's OWN structured status block (e.g. `status=played\nplayedTitle=…\n
        // playedArtist=…`) as the summary, not a generic "executed successfully". The script already
        // verified its effect and reported it; showing that to the planner is the evidence it needs to
        // run.complete directly, instead of reaching for a second tool to re-verify (which is where the
        // run was looping). Falls back to the generic summary when the script reports nothing.
        let status = outcome.output
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        return success(
            context,
            summary: status.isEmpty ? outcome.summary : status,
            facts: ["skillRun.\(scriptID)": outcome.metadata["status"] ?? "succeeded"],
            metadata: outcome.metadata
        )
    }

    // MARK: - shell_exec

    /// Max characters accepted for a one-line command. Sized for real `osascript` one-liners: a
    /// macOS temp path (e.g. an `llm.generate` file under `/var/folders/.../T/`) is ~100 chars on its
    /// own, and a multi-`-e` AppleScript that reads such a file into Notes/Mail/Calendar runs to
    /// ~450+ chars before any content. A tighter cap silently rejected those legitimate commands; the
    /// bound stays only as a backstop against pathological inline payloads.
    private static let shellCommandMaxLength = 1_500
    /// Seconds before a command is terminated when the call does not set its own budget.
    private static let shellTimeout: TimeInterval = 12
    /// Upper bound for a caller-provided `timeoutSeconds`, so a planner mistake can never hang a run.
    private static let shellTimeoutMax: TimeInterval = 120
    /// Max stdout characters returned to the model.
    private static let shellOutputMaxLength = 4_000
    /// Max characters of a FAILED command's output surfaced for diagnosis. Generous because this is the
    /// one thing the planner needs to recover, and the actual error is usually only a few lines.
    private static let shellFailureDiagnosticMaxLength = 1_000

    /// Truncates output to the model-facing cap, announcing the cut instead of trimming silently —
    /// the model must know it saw a prefix, not the whole output.
    private static func boundedOutput(_ output: String) -> (text: String, truncated: Bool) {
        guard output.count > shellOutputMaxLength else { return (output, false) }
        // This IS partial data — the command produced more than the capture cap, so the tail is gone from
        // this result. Unlike a prompt-side context trim, re-running won't help; the fix is to redirect the
        // command's output to a file and read it in pieces. Say so, so the planner reaches for the file
        // instead of re-running or bumping the timeout.
        return (
            String(output.prefix(shellOutputMaxLength))
                + "\n… [output truncated at \(shellOutputMaxLength) chars; the command produced more — "
                + "re-run it redirected to a file (`cmd > out.txt`) and read that, don't re-run as-is]",
            true
        )
    }

    /// The diagnostic TAIL of a failed command's output. A tool prints its banner/help first and the
    /// real error LAST — ffmpeg's version-and-config block precedes its `No such filter` / filtergraph
    /// error, a compiler's summary follows its warnings, a downloader's failure line is the final one.
    /// Keeping the HEAD (the old behavior) fed the planner the version banner and hid the error, so it
    /// retried the same broken command blind. Keeping the tail surfaces the line that explains why.
    private static func diagnosticTail(_ output: String) -> String {
        guard output.count > shellFailureDiagnosticMaxLength else { return output }
        return "… [earlier output truncated]\n" + String(output.suffix(shellFailureDiagnosticMaxLength))
    }

    private static func shellExec(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let command = trimmed(context.call.input["command"]) ?? trimmed(context.call.input["cmd"]) else {
            return invalidInput(context, "shell_exec requires a `command`.")
        }
        guard command.count <= shellCommandMaxLength else {
            return invalidInput(
                context,
                "shell_exec command is \(command.count) chars; the limit is \(shellCommandMaxLength). "
                    + "Don't inline large content into a command — write it straight to a file with "
                    + "files.write (path + content), then run a short command that reads from that file."
            )
        }

        // Run from the conversation's working directory when one exists, so relative reads/writes land in
        // the agent's own folder instead of the home root; falls back to home for a run without a workspace.
        let workingDirectory = workspaceBaseDir(context)
        let owned = ownedRoots(context)

        // Decide consent. A command runs UNPROMPTED when it is a read; a bounded file mutator whose every
        // operand sits inside a folder Donkey created; or a scripting interpreter the kernel jail can
        // contain — managing its own folder is not the user's to approve. Anything else (a mutation
        // reaching a user file, a network tool, a side-effecting app driver) prompts first; nothing is
        // silently refused.
        let classification = ShellCommandClassifier.classify(command)
        let resolvedWorkdir = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        // An interpreter (python3/ruby/…) reshaping files in Donkey's own folder runs unprompted, the same
        // as a bounded mutator — because the kernel jail keeps its WRITES in those folders. Reads and the
        // network stay open like every spawn, so a script that inspects a file or calls an API still works;
        // a write aimed at a user file is stopped by the kernel rather than a prompt.
        let unprompted = classification.tier == .read
            || ShellCommandClassifier.isWorkspaceConfinedInterpreterRun(
                command, ownedRoots: owned, workingDirectory: resolvedWorkdir
            )
            || ShellCommandClassifier.everySegmentMutatesOnlyOwnedRoots(
                command, ownedRoots: owned, workingDirectory: resolvedWorkdir
            )
        if !unprompted {
            if let gate = await consentGate(context, command: command, classification: classification) {
                return gate
            }
        }

        let timeout = context.call.input["timeoutSeconds"].flatMap(Double.init)
            .map { min(max($0, 1), shellTimeoutMax) } ?? shellTimeout
        // Confine the spawn (kernel-enforced): reads open, network open, writes held to the owned folders —
        // plus the user's home when they approved this command at a prompt, so the approved write lands.
        // nil → no folder yet.
        let policy = shellPolicy(owned: owned, consented: !unprompted)
        let result = await Task.detached(priority: .userInitiated) {
            runShellSync(command, timeout: timeout, workingDirectory: workingDirectory, policy: policy)
        }.value

        let stdout = boundedOutput(result.stdout)
        guard result.exitCode == 0 else {
            // The summary is what the model reads next step; a bare exit code hides WHY the command
            // failed and leaves the planner guessing, so carry the error text in it. Surface the TAIL,
            // not the head: the diagnostic line lives at the END of a tool's output (ffmpeg's banner
            // precedes its real error), and feeding the head made the planner loop on an invisible
            // failure (e.g. retrying the same `subtitles=` filter without seeing `No such filter`).
            let stderrTail = diagnosticTail(result.stderr)
            let stdoutTail = diagnosticTail(result.stdout)
            // A timeout that already produced a lot of stdout is an OUTPUT-VOLUME problem, not a
            // needs-more-time problem: the command was streaming faster than it could be drained, so a
            // bigger timeout just buys a bigger truncated dump. Steer to a file redirect instead of a
            // higher timeout. A timeout with little/no output is genuinely slow — there, bumping helps.
            let timedOutOnVolume = result.timedOut && result.stdout.count >= shellOutputMaxLength
            let firstLine: String
            if timedOutOnVolume {
                firstLine = "Command timed out after \(Int(timeout))s while producing a large, streaming "
                    + "output — this is a volume problem, not a speed one. Do NOT just raise timeoutSeconds; "
                    + "re-run it redirected to a file (`cmd > out.txt`) and read that file in pieces."
            } else if result.timedOut {
                firstLine = "Command timed out after \(Int(timeout))s and was terminated. Pass "
                    + "timeoutSeconds (max \(Int(shellTimeoutMax))) for known-slow commands."
            } else {
                firstLine = "Command exited with code \(result.exitCode)."
            }
            var failureLines = [firstLine]
            if !stderrTail.isEmpty {
                failureLines.append("stderr: " + stderrTail)
            } else if !stdoutTail.isEmpty {
                failureLines.append("stdout: " + stdoutTail)
            }
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .failed,
                summary: failureLines.joined(separator: "\n"),
                metadata: [
                    "executor": "donkeyCommandLayer",
                    "reason": result.timedOut ? "timedOut" : "nonZeroExit",
                    "exitCode": String(result.exitCode),
                    "stdout": stdoutTail,
                    "stderr": stderrTail,
                    "timeoutSeconds": String(Int(timeout))
                ]
            )
        }
        var metadata = ["stdout": stdout.text, "exitCode": "0", "stdoutTruncated": String(stdout.truncated)]
        // Stamp whether this command READ or changed state, so the runtime can tell a scouting step (a
        // listing, a page dump to read) from a real action (`open -a Music`, `osascript`, a write) even
        // though both ride the one `shell_exec` tool. A read must not count as the run's produced result.
        metadata["shell.effect"] = classification.tier == .read ? "read" : "write"
        // Surface an explicit output file (`-o`/`--out`/`--output <path>`) the command just wrote, so the
        // workspace records it as a real DELIVERABLE. The `-o` flag is the intentional-output signal that a
        // `>`-redirect (scratch: a field dump, a page view to read) is not — that distinction is what lets the
        // runtime tell "produced the result" from "only scouted" and refuse to call a scout-only run done.
        if let output = explicitOutputFile(command: command, workingDirectory: workingDirectory) {
            metadata["filePath"] = output
        }
        return success(
            context,
            summary: stdout.text.isEmpty ? "Command ran (no output)." : stdout.text,
            facts: ["lastShellExitCode": "0"],
            metadata: metadata
        )
    }

    /// The absolute path of a file a command wrote via an explicit output flag (`-o`/`--out`/`--output`),
    /// when that file now exists. Mechanical flag parsing on technical tokens — NOT natural-language intent
    /// matching: it reads the value after (or attached to) a known flag, resolves it against the working
    /// directory, and confirms the file is on disk. Returns nil when there is no such flag or the file isn't
    /// there, so a scratch `>`-redirect (no `-o`) never registers as a deliverable.
    ///
    /// Robust to the forms a real command takes: a quoted/spaced path (`-o 'tax return.pdf'`) is one token,
    /// the equals-attached forms (`-o=out.pdf`, `--output=out.pdf`) are split on `=`, and tools where `-o`
    /// is NOT an output path (grep's only-matching, ssh's `-o Option=val`) are excluded so a non-output `-o`
    /// whose neighbor happens to name an existing file is not mis-recorded as a deliverable.
    static func explicitOutputFile(command: String, workingDirectory: String?) -> String? {
        let tokens = ShellCommandClassifier.argvTokens(command)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\\\"'")) }
        guard let first = tokens.first else { return nil }
        // Don't read `-o` as an output path for tools that overload it for something else.
        if outputFlagIsNotAFile.contains(ShellCommandClassifier.executableName(first)) { return nil }
        let flags: Set<String> = ["-o", "--out", "--output", "-output"]
        var value: String?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if let equals = token.firstIndex(of: "="), flags.contains(String(token[..<equals])) {
                value = String(token[token.index(after: equals)...])
                break
            }
            if flags.contains(token), index + 1 < tokens.count {
                value = tokens[index + 1]
                break
            }
            index += 1
        }
        guard let path = value, !path.isEmpty, !path.hasPrefix("-") else { return nil }
        let resolved: String
        if (path as NSString).isAbsolutePath {
            resolved = path
        } else if path.hasPrefix("~") {
            resolved = (path as NSString).expandingTildeInPath
        } else {
            let base = workingDirectory.flatMap { $0.isEmpty ? nil : $0 }
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            resolved = (base as NSString).appendingPathComponent(path)
        }
        return FileManager.default.fileExists(atPath: resolved) ? resolved : nil
    }

    /// Executables that overload `-o`/`-output` for something other than an output file, so the token after
    /// it is not a produced deliverable: grep family (`-o` = only-matching, takes no value), ssh/scp/sftp
    /// (`-o Key=Value` config), and sort (`-o` writes in place over an existing file, not a fresh result).
    private static let outputFlagIsNotAFile: Set<String> = [
        "grep", "egrep", "fgrep", "rg", "ssh", "scp", "sftp", "sort"
    ]

    /// Returns nil when the command is already allowed (run it), or a
    /// `waitingForPermission` gate result the runtime turns into an allow-once /
    /// always-allow prompt. `highRisk` commands can only be allowed once.
    private static func consentGate(
        _ context: HarnessToolExecutionContext,
        command: String,
        classification: ShellCommandClassification
    ) async -> HarnessToolResult? {
        let store = ShellPermissionPolicyStore.shared
        let signature = classification.signature

        var allowed = false
        if classification.tier != .highRisk {
            allowed = await store.isAlwaysAllowed(signature)
        }
        if !allowed {
            allowed = await store.consumeOnce(agentID: context.agentID, signature: signature)
        }
        if allowed { return nil }

        let allowAlways = classification.tier != .highRisk
        let reason = classification.reason.map { " (\($0))" } ?? ""
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .waitingForPermission,
            summary: "Needs your approval to run `\(command)`\(reason).",
            metadata: [
                "executor": "donkeyCommandLayer",
                "gate": "shellConsent",
                "shell.command": command,
                "shell.signature": signature,
                "shell.tier": classification.tier.rawValue,
                "shell.reason": classification.reason ?? "",
                "shell.allowAlways": allowAlways ? "true" : "false"
            ]
        )
    }

    private struct ShellResult: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    /// The directory a bundled tool or shell command should run in: the conversation's own working
    /// directory when it exists, else the user's home. Never the GUI app's inherited cwd (`/`), where a
    /// relative `find .` walks the whole disk, stalls on SIP-protected dirs, and times out. Shared by
    /// `runShellSync`, `runBundledTool`, and the media/form orchestrators so the rule lives in one place.
    public static func resolvedWorkingDirectory(_ workingDirectory: String?) -> URL {
        let fileManager = FileManager.default
        if let workingDirectory, !workingDirectory.isEmpty, fileManager.fileExists(atPath: workingDirectory) {
            return URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    /// String form of `resolvedWorkingDirectory`, for callers that thread the working directory as a path.
    public static func resolvedWorkingDirectoryPath(_ workingDirectory: String?) -> String {
        resolvedWorkingDirectory(workingDirectory).path
    }

    private struct ProcessOutput: Sendable {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
    }

    /// Run an already-configured process to completion, bounded by `timeout`, draining stdout and stderr
    /// CONCURRENTLY on their own queues. The concurrent drain is the safety property: a tool that writes
    /// more than the ~64KB pipe buffer to either stream (a verbose `lit` OCR dump, a Rust panic with a full
    /// backtrace on stderr) keeps flowing instead of blocking on a full pipe while the parent waits on the
    /// other stream — the two-pipe deadlock. SIGTERM on timeout, SIGKILL if it ignores that, so the bound is
    /// real. Blocking; callers run it off the main actor.
    private static func runProcess(_ process: Process, timeout: TimeInterval) -> ProcessOutput {
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Signalled by the OS when the process actually exits.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return ProcessOutput(exitCode: 127, stdout: Data(), stderr: Data(error.localizedDescription.utf8), timedOut: false)
        }

        // Drain both streams in parallel so neither can fill its pipe and block the child before it exits.
        // Each reader stores into a locked box; the DispatchGroup join below is the happens-before barrier.
        let outBox = DataBox()
        let errBox = DataBox()
        let readers = DispatchGroup()
        let outQueue = DispatchQueue(label: "donkey.process.stdout")
        let errQueue = DispatchQueue(label: "donkey.process.stderr")
        readers.enter()
        outQueue.async { outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile()); readers.leave() }
        readers.enter()
        errQueue.async { errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile()); readers.leave() }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate() // SIGTERM
            if finished.wait(timeout: .now() + 1.0) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        // The process has exited (or been killed), so the pipe write ends close, the readers hit EOF and
        // return, and this join completes promptly.
        readers.wait()
        return ProcessOutput(exitCode: process.terminationStatus, stdout: outBox.get(), stderr: errBox.get(), timedOut: timedOut)
    }

    /// A lock-guarded `Data` cell so the two stream-reader queues in `runProcess` can hand their result back
    /// without the compiler flagging a captured-var data race; the `DispatchGroup` join is what orders the
    /// write before the read.
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// Run a one-line command via `/bin/zsh -c`, bounded by `timeout`. Blocking;
    /// always called off the main actor via `Task.detached`.
    private static func runShellSync(
        _ command: String,
        timeout: TimeInterval,
        workingDirectory: String? = nil,
        policy: SandboxPolicy? = nil
    ) -> ShellResult {
        let process = Process()
        // Under a policy, the command runs inside the seatbelt jail (writes confined to the owned folder,
        // plus home when consent approved it; reads open) with TMPDIR corralled into the folder. A nil
        // policy is a passthrough, so a run without an owned folder behaves exactly as before.
        let environment = WorkspaceSandbox.childEnvironment(shellEnvironment(), policy: policy)
        let (executable, arguments) = WorkspaceSandbox.wrap(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", command],
            policy: policy,
            environment: environment,
            bundledToolsDir: bundledToolsDirectory?.path
        )
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = resolvedWorkingDirectory(workingDirectory)
        let output = runProcess(process, timeout: timeout)
        return ShellResult(
            exitCode: output.exitCode,
            stdout: String(data: output.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: output.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            timedOut: output.timedOut
        )
    }

    /// Run a bundled command-line tool (`pdf-fill`, `lit`, …) DIRECTLY by resolving its path in the
    /// bundled-tools dir, bypassing the shell so arguments with spaces or `⟦…⟧` need no quoting. The
    /// bundled binary is REQUIRED: when it can't be resolved this returns exit 127 with a descriptive
    /// stderr — never a same-named binary off the user's PATH, which would be the wrong build with no
    /// pdfium and is worse than a clean failure. Uses `shellEnvironment()` so PDFIUM_LIB_PATH and the
    /// bundled PATH are set, and runs in `workingDirectory` (else home). Blocking — callers run it off the
    /// main actor. Used by the form/PDF/media orchestrators so a pipeline drives its tool without going
    /// through the model-facing `shell_exec` gate.
    public static func runBundledTool(
        _ name: String,
        _ arguments: [String],
        workingDirectory: String?,
        policy: SandboxPolicy? = nil
    ) -> (exitCode: Int32, stdout: String, stderr: String) {
        guard let directory = bundledToolsDirectory else {
            return (127, "", "Bundled tools directory is unavailable, so '\(name)' cannot run.")
        }
        let binary = directory.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            return (127, "", "Bundled tool '\(name)' is missing from \(directory.path).")
        }
        let process = Process()
        // Same seatbelt jail as `runShellSync` when a policy is supplied (orchestrators thread one in);
        // a nil policy is a passthrough.
        let environment = WorkspaceSandbox.childEnvironment(shellEnvironment(), policy: policy)
        let (executable, wrappedArguments) = WorkspaceSandbox.wrap(
            executable: binary,
            arguments: arguments,
            policy: policy,
            environment: environment,
            bundledToolsDir: directory.path
        )
        process.executableURL = executable
        process.arguments = wrappedArguments
        process.environment = environment
        process.currentDirectoryURL = resolvedWorkingDirectory(workingDirectory)
        // Concurrent drain via runProcess: the large `--full` dump on stdout and a verbose error on stderr
        // both flow without either pipe filling and deadlocking the child. Bounded by a generous timeout so a
        // runaway tool can't hang the pipeline forever (a normal parse/fill finishes in well under this).
        let output = runProcess(process, timeout: bundledToolTimeoutSeconds)
        return (
            output.exitCode,
            String(data: output.stdout, encoding: .utf8) ?? "",
            String(data: output.stderr, encoding: .utf8) ?? ""
        )
    }

    /// Upper bound for a single bundled-tool run. Generous — a long OCR pass over a big scanned PDF is fine
    /// — but finite, so a wedged child is eventually killed instead of hanging the form/media pipeline.
    private static let bundledToolTimeoutSeconds: TimeInterval = 900

    /// The directory holding the bundled command-line tools (`ffmpeg`/`yt-dlp`/...), which skills invoke
    /// by bare name and rely on being on the shell PATH. Resolved fresh each call (not cached) so tools
    /// that `BundledToolsInstaller` downloads after launch are picked up without a relaunch.
    ///
    /// Preference order: an explicit `DONKEY_TOOLS_DIR` override, then the first-run download in
    /// Application Support, then a copy baked into the app bundle (the offline override, or a dev symlink).
    /// `nil` when none exists, so the child process inherits the environment unchanged and skills fall back
    /// to whatever the user has installed.
    ///
    /// The `DONKEY_TOOLS_DIR` override is what lets a test or eval process — where `Bundle.main` is the
    /// test runner, not the app, so the baked path never resolves — point at the repo's `vendor/donkey-tools`
    /// and run the SAME bundled `lit`/`pdf-fill`/`ffmpeg` (and pdfium) as production. It mirrors the
    /// build-time `DONKEY_TOOLS_DIR` convention in `ensure-bundled-tools.sh`.
    static var bundledToolsDirectory: URL? {
        let fileManager = FileManager.default
        // Read live via getenv: `ProcessInfo.processInfo.environment` is a process-start snapshot, so a test
        // or eval that `setenv`s this after launch would otherwise not be seen.
        if let raw = getenv("DONKEY_TOOLS_DIR") {
            let override = String(cString: raw)
            if !override.isEmpty {
                let dir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                if fileManager.fileExists(atPath: dir.path) {
                    return dir
                }
            }
        }
        // In a development build (where the baked donkey-tools resource is a symlink),
        // we MUST prioritize it so that local uncommitted changes to native tools are immediately
        // reflected in the app without being shadowed by older downloads in Application Support.
        if let baked = Bundle.main.resourceURL?.appendingPathComponent("donkey-tools", isDirectory: true) {
            let isSymlink = (try? baked.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            if isSymlink && fileManager.fileExists(atPath: baked.path) {
                return baked
            }
        }
        if let installed = BundledTools.resolvedInstallDirectory() {
            return installed
        }
        if let baked = Bundle.main.resourceURL?
            .appendingPathComponent("donkey-tools", isDirectory: true),
            fileManager.fileExists(atPath: baked.path) {
            return baked
        }
        return nil
    }

    /// The environment for a `shell_exec` child: the app's environment, but with PATH rebuilt as
    /// `<bundled tools dir> : <login-shell PATH>`.
    ///
    /// A GUI-launched app (Finder/Dock) inherits only launchd's minimal PATH —
    /// `/usr/bin:/bin:/usr/sbin:/sbin` — which omits `/opt/homebrew/bin` and everything else the
    /// user's profile adds. Building the child's PATH from that minimal value made every
    /// Homebrew-installed tool (`brew`, `ffmpeg`, `yt-dlp`, …) read as `command not found`, even
    /// though the user clearly had them in Terminal. Anchoring on the login-shell PATH means the agent
    /// sees exactly what the user sees.
    ///
    /// The bundled tools dir is PREPENDED, so the app's curated, signed copy ALWAYS wins over whatever the
    /// user happens to have on their PATH — no per-tool exceptions. Packaged-wins is the whole point of
    /// bundling: a capability behaves identically on every machine (the libass ffmpeg that can burn in
    /// subtitles, a yt-dlp that launches under the sandbox), instead of silently deferring to a user's
    /// stripped or incompatible build. Prepending the same dir also resolves any tool the user lacks, so
    /// the install-nothing guarantee falls out for free. The login-shell PATH still follows, so everything
    /// the user has — and that Donkey doesn't bundle — keeps resolving.
    static func shellEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var segments: [String] = []
        if let toolsDirectory = bundledToolsDirectory {
            segments.append(toolsDirectory.path)
            // `lit` (liteparse) loads pdfium as a shared library at runtime via dlopen, and pdfium-rs
            // reads PDFIUM_LIB_PATH for the directory holding `libpdfium.dylib`. We ship that dylib in the
            // bundled-tools dir next to `lit`, so point the agent's shell at it — otherwise every PDF
            // parse (`lit parse …`, the pdf skill's label recovery) panics with "could not find pdfium
            // shared library". Only the agent's child sees this; the app process is untouched.
            environment["PDFIUM_LIB_PATH"] = toolsDirectory.path
        }
        segments.append(loginShellPath)
        environment["PATH"] = segments.joined(separator: ":")
        return environment
    }

    /// The PATH the user's interactive shell would have, resolved once. Asking the login shell
    /// (`$SHELL -lc …`) runs their `.zprofile`/`.zshrc`, so the result includes `/opt/homebrew/bin`,
    /// `~/.local/bin`, language version managers, and anything else they rely on — the same PATH they
    /// get in Terminal. Resolved lazily and cached: it is stable for the process lifetime and spawning
    /// a login shell is not free.
    private static let loginShellPath: String = resolveLoginShellPath()

    /// A PATH that already covers both Homebrew prefixes, used when the login shell can't be queried so
    /// the agent still degrades to a useful PATH rather than launchd's bare minimum.
    private static let fallbackShellPath =
        "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    private static func resolveLoginShellPath() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Markers fence the value so output printed by the user's rc files (version-manager banners,
        // etc.) can't contaminate the PATH we extract.
        let start = "__DONKEY_PATH_START__"
        let end = "__DONKEY_PATH_END__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf '%s%s%s' '\(start)' \"$PATH\" '\(end)'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return fallbackShellPath
        }
        // Bound it: a login shell normally exits in well under a second, but a pathological profile
        // must not hang the first shell_exec forever.
        if finished.wait(timeout: .now() + 5.0) == .timedOut {
            process.terminate()
            return fallbackShellPath
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let output = String(data: data, encoding: .utf8),
            let lower = output.range(of: start),
            let upper = output.range(of: end)
        else {
            return fallbackShellPath
        }
        let resolved = String(output[lower.upperBound..<upper.lowerBound])
        return resolved.isEmpty ? fallbackShellPath : resolved
    }

    // MARK: - Result helpers

    private static func success(
        _ context: HarnessToolExecutionContext,
        summary: String,
        facts: [String: String],
        metadata: [String: String]
    ) -> HarnessToolResult {
        var allFacts = facts
        allFacts["lastAcceptedTool"] = context.call.name
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: summary,
            observations: HarnessObservationDelta(facts: allFacts),
            metadata: metadata.merging(["executor": "donkeyCommandLayer"]) { current, _ in current }
        )
    }

    private static func failed(
        _ context: HarnessToolExecutionContext,
        _ summary: String,
        reason: String
    ) -> HarnessToolResult {
        HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .failed,
            summary: summary,
            metadata: ["executor": "donkeyCommandLayer", "reason": reason]
        )
    }

    private static func invalidInput(
        _ context: HarnessToolExecutionContext,
        _ summary: String
    ) -> HarnessToolResult {
        HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .invalidInput,
            summary: summary,
            metadata: ["executor": "donkeyCommandLayer", "reason": "invalidInput"]
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

/// Drives a one-shot `WKWebView` load to completion (or a timeout) for
/// `web_snapshot`. Resolves `true` on `didFinish`, `false` on failure or timeout;
/// the `settled` guard keeps the continuation from resuming twice.
@MainActor
private final class WebSnapshotLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var settled = false

    func load(_ url: URL, in webView: WKWebView, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.settle(false)
            }
        }
    }

    /// Load an in-memory HTML/SVG document (no network) for `image_render`. Resolves the same way as
    /// `load` — `true` on `didFinish`, `false` on failure or timeout.
    func loadHTML(_ html: String, in webView: WKWebView, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.settle(false)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        settle(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        settle(false)
    }

    private func settle(_ value: Bool) {
        guard !settled else { return }
        settled = true
        continuation?.resume(returning: value)
        continuation = nil
    }
}
