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
    /// `backgroundTurn` marks a turn the user is not watching: the shell path then restores the frontmost
    /// app after each command so a `shell_exec` that raises an app (an `osascript … activate`) can't leave
    /// it in front. Defaults false so callers that don't run background work (the Live voice session) keep
    /// the foreground behavior unchanged.
    public static func makeExecutor(backgroundTurn: Bool = false) -> @Sendable (HarnessToolExecutionContext) async -> HarnessToolResult? {
        { context in await execute(context, backgroundTurn: backgroundTurn) }
    }

    @MainActor
    static func execute(_ context: HarnessToolExecutionContext, backgroundTurn: Bool = false) async -> HarnessToolResult? {
        guard let command = DonkeyCommandLayer.Command(rawValue: context.call.name) else {
            return nil
        }
        switch command {
        case .shellExec:
            return await shellExec(context, backgroundTurn: backgroundTurn)
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
        // run (an unattached WKWebView can snapshot blank). The view stays at one
        // viewport (1280×1600); `captureStitched` scrolls it a screen at a time and
        // composites the shots. The page runs unmodified — no reduced-motion patch,
        // no animation-disabling CSS. Sites that honor `prefers-reduced-motion`
        // (stripe.com) respond by never mounting their animated demo content, which
        // captures as empty boxes; and killing transitions can stall reveal logic
        // that waits on `transitionend`. Tiling is what settles motion instead:
        // every viewport is photographed after dwelling at its own scroll position.
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 1600),
            configuration: WKWebViewConfiguration()
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
        // Warm the page (scroll to mount lazy content, settle media and fonts)
        // before the tiled capture measures its full height and photographs it.
        await prepareForCapture(webView)

        do {
            let data = try await (format == "pdf" ? snapshotStitchedPDF(webView) : snapshotStitchedPNG(webView))
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

    /// Warm the page before the tiled capture. A single top-to-bottom walk mounts
    /// viewport-gated content (lazy images, `IntersectionObserver` reveals) and lets
    /// the document reach its full height, then we settle media and wait on fonts:
    ///
    /// 1. Walk top-to-bottom slowly enough for frameworks to hydrate each screen.
    /// 2. Give every `<video>` a real frame, swap in its poster, or hide it so a
    ///    section shows its background instead of a black rectangle.
    /// 3. De-pin scroll-scrub sections. A `position: sticky` element pinned inside a
    ///    much taller parent is a scroll *runway*: its extra height is empty space
    ///    the pin animation scrubs through, and a static capture renders it as a
    ///    black void. Unpinning the element and collapsing the runway to content
    ///    height makes the section render once, at its natural size.
    /// 4. Wait (bounded) for web fonts and in-flight images so text metrics and
    ///    thumbnails are final, not half-loaded.
    ///
    /// It does *not* flatten transforms or freeze scroll-linked animation: the tiled
    /// capture (`captureStitched`) photographs each viewport while it is actually on
    /// screen, so scroll-scrubbed sections resolve naturally at their own position —
    /// forcing them to a resting state here would distort exactly those layouts.
    @MainActor
    private static func prepareForCapture(_ webView: WKWebView) async {
        let settleBody = """
        function fullHeight() {
          return Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
        }
        // Cap the walk at the capture cap so infinite-scroll feeds, which grow the
        // document faster than we walk it, can't keep the loop alive forever.
        var step = Math.max(window.innerHeight * 0.85, 600);
        for (var y = 0; y < Math.min(fullHeight(), 20000); y += step) {
          window.scrollTo(0, y);
          await new Promise(function (r) { setTimeout(r, 300); });
        }
        window.scrollTo(0, fullHeight());
        await new Promise(function (r) { setTimeout(r, 500); });

        var videos = document.querySelectorAll('video');
        for (var i = 0; i < videos.length; i++) {
          var v = videos[i];
          try {
            v.pause();
            v.removeAttribute('autoplay');
            v.removeAttribute('loop');
            if (v.readyState >= 2 && v.duration && isFinite(v.duration)) {
              v.currentTime = Math.min(0.1 * v.duration, 1);
            } else if (v.poster) {
              var img = document.createElement('img');
              img.src = v.poster;
              img.width = v.clientWidth;
              img.height = v.clientHeight;
              img.style.objectFit = 'cover';
              v.replaceWith(img);
            } else {
              v.style.visibility = 'hidden';
            }
          } catch (e) {}
        }

        var nodes = document.querySelectorAll('body *');
        for (var j = 0; j < nodes.length; j++) {
          var el = nodes[j];
          if (getComputedStyle(el).position !== 'sticky') continue;
          el.style.position = 'relative';
          el.style.top = 'auto';
          // Collapse the pin runway, identified by BOTH: a parent much taller than
          // the sticky child, and overflow visible. The overflow gate keeps this
          // off scroll containers (sticky table headers, sticky sidebars in
          // overflow panes), where forcing height auto would explode the layout.
          var parent = el.parentElement;
          if (parent &&
              getComputedStyle(parent).overflowY === 'visible' &&
              parent.getBoundingClientRect().height > el.getBoundingClientRect().height * 1.3) {
            parent.style.height = 'auto';
            parent.style.minHeight = '0';
          }
        }

        function withTimeout(p, ms) {
          return Promise.race([p, new Promise(function (r) { setTimeout(r, ms); })]);
        }
        try { await withTimeout(document.fonts.ready, 3000); } catch (e) {}
        var pending = Array.prototype.slice.call(document.images)
          .filter(function (im) { return !im.complete; })
          .map(function (im) { return im.decode().catch(function () {}); });
        await withTimeout(Promise.all(pending), 4000);

        window.scrollTo(0, 0);
        await new Promise(function (r) { setTimeout(r, 500); });
        return true;
        """
        _ = try? await webView.callAsyncJavaScript(
            settleBody,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
    }

    /// Grow the web view to its full scrollable height (capped) so a capture takes
    /// in the whole page in one pass. Returns the height actually used.
    @MainActor
    private static func fitToContentHeight(_ webView: WKWebView) async -> CGFloat {
        guard let height = try? await webView.evaluateJavaScript("document.body.scrollHeight") as? CGFloat,
              height > 0 else {
            return webView.bounds.height
        }
        let fitted = min(height, 20_000)
        webView.frame.size.height = fitted
        try? await Task.sleep(nanoseconds: 300_000_000)
        return fitted
    }

    @MainActor
    private static func exportPDF(_ webView: WKWebView) async throws -> Data {
        // One long continuous page: fit the view to the full document and hand
        // createPDF an explicit rect so it emits a single tall page instead of
        // paginating or clipping to the initial viewport.
        let height = await fitToContentHeight(webView)
        let config = WKPDFConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: webView.bounds.width, height: height)
        return try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: config) { result in
                continuation.resume(with: result)
            }
        }
    }

    // MARK: web_snapshot tiled capture

    /// Photograph the page one viewport at a time and composite the shots into a
    /// single tall image. A one-shot full-height snapshot leaves dark voids on
    /// motion-heavy pages: sections built with `content-visibility`,
    /// `IntersectionObserver`, or scroll-linked ("scrubbed") animation are
    /// un-rendered once off screen, so a grab from the top captures them blank.
    /// Capturing each band *while it is on screen* is the general fix — it holds
    /// for any site, not just one layout. Fixed overlays (nav bars, cookie strips)
    /// are hidden on every tile after the first so they aren't stamped down the
    /// whole page; sticky sections were already de-pinned in `prepareForCapture`.
    @MainActor
    private static func captureStitched(_ webView: WKWebView) async throws -> CGImage {
        let viewportW = webView.bounds.width
        let viewportH = webView.bounds.height
        let measured = (try? await webView.evaluateJavaScript(
            "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)"
        ) as? CGFloat) ?? viewportH
        let fullHeight = min(max(measured, viewportH), 20_000)

        // Cache fixed overlays (nav bars, cookie strips) once so we can hide them on
        // later tiles. Only `fixed` — sticky sections were already de-pinned to flow
        // inline in `prepareForCapture`, so they appear once naturally.
        _ = try? await webView.evaluateJavaScript("""
        window.__donkeyChrome = Array.prototype.slice.call(document.querySelectorAll('body *'))
          .filter(function (e) { return getComputedStyle(e).position === 'fixed'; });
        true;
        """)

        var offsets: [CGFloat] = []
        var y: CGFloat = 0
        while y + viewportH < fullHeight { offsets.append(y); y += viewportH }
        offsets.append(max(0, fullHeight - viewportH))

        // Per tile: scroll, hide fixed chrome on tiles > 0, dwell so this
        // viewport's entrance animations play out, then wait (bounded) for the
        // images intersecting it to decode — lazy images only start fetching when
        // they enter the viewport, so a fixed dwell photographs their empty boxes.
        let tileSettleBody = """
        window.scrollTo(0, offset);
        var chrome = window.__donkeyChrome || [];
        for (var i = 0; i < chrome.length; i++) {
          chrome[i].style.visibility = index > 0 ? 'hidden' : '';
        }
        await new Promise(function (r) { setTimeout(r, 600); });
        var pending = Array.prototype.slice.call(document.images).filter(function (im) {
          var rect = im.getBoundingClientRect();
          return rect.bottom > 0 && rect.top < window.innerHeight && !im.complete;
        }).map(function (im) { return im.decode().catch(function () {}); });
        await Promise.race([
          Promise.all(pending),
          new Promise(function (r) { setTimeout(r, 2500); })
        ]);
        await new Promise(function (r) { setTimeout(r, 120); });
        return true;
        """
        var tiles: [(offset: CGFloat, image: CGImage)] = []
        var scale: CGFloat = 1
        for (index, offset) in offsets.enumerated() {
            _ = try? await webView.callAsyncJavaScript(
                tileSettleBody,
                arguments: ["offset": Double(offset), "index": index],
                in: nil,
                contentWorld: .page
            )
            let tile = try await snapshotImage(webView)
            scale = CGFloat(tile.width) / max(viewportW, 1)
            tiles.append((offset, tile))
        }

        let pxW = Int((viewportW * scale).rounded())
        let pxH = Int((fullHeight * scale).rounded())
        guard pxW > 0, pxH > 0, let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // CGContext is bottom-left origin, so a band at document offset `y` sits at
        // context y = totalHeight - y - tileHeight. Later tiles overwrite overlap.
        for tile in tiles {
            let drawY = CGFloat(pxH) - (tile.offset * scale) - CGFloat(tile.image.height)
            ctx.draw(tile.image, in: CGRect(x: 0, y: drawY, width: CGFloat(tile.image.width), height: CGFloat(tile.image.height)))
        }
        guard let stitched = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return stitched
    }

    /// Snapshot the current viewport as a `CGImage`. Converts inside the completion
    /// handler so the non-Sendable `NSImage` never crosses the continuation boundary.
    @MainActor
    private static func snapshotImage(_ webView: WKWebView) async throws -> CGImage {
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: webView.bounds.size)
        return try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown))
                    return
                }
                continuation.resume(returning: cg)
            }
        }
    }

    /// web_snapshot PNG: the stitched full-page image encoded as PNG.
    @MainActor
    private static func snapshotStitchedPNG(_ webView: WKWebView) async throws -> Data {
        let stitched = try await captureStitched(webView)
        guard let png = NSBitmapImageRep(cgImage: stitched).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
    }

    /// web_snapshot PDF: the stitched full-page image as one continuous page when
    /// it fits, sliced into equal tall pages when it does not. This path is raster
    /// (an image PDF) rather than vector, because the page is composited from
    /// per-viewport photographs — the tradeoff that buys void-free motion-site
    /// capture. (`image_render` still uses vector `exportPDF`.)
    ///
    /// Pages are sized in CSS points with the higher-resolution pixels drawn in
    /// (~144 DPI on a 2x snapshot), and capped at the PDF spec's 14,400 pt page
    /// limit. Measured in Preview: pages near the limit render sharp, but far past
    /// it the whole page is rasterized into a capped backing store and reads as
    /// blur at every zoom — and out-of-spec pages break other viewers.
    @MainActor
    private static func snapshotStitchedPDF(_ webView: WKWebView) async throws -> Data {
        let stitched = try await captureStitched(webView)
        let scale = max(CGFloat(stitched.width) / max(webView.bounds.width, 1), 1)
        let cssWidth = CGFloat(stitched.width) / scale
        let cssHeight = CGFloat(stitched.height) / scale
        let pageLimit: CGFloat = 14_400
        let pageCount = max(1, Int((cssHeight / pageLimit).rounded(.up)))
        let pixelPageHeight = Int((CGFloat(stitched.height) / CGFloat(pageCount)).rounded(.up))

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for page in 0..<pageCount {
            let pixelY = page * pixelPageHeight
            let sliceHeight = min(pixelPageHeight, stitched.height - pixelY)
            guard sliceHeight > 0,
                  let slice = stitched.cropping(
                    to: CGRect(x: 0, y: pixelY, width: stitched.width, height: sliceHeight)
                  ) else { continue }
            var mediaBox = CGRect(x: 0, y: 0, width: cssWidth, height: CGFloat(sliceHeight) / scale)
            ctx.beginPage(mediaBox: &mediaBox)
            ctx.draw(slice, in: mediaBox)
            ctx.endPage()
        }
        ctx.closePDF()
        return data as Data
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

    @MainActor
    private static func shellExec(_ context: HarnessToolExecutionContext, backgroundTurn: Bool = false) async -> HarnessToolResult {
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
        // On a background turn the user is not watching, so no command may leave another app in front.
        // A shell command can raise one as a side effect (`osascript … activate`, `open -a`) outside the
        // input guard, so snapshot the frontmost app before the run and hand focus back after — the steal
        // never survives the call. Foreground turns keep whatever the command intentionally brought up.
        let restoreTarget = backgroundTurn ? TargetFocusRecovery.frontmostProcessID() : nil
        let result = await Task.detached(priority: .userInitiated) {
            runShellSync(command, timeout: timeout, workingDirectory: workingDirectory, policy: policy)
        }.value
        if let restoreTarget {
            // `open -a` raises the app ASYNCHRONOUSLY — it returns before the window server makes the app
            // frontmost — so the steal may still be pending here. Poll briefly for the raise to land, then
            // hand focus back; without the wait the restore sees "still frontmost, nothing moved", no-ops,
            // and the app comes forward a beat later and stays. The poll exits the instant focus moves, so a
            // synchronous raise (`osascript … activate`, which blocks until the app is up) costs nothing;
            // only a slow async raise waits, and the cap is short so a non-raising write barely pays. A read
            // never raises an app, so it skips the wait and the restore just confirms nothing moved.
            if classification.tier != .read {
                for _ in 0..<5 {
                    if TargetFocusRecovery.frontmostProcessID() != restoreTarget { break }
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
            }
            TargetFocusRecovery.restoreFrontmost(to: restoreTarget)
        }

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
