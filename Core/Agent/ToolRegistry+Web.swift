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
            return .fail("HTTP \(http.statusCode) для \(raw)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            return .fail("Ответ не является текстом")
        }
        return .ok(Self.plainText(fromHTML: html, limit: 30_000))
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
        let name = "screen-\(Int(Date().timeIntervalSince1970)).png"
        let path = AppPaths.artifactsDirectory.appendingPathComponent(name)
        var command = "screencapture -x"
        if let windowID = Self.int(args, "window_id") {
            command += " -o -l \(windowID)"
        }
        command += " \(Self.shellQuote(path.path))"
        _ = try Self.runSync(command, cwd: workspace, timeout: 30)
        return .ok("Скриншот: \(path.path)\nПоказать пользователю: путь можно передать в ocr(path: \"\(path.path)\").")
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
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: cgImage).perform([request])

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return .ok(lines.isEmpty ? "Текст не распознан." : lines.joined(separator: "\n"))
    }

// MARK: - Helpers
    static func plainText(fromHTML html: String, limit: Int) -> String {
        var text = html
        for pattern in [
            #"(?is)<script[\s\S]*?</script>"#,
            #"(?is)<style[\s\S]*?</style>"#,
            #"(?is)<head[\s\S]*?</head>"#,
            #"(?is)<!--[\s\S]*?-->"#
        ] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</(p|div|li|h[1-6]|tr)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"&nbsp;"#, with: " ")
        text = text.replacingOccurrences(of: #"&amp;"#, with: "&")
        text = text.replacingOccurrences(of: #"&lt;"#, with: "<")
        text = text.replacingOccurrences(of: #"&gt;"#, with: ">")
        text = text.replacingOccurrences(of: #"&quot;"#, with: "\"")
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "\n…" : trimmed
    }
}
