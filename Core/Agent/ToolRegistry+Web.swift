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

    func browser(_ args: [String: Any]) async throws -> ToolResult {
        guard let action = args["action"] as? String else { return .fail("action обязателен") }

        let tools = AppPaths.dataDirectory.appendingPathComponent("tools", isDirectory: true)
        try AppPaths.ensureDirectory(tools)
        try AppPaths.ensureDirectory(AppPaths.artifactsDirectory)

        let scriptURL = tools.appendingPathComponent("browser.mjs")
        try Self.playwrightScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        if !FileManager.default.fileExists(atPath: tools.appendingPathComponent("node_modules/playwright").path) {
            return .fail("Playwright не установлен. Один раз выполни: cd ~/HARNES_S_DATA/tools && npm i playwright@1.63.0 && npx playwright install chromium")
        }

        var payload: [String: Any] = ["action": action]
        for key in ["url", "selector", "value", "path"] {
            if let value = args[key] as? String { payload[key] = value }
        }
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
        return .ok(String(output.prefix(40_000)))
    }

    private static let playwrightScript = """
    import { chromium } from 'playwright';
    import { resolve } from 'node:path';

    const args = JSON.parse(process.argv[2] || '{}');
    if (args.action !== 'goto' && !args.url) {
      console.error('Нужен параметр url: без него открывается пустая страница about:blank.');
      process.exit(2);
    }
    const browser = await chromium.launch({ headless: true });
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    try {
      if (args.url) {
        await page.goto(args.url, { waitUntil: 'load', timeout: 45000 });
        await page.waitForTimeout(500);
      }
      switch (args.action) {
        case 'goto':
          console.log('title:', await page.title());
          console.log('url:', page.url());
          break;
        case 'text':
          console.log((await page.innerText('body')).slice(0, 20000));
          break;
        case 'html':
          console.log((await page.content()).slice(0, 20000));
          break;
        case 'click':
          await page.click(args.selector, { timeout: 20000 });
          console.log('clicked', args.selector);
          break;
        case 'fill':
          await page.fill(args.selector, args.value || '', { timeout: 20000 });
          console.log('filled', args.selector);
          break;
        case 'screenshot': {
          const path = args.path || 'shot.png';
          await page.screenshot({ path, fullPage: true });
          console.log('Скриншот: ' + resolve(path));
          break;
        }
        case 'open':
          console.log('title:', await page.title());
          console.log('url:', page.url());
          console.log((await page.innerText('body')).slice(0, 20000));
          break;
        default:
          console.log('unknown action');
      }
    } finally {
      await browser.close();
    }
    """

    func screenshot(_ args: [String: Any]) throws -> ToolResult {
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

        var command = "screencapture -x"
        if let windowID = Self.int(args, "window_id") {
            command += " -o -l \(windowID)"
        } else if let name = args["window"] as? String, !name.isEmpty,
                  let windowID = Self.windowID(named: name) {
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
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let lines = (request.results ?? []).compactMap { observation -> String? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            guard withCoords else { return text }
            let box = observation.boundingBox
            let x = box.minX * width
            let y = (1 - box.maxY) * height
            return String(
                format: "%@ [x=%.0f y=%.0f w=%.0f h=%.0f]",
                text, x, y, box.width * width, box.height * height
            )
        }
        return .ok(lines.isEmpty ? "Текст не распознан." : lines.joined(separator: "\n"))
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
