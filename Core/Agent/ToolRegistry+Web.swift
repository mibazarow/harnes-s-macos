import AppKit
import Foundation
import Vision

extension ToolRegistry {
// MARK: - Web and vision
    func fetchURL(_ args: [String: Any]) async throws -> ToolResult {
        guard let raw = args["url"] as? String, let url = URL(string: raw) else {
            return .fail("url обязателен")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) Harness/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // An empty 401/403/429 is usually a network-level block, not a missing page;
            // saying so saves the model a retry loop that cannot succeed.
            let hint = [401, 403, 429].contains(http.statusCode) && body.isEmpty
                ? " — пустое тело: вероятно, блокировка по IP или региону. "
                    + "Попробуй другой proxy через scrapling make_request или stealthy_fetch."
                : ""
            return .fail("HTTP \(http.statusCode) для \(raw)\(hint)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            return .fail("Ответ не является текстом")
        }
        // Extraction happens first, pagination second: a page is one HTML blob, but the
        // model often needs only the top of it, and says so with offset.
        let full = Self.plainText(fromHTML: html, limit: 200_000)
        guard !full.isEmpty else { return .ok("(на странице нет читаемого текста)") }
        let offset = max(0, Self.int(args, "offset") ?? 0)
        let limit = min(max(Self.int(args, "limit") ?? 30_000, 500), 100_000)
        guard offset < full.count else {
            return .ok("(пусто: offset=\(offset) за концом текста, всего \(full.count) симв.)")
        }
        let start = full.index(full.startIndex, offsetBy: offset)
        let end = full.index(start, offsetBy: min(limit, full.count - offset))
        var out = String(full[start..<end])
        if end < full.endIndex {
            out += "\n\n[обрезано: символы \(offset)–\(full.distance(from: full.startIndex, to: end)) "
                + "из \(full.count); продолжение — offset=\(full.distance(from: full.startIndex, to: end))]"
        }
        return .ok(out)
    }

    func webSearch(_ args: [String: Any]) async throws -> ToolResult {
        guard let query = args["query"] as? String, !query.isEmpty else { return .fail("query обязателен") }
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            return .fail("Не удалось построить запрос")
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return .fail("Некорректный запрос") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) Harness/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""

        let pattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(html.startIndex..., in: html)
        var results: [String] = []
        for match in regex.matches(in: html, range: range).prefix(10) {
            guard let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }
            let link = String(html[urlRange])
            let title = Self.plainText(fromHTML: String(html[titleRange]), limit: 200)
            results.append("- \(title)\n  \(link)")
        }
        return .ok(results.isEmpty ? "Ничего не найдено." : results.joined(separator: "\n"))
    }

    /// R16.6: a persistent browser with a real profile. The tool only ensures the process
    /// is up and hands the CDP endpoint to the script; the script never closes it.
    func browser(_ args: [String: Any]) async throws -> ToolResult {
        guard let action = args["action"] as? String else { return .fail("action обязателен") }

        let tools = AppPaths.dataDirectory.appendingPathComponent("tools", isDirectory: true)
        try AppPaths.ensureDirectory(tools)
        try AppPaths.ensureDirectory(AppPaths.artifactsDirectory)

        if !FileManager.default.fileExists(atPath: tools.appendingPathComponent("node_modules/playwright").path) {
            return .fail("Playwright не установлен. Один раз выполни: cd ~/HARNESS_S_DATA/tools && npm i playwright@1.63.0")
        }

        let endpoint: URL
        switch await BrowserSession.shared.ensureRunning() {
        case .failed(let reason):
            return .fail(reason)
        case .ready(let url):
            endpoint = url
        }

        let scriptURL = tools.appendingPathComponent("browser.mjs")
        try Self.browserScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        var payload: [String: Any] = [
            "action": action,
            "endpoint": endpoint.absoluteString,
            "statePath": BrowserSession.shared.stateFile.path
        ]
        for key in ["url", "selector", "value", "path", "expression", "mode"] {
            if let value = args[key] as? String { payload[key] = value }
        }
        if let index = Self.int(args, "index") { payload["index"] = index }
        if let timeout = Self.int(args, "timeout_ms") { payload["timeout_ms"] = timeout }
        if let reload = Self.bool(args, "reload") { payload["reload"] = reload }
        if let raw = payload["path"] as? String {
            payload["path"] = resolve(raw).path
        }
        if payload["path"] == nil, action == "screenshot" {
            payload["path"] = AppPaths.artifactsDirectory
                .appendingPathComponent("page-\(Int(Date().timeIntervalSince1970)).png").path
        }
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"

        let command = "node \(Self.shellQuote(scriptURL.path)) \(Self.shellQuote(json))"
        let output = try await Task.detached(priority: .userInitiated) {
            try Self.runSync(command, cwd: tools, timeout: 180)
        }.value
        let (status, body) = Self.splitExit(output)
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0 else {
            return .fail(text.isEmpty ? "browser: exit \(status)" : String(text.prefix(4_000)))
        }
        return .ok(String(text.prefix(40_000)))
    }

    /// Internal for the test that guards the "never close the live browser" rule.
    static let browserScript = """
    import { chromium } from 'playwright';
    import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
    import { dirname, resolve } from 'node:path';

    const args = JSON.parse(process.argv[2] || '{}');
    const endpoint = args.endpoint || 'http://127.0.0.1:9222';
    const statePath = args.statePath || '';
    const lines = [];

    function say(text) { lines.push(String(text)); }
    function finish(code) {
      const text = lines.join('\\n');
      process.stdout.write(text.endsWith('\\n') || text === '' ? text : text + '\\n', () => process.exit(code));
    }
    function die(message) {
      process.stderr.write(String(message) + '\\n', () => process.exit(2));
    }

    function readState() {
      if (!statePath) return {};
      try { return JSON.parse(readFileSync(statePath, 'utf8')); } catch { return {}; }
    }
    function writeState(value) {
      if (!statePath) return;
      try { mkdirSync(dirname(statePath), { recursive: true }); writeFileSync(statePath, JSON.stringify(value)); } catch {}
    }

    let state = readState();

    let browser;
    try {
      browser = await chromium.connectOverCDP(endpoint);
    } catch (error) {
      die(`Нет соединения с постоянным браузером на ${endpoint}: ${error.message}`);
    }

    const context = browser.contexts()[0] || await browser.newContext();

    async function pages() {
      return context.pages().filter((page) => !page.isClosed());
    }

    async function currentPage() {
      const all = await pages();
      if (all.length === 0) return context.newPage();
      const index = Number.isInteger(state.index) ? state.index : all.length - 1;
      return all[Math.min(Math.max(index, 0), all.length - 1)];
    }

    async function describeTabs() {
      const all = await pages();
      const index = Number.isInteger(state.index) ? state.index : all.length - 1;
      say(`session: port=${new URL(endpoint).port} tabs=${all.length} current=${index}`);
      for (let i = 0; i < all.length; i += 1) {
        const page = all[i];
        let title = '';
        try { title = await page.title(); } catch {}
        say(`${i} ${i === index ? '*' : ' '} ${page.url()} ${title}`);
      }
    }

    async function saveState(path) {
      const page = await currentPage();
      const cookies = await context.cookies();
      const storage = await page.evaluate(() => {
        const dump = (source) => {
          const out = {};
          for (let i = 0; i < source.length; i += 1) {
            const key = source.key(i);
            out[key] = source.getItem(key);
          }
          return out;
        };
        return { localStorage: dump(window.localStorage), sessionStorage: dump(window.sessionStorage) };
      });
      mkdirSync(dirname(resolve(path)), { recursive: true });
      writeFileSync(path, JSON.stringify({ url: page.url(), cookies, storage }, null, 2));
      say(`state saved: ${resolve(path)} cookies=${cookies.length} keys=${Object.keys(storage.localStorage).length}`);
    }

    async function loadState(path) {
      const raw = JSON.parse(readFileSync(path, 'utf8'));
      if (Array.isArray(raw.cookies) && raw.cookies.length) await context.addCookies(raw.cookies);
      const page = await currentPage();
      if (raw.url) await page.goto(raw.url, { waitUntil: 'load', timeout: 45000 });
      if (raw.storage && raw.storage.localStorage) {
        await page.evaluate((data) => {
          for (const [key, value] of Object.entries(data)) window.localStorage.setItem(key, value);
        }, raw.storage.localStorage);
      }
      say(`state loaded: ${resolve(path)} cookies=${(raw.cookies || []).length}`);
    }

    async function collectNetwork(page, reload, waitMs) {
      const entries = new Map();
      page.on('request', (request) => {
        if (!entries.has(request)) {
          entries.set(request, { method: request.method(), url: request.url(), status: null, type: null });
        }
      });
      page.on('response', (response) => {
        const entry = entries.get(response.request());
        if (entry) {
          entry.status = response.status();
          entry.type = response.headers()['content-type'] || null;
        }
      });
      if (reload) {
        await page.reload({ waitUntil: 'load', timeout: 30000 }).catch(() => {});
      }
      await page.waitForTimeout(waitMs);
      const list = [...entries.values()];
      say(`requests: ${list.length}${reload ? ' (после reload)' : ' (только с момента подключения; reload=true — с начала загрузки)'}`);
      for (const item of list.slice(0, 200)) {
        say(`${item.status ?? '-'} ${item.method} ${item.url}${item.type ? ' ' + item.type : ''}`);
      }
      return list;
    }

    try {
      switch (args.action) {
        case 'goto':
        case 'open': {
          if (!args.url) die('url обязателен: about:blank открывается только явным url.');
          const page = await currentPage();
          await page.goto(args.url, { waitUntil: 'load', timeout: 45000 });
          await page.waitForTimeout(300);
          say(`title: ${await page.title()}`);
          say(`url: ${page.url()}`);
          if (args.action === 'open') {
            say((await page.innerText('body')).slice(0, 20000));
          }
          break;
        }
        case 'text': {
          const page = await currentPage();
          say((await page.innerText('body')).slice(0, 20000));
          break;
        }
        case 'html': {
          const page = await currentPage();
          say((await page.content()).slice(0, 20000));
          break;
        }
        case 'click': {
          if (!args.selector) die('selector обязателен.');
          const page = await currentPage();
          await page.click(args.selector, { timeout: 20000 });
          say(`clicked ${args.selector}`);
          break;
        }
        case 'fill': {
          if (!args.selector) die('selector обязателен.');
          const page = await currentPage();
          await page.fill(args.selector, args.value || '', { timeout: 20000 });
          say(`filled ${args.selector}`);
          break;
        }
        case 'screenshot': {
          const page = await currentPage();
          const path = args.path || 'shot.png';
          await page.screenshot({ path, fullPage: true });
          say(`Скриншот: ${resolve(path)}`);
          break;
        }
        case 'list':
        case 'tabs': {
          await describeTabs();
          break;
        }
        case 'switch': {
          const all = await pages();
          if (!Number.isInteger(args.index) || args.index < 0 || args.index >= all.length) {
            die(`index вне диапазона: вкладок ${all.length}.`);
          }
          state = { ...state, index: args.index };
          writeState(state);
          const page = all[args.index];
          say(`title: ${await page.title()}`);
          say(`url: ${page.url()}`);
          break;
        }
        case 'back': {
          const page = await currentPage();
          await page.goBack({ waitUntil: 'load', timeout: 30000 });
          say(`url: ${page.url()}`);
          break;
        }
        case 'forward': {
          const page = await currentPage();
          await page.goForward({ waitUntil: 'load', timeout: 30000 });
          say(`url: ${page.url()}`);
          break;
        }
        case 'reload': {
          const page = await currentPage();
          await page.reload({ waitUntil: 'load', timeout: 30000 });
          say(`url: ${page.url()}`);
          break;
        }
        case 'wait': {
          if (!args.selector) die('selector обязателен.');
          const page = await currentPage();
          const timeout = Number.isInteger(args.timeout_ms) ? args.timeout_ms : 20000;
          await page.waitForSelector(args.selector, { timeout });
          say(`visible: ${args.selector}`);
          break;
        }
        case 'eval': {
          if (!args.expression) die('expression обязателен.');
          const page = await currentPage();
          const value = await page.evaluate(args.expression);
          say(JSON.stringify(value).slice(0, 20000));
          break;
        }
        case 'network': {
          const page = await currentPage();
          const waitMs = Number.isInteger(args.timeout_ms) ? args.timeout_ms : 2000;
          await collectNetwork(page, args.reload === true, waitMs);
          break;
        }
        case 'state': {
          const mode = args.mode || args.value || 'save';
          const path = args.path;
          if (!path) die('path обязателен для state.');
          if (mode === 'load') await loadState(path);
          else await saveState(path);
          break;
        }
        default:
          die(`unknown action: ${args.action}`);
      }
      finish(0);
    } catch (error) {
      die(error && error.message ? error.message : String(error));
    }
    """

    func screenshot(_ args: [String: Any]) async throws -> ToolResult {
        try AppPaths.ensureDirectory(AppPaths.artifactsDirectory)
        let path: URL
        if let saveTo = args["save_to"] as? String, !saveTo.isEmpty {
            var url = resolve(saveTo)
            if url.pathExtension.isEmpty { url.appendPathExtension("png") }
            if let refusal = writeGuard(url) { return refusal }
            try AppPaths.ensureDirectory(url.deletingLastPathComponent())
            path = url
        } else {
            path = AppPaths.artifactsDirectory
                .appendingPathComponent("screen-\(UUID().uuidString.prefix(8)).png")
        }

        // R25.2: ScreenCaptureKit takes a window frame even when the window is covered
        // or lives on another Space; `screencapture -l` does not. Fall back only if the
        // capture itself fails, not because the API is newer.
        let windowID = Self.screenshotWindowID(args)

        // R25.7: a short watch instead of screenshot → sleep → screenshot.
        if Self.bool(args, "stream") ?? false {
            guard let windowID else {
                return .fail("stream: нужен window_id или window — поток идёт по окну.")
            }
            let duration = Double(Self.int(args, "duration_ms") ?? 3_000) / 1_000
            let interval = Double(Self.int(args, "interval_ms") ?? 500) / 1_000
            guard let watched = await ScreenStream.watch(
                windowID: CGWindowID(windowID), duration: duration, interval: interval
            ) else {
                return .fail("stream: кадры не снимаются (нужен грант Screen Recording и видимое окно).")
            }
            var text = "frames=\(watched.result.frames) changed=\(watched.result.changedFrames)"
            if !watched.result.regions.isEmpty {
                let listed = watched.result.regions.prefix(12).map {
                    String(format: "%.0f%%x%.0f%%", $0.minX * 100, $0.minY * 100)
                }
                text += " regions=\(listed.joined(separator: ","))"
            }
            if let image = watched.lastChanged {
                let representation = NSBitmapImageRep(cgImage: image)
                if let data = representation.representation(using: .png, properties: [:]) {
                    try? data.write(to: path)
                    Self.resampleIfNeeded(path, scaleDown: Self.double(args, "scale_down"),
                                          maxHeight: Self.int(args, "max_height"))
                    text += " shot=\(path.path)"
                }
            }
            return .ok(text)
        }
        if let windowID, await WindowCapture.capture(windowID: CGWindowID(windowID), to: path) {
            Self.resampleIfNeeded(path, scaleDown: Self.double(args, "scale_down"),
                                  maxHeight: Self.int(args, "max_height"))
            return .ok("Скриншот окна (ScreenCaptureKit): \(path.path)\n"
                + "Размер: \(Self.humanSize(FileLines.fileSize(path))). "
                + "Дальше: image_read(path:) для кропа/сжатия, ocr(path:) для текста.")
        }

        var command = "screencapture -x"
        if let windowID {
            command += " -o -l \(windowID)"
        }
        if let clip = args["clip"] as? [String: Any],
           let x = Self.int(clip, "x"), let y = Self.int(clip, "y"),
           let width = Self.int(clip, "width"), let height = Self.int(clip, "height") {
            command += " -R \(x),\(y),\(width),\(height)"
        }
        command += " \(Self.shellQuote(path.path))"

        let result = try Self.runSync(command, cwd: workspace, timeout: 30)
        let (status, body) = Self.splitExit(result)
        guard status == 0, FileManager.default.fileExists(atPath: path.path) else {
            return .fail("screencapture: \(String(body.prefix(300)))")
        }
        Self.resampleIfNeeded(path, scaleDown: Self.double(args, "scale_down"),
                              maxHeight: Self.int(args, "max_height"))
        return .ok("Скриншот: \(path.path)\nРазмер: \(Self.humanSize(FileLines.fileSize(path))). "
            + "Дальше: image_read(path:) для кропа/сжатия, ocr(path:) для текста.")
    }

    static func screenshotWindowID(_ args: [String: Any]) -> Int? {
        if let id = Self.int(args, "window_id") { return id }
        if let name = args["window"] as? String, !name.isEmpty {
            return Self.windowID(named: name)
        }
        return nil
    }

    static func windowID(named name: String) -> Int? {
        let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return raw.first { window in
            (window[kCGWindowLayer as String] as? Int) == 0
                && ((window[kCGWindowName as String] as? String) ?? "")
                    .localizedCaseInsensitiveContains(name)
        }.flatMap { $0[kCGWindowNumber as String] as? Int }
    }

    static func resampleIfNeeded(_ path: URL, scaleDown: Double?, maxHeight: Int?) {
        guard scaleDown != nil || maxHeight != nil else { return }
        guard let image = NSImage(contentsOf: path),
              let size = image.representations.first.map({
                  CGSize(width: $0.pixelsWide, height: $0.pixelsHigh)
              }),
              let target = ScreenshotScale.target(size: size, scaleDown: scaleDown, maxHeight: maxHeight)
        else { return }
        _ = try? Self.runSync(
            "sips -z \(Int(target.height)) \(Int(target.width)) \(Self.shellQuote(path.path)) >/dev/null",
            cwd: path.deletingLastPathComponent(), timeout: 20
        )
    }

    func ocr(_ args: [String: Any]) throws -> ToolResult {
        guard let raw = args["path"] as? String else { return .fail("path обязателен") }
        let url = resolve(raw)
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .fail("Не удалось открыть изображение: \(display(url))")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = Self.languages(from: args["lang"]) 
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: cgImage).perform([request])

        // Bounding boxes are needed to click on a found label, so they are in pixel
        // coordinates with a top-left origin — the same space the mouse lives in.
        let withCoords = Self.bool(args, "coords") ?? false
        // R18.10: `hit` adds the centre of every box in screen points, so "find the word
        // and click it" needs no arithmetic on the model side. The capture must be
        // traceable to a display (or a window), otherwise points would be a guess.
        let withHit = Self.bool(args, "hit") ?? false
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let frame = withHit ? Self.hitFrame(args: args, pixelSize: CGSize(width: width, height: height)) : nil
        let lines = (request.results ?? []).compactMap { observation -> String? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            guard withCoords || withHit else { return text }
            let box = observation.boundingBox
            let x = box.minX * width
            let y = (1 - box.maxY) * height
            var line = String(
                format: "%@ [x=%.0f y=%.0f w=%.0f h=%.0f]",
                text, x, y, box.width * width, box.height * height
            )
            if withHit {
                let center = CGPoint(x: x + box.width * width / 2, y: y + box.height * height / 2)
                if let frame {
                    let point = ScreenGeometry.point(
                        fromRegionPixels: center, origin: frame.origin, scale: frame.scale
                    )
                    line += String(format: " center=%.0f,%.0f", point.x, point.y)
                } else {
                    line += " center=px:\(Int(center.x)),\(Int(center.y)) (display неизвестен: "
                        + "передай display или window_id)"
                }
            }
            return line
        }
        return .ok(lines.isEmpty ? "Текст не распознан." : lines.joined(separator: "\n"))
    }

    /// Where the captured pixels sit on screen, in points.
    static func hitFrame(args: [String: Any], pixelSize: CGSize) -> (origin: CGPoint, scale: CGFloat)? {
        let screens = displays()
        if let id = int(args, "window_id") {
            guard let rect = windowBounds(id: id) else { return nil }
            let scale = ScreenGeometry.displayIndex(
                for: CGPoint(x: rect.midX, y: rect.midY), screens: screens
            ).map { screens[$0].scale } ?? 1
            return (rect.origin, scale)
        }
        if let index = int(args, "display"), index >= 0, index < screens.count {
            return (screens[index].origin, screens[index].scale)
        }
        guard let index = ScreenGeometry.displayIndex(forPixelSize: pixelSize, screens: screens) else {
            return nil
        }
        return (screens[index].origin, screens[index].scale)
    }

// MARK: - Helpers
    /// Vision wants locale identifiers; `["ru", "en"]` is what a model naturally sends.
    static func languages(from raw: Any?) -> [String] {
        let requested: [String]
        if let list = raw as? [String] {
            requested = list
        } else if let text = raw as? String {
            requested = text.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        } else {
            requested = ["ru", "en"]
        }
        let mapped = requested.filter { !$0.isEmpty }.map { value -> String in
            switch value.lowercased() {
            case "ru": return "ru-RU"
            case "en": return "en-US"
            case "de": return "de-DE"
            case "fr": return "fr-FR"
            case "es": return "es-ES"
            case "zh": return "zh-Hans"
            default: return value
            }
        }
        return mapped.isEmpty ? ["ru-RU", "en-US"] : mapped
    }

    /// Readable text from a page, without the navigation soup.
    ///
    /// The old extractor only removed script/style and tags, so menus, footers and
    /// duplicate nav blocks came through three or four times. Prefer <main>/<article>,
    /// drop chrome, collapse repeated lines.
    static func plainText(fromHTML html: String, limit: Int) -> String {
        var text = html

        for tag in ["main", "article"] {
            if let open = text.range(of: "<\(tag)[^>]*>", options: .regularExpression),
               let close = text.range(
                of: "</\(tag)>", options: .regularExpression, range: open.upperBound..<text.endIndex
               ) {
                text = String(text[open.upperBound..<close.lowerBound])
                break
            }
        }

        for pattern in [
            #"(?is)<head[\s\S]*?</head>"#,
            #"(?is)<script[\s\S]*?</script>"#,
            #"(?is)<style[\s\S]*?</style>"#,
            #"(?is)<noscript[\s\S]*?</noscript>"#,
            #"(?is)<nav[\s\S]*?</nav>"#,
            #"(?is)<header[\s\S]*?</header>"#,
            #"(?is)<footer[\s\S]*?</footer>"#,
            #"(?is)<aside[\s\S]*?</aside>"#,
            #"(?is)<form[\s\S]*?</form>"#,
            #"(?is)<svg[\s\S]*?</svg>"#,
            #"(?is)<!--[\s\S]*?-->"#
        ] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(?i)</(p|div|li|h[1-6]|tr|section|article|main|blockquote|pre|dt|dd)>"#,
            with: "\n", options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"(?i)<li[^>]*>"#, with: "• ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</t[dh]>"#, with: " | ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeEntities(text)

        // Collapse runs and duplicate lines: the same menu item repeated 4 times is the
        // single biggest source of wasted context on real pages.
        var lines: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine
                .replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.count <= 1 { continue }
            if lines.last == line { continue }
            lines.append(line)
        }
        var result = lines.joined(separator: "\n")
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "\n…" : trimmed
    }
}
