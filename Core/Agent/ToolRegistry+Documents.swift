import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ToolRegistry {
// MARK: - Documents

    func docRead(_ args: [String: Any]) async throws -> ToolResult {
        guard let path = args["path"] as? String else { return .fail("path обязателен") }
        let url = resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .fail("Файл не найден: \(display(url))")
        }
        let ext = url.pathExtension.lowercased()
        let pageFrom = max(1, Self.int(args, "page_from") ?? 1)
        let pageTo = Self.int(args, "page_to")

        switch ext {
        case "pdf":
            return try readPDF(url, from: pageFrom, to: pageTo)
        case "docx":
            return try readZipText(url, entry: "word/document.xml", breaks: [
                "</w:p>": "\n", "</w:tr>": "\n", "<w:tab/>": "\t", "<w:br/>": "\n"
            ])
        case "odt":
            return try readZipText(url, entry: "content.xml", breaks: [
                "</text:p>": "\n", "</text:h>": "\n"
            ])
        case "pptx":
            return try readPptx(url)
        case "xlsx":
            return try readXlsx(url, formulas: Self.bool(args, "formulas") ?? false)
        case "rtf":
            guard let textutil = Self.which("textutil") else {
                return .fail("textutil недоступен")
            }
            let result = try Self.runSync(
                "\(textutil) -convert txt -stdout \(Self.shellQuote(url.path))",
                cwd: workspace, timeout: 30
            )
            let (status, body) = Self.splitExit(result)
            guard status == 0 else { return .fail("textutil: \(String(body.prefix(300)))") }
            return .ok(Self.clipDocument(body))
        case "md", "markdown", "txt", "csv", "json", "xml", "html", "htm", "log", "yaml", "yml":
            // Plain text stays on the same windowed path as fs_read: pagination, binary
            // refusal and the offset note all already work there.
            return try await readFile(args)
        default:
            return .fail("Формат .\(ext) не поддержан. Есть: pdf, docx, xlsx, pptx, odt, rtf, "
                + "md, txt, csv, json, xml, html.")
        }
    }

    // MARK: PDF

    private func readPDF(_ url: URL, from: Int, to: Int?) throws -> ToolResult {
        guard let pdftotext = Self.which("pdftotext") else {
            return .fail("Нужен poppler для PDF: brew install poppler")
        }
        let last = max(from, to ?? from)
        let range = to == nil ? "-f \(from)" : "-f \(from) -l \(last)"
        let result = try Self.runSync(
            "\(pdftotext) -layout \(range) \(Self.shellQuote(url.path)) -",
            cwd: workspace, timeout: 60
        )
        let (status, body) = Self.splitExit(result)
        guard status == 0 else { return .fail("pdftotext: \(String(body.prefix(300)))") }

        // A scanned page has no text layer. Render it and OCR automatically instead of
        // returning an empty page and making the model discover the workaround.
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let rendered = Self.renderPDFPage(url, page: from),
               let recognized = try? ocr(["path": rendered.path]),
               !recognized.isError,
               !recognized.output.isEmpty,
               recognized.output != "Текст не распознан." {
                return .ok("PDF, страница \(from) распознана (скан)\n" + Self.clipDocument(recognized.output))
            }
            return .ok("PDF: текстовый слой пуст, распознать страницу не удалось (скан?)")
        }

        var header = "PDF"
        if let pages = Self.pdfPageCount(url) { header += ", \(pages) страниц" }
        if to != nil { header += ", страницы \(from)–\(last)" }
        return .ok(header + "\n" + Self.clipDocument(body))
    }

    private static func pdfPageCount(_ url: URL) -> Int? {
        guard let pdfinfo = which("pdfinfo") else { return nil }
        guard let output = try? runSync("\(pdfinfo) \(shellQuote(url.path))", cwd: url.deletingLastPathComponent(), timeout: 15) else {
            return nil
        }
        for line in output.components(separatedBy: "\n") where line.hasPrefix("Pages:") {
            return Int(line.replacingOccurrences(of: "Pages:", with: "").trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Renders a PDF page to a PNG in the artifacts folder.
    ///
    /// Used by `image_read` (a PDF is a valid image source) and by the scan fallback of
    /// `doc_read`. CoreGraphics only: no sips or poppler render step to shell out to.
    static func renderPDFPage(_ url: URL, page: Int, scale: CGFloat = 2) -> URL? {
        guard let document = CGPDFDocument(url as CFURL),
              let pdfPage = document.page(at: max(1, page)) else { return nil }
        let bounds = pdfPage.getBoxRect(.mediaBox)
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(pdfPage)
        guard let image = context.makeImage() else { return nil }

        try? AppPaths.ensureDirectory(AppPaths.artifactsDirectory)
        let output = AppPaths.artifactsDirectory
            .appendingPathComponent("pdf-\(UUID().uuidString.prefix(8)).png")
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output : nil
    }

    // MARK: Zip-based formats

    private func readZipText(_ url: URL, entry: String, breaks: [String: String]) throws -> ToolResult {
        guard let text = Self.unzipEntry(url, entry) else {
            return .fail("Не удалось прочитать \(entry) из \(display(url))")
        }
        let body = Self.stripXML(text, breaks: breaks)
        return .ok(body.isEmpty ? "(документ пуст)" : Self.clipDocument(body))
    }

    private func readPptx(_ url: URL) throws -> ToolResult {
        let slides = Self.unzipList(url)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { Self.trailingNumber($0) < Self.trailingNumber($1) }
        guard !slides.isEmpty else { return .fail("Слайды не найдены в \(display(url))") }

        var out: [String] = []
        for (index, slide) in slides.enumerated() {
            guard let xml = Self.unzipEntry(url, slide) else { continue }
            let texts = Self.matches(in: xml, pattern: #"<a:t>([^<]*)</a:t>"#)
            guard !texts.isEmpty else { continue }
            out.append("## Слайд \(index + 1)")
            out.append(texts.map(Self.decodeEntities).joined(separator: "\n"))
        }
        return .ok(out.isEmpty ? "Текст на слайдах не найден." : Self.clipDocument(out.joined(separator: "\n")))
    }

    private func readXlsx(_ url: URL, formulas: Bool = false) throws -> ToolResult {
        if let python = Self.which("python3") {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("xlsx-\(UUID().uuidString).py")
            try Self.openpyxlScript.write(to: tmp, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                let mode = formulas ? "formulas" : "values"
                let result = try Self.runSync(
                    "\(python) \(Self.shellQuote(tmp.path)) \(Self.shellQuote(url.path)) \(mode)",
                    cwd: workspace, timeout: 60
                )
                let (status, body) = Self.splitExit(result)
                if status == 0, !body.isEmpty { return .ok(Self.clipDocument(body)) }
            }
        }
        // No openpyxl: the shared strings are still better than nothing, and the note
        // says what is missing instead of returning a corrupt table.
        guard let shared = Self.unzipEntry(url, "xl/sharedStrings.xml") else {
            return .fail("xlsx: нет openpyxl и не удалось прочитать sharedStrings. "
                + "Установи: python3 -m pip install openpyxl")
        }
        let strings = Self.matches(in: shared, pattern: #"<t[^>]*>([^<]*)</t>"#).map(Self.decodeEntities)
        return .ok("[без openpyxl: только строковые значения, без раскладки по листам]\n"
            + Self.clipDocument(strings.joined(separator: "\n")))
    }

    private static let openpyxlScript = """
    import sys
    try:
        import openpyxl
    except ImportError:
        sys.exit(2)
    wb = openpyxl.load_workbook(sys.argv[1], read_only=True, data_only=(sys.argv[2] != "formulas"))
    for ws in wb.worksheets:
        print(f"## {ws.title}")
        for row in ws.iter_rows(values_only=True):
            values = [str(cell) for cell in row if cell is not None]
            if values:
                print(" | ".join(values))
    """

    // MARK: Writing

    func docWrite(_ args: [String: Any]) async throws -> ToolResult {
        guard let path = args["path"] as? String else { return .fail("path обязателен") }
        let content: String
        if let inline = args["content"] as? String {
            content = inline
        } else if let source = args["source"] as? String {
            content = try String(contentsOf: resolve(source), encoding: .utf8)
        } else {
            return .fail("Нужен content (markdown) или source (путь к .md)")
        }

        let output = resolve(path)
        if let refusal = writeGuard(output) { return refusal }
        if FileManager.default.fileExists(atPath: output.path),
           let refusal = await requireFreshRead(output) { return refusal }
        try AppPaths.ensureDirectory(output.deletingLastPathComponent())

        let ext = output.pathExtension.lowercased()
        let stem = FileManager.default.temporaryDirectory
            .appendingPathComponent("doc-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: stem.appendingPathExtension("html"))
            try? FileManager.default.removeItem(at: stem.appendingPathExtension("txt"))
        }
        let htmlURL = stem.appendingPathExtension("html")
        let txtURL = stem.appendingPathExtension("txt")

        switch ext {
        case "docx", "rtf":
            guard let textutil = Self.which("textutil") else { return .fail("textutil недоступен") }
            try Self.markdownToHTML(content).write(to: htmlURL, atomically: true, encoding: .utf8)
            let format = ext == "docx" ? "docx" : "rtf"
            let result = try Self.runSync(
                "\(textutil) -convert \(format) -output \(Self.shellQuote(output.path)) "
                + Self.shellQuote(htmlURL.path),
                cwd: workspace, timeout: 60
            )
            let (status, body) = Self.splitExit(result)
            guard status == 0 else { return .fail("textutil: \(String(body.prefix(300)))") }
        case "pdf":
            guard let cupsfilter = Self.which("cupsfilter") else {
                return .fail("cupsfilter недоступен: PDF на macOS собирается через него")
            }
            try Self.plainText(fromMarkdown: content).write(to: txtURL, atomically: true, encoding: .utf8)
            let result = try Self.runSync(
                "\(cupsfilter) -m application/pdf \(Self.shellQuote(txtURL.path)) > \(Self.shellQuote(output.path))",
                cwd: workspace, timeout: 60
            )
            let (status, body) = Self.splitExit(result)
            guard status == 0 else { return .fail("cupsfilter: \(String(body.prefix(300)))") }
        case "html", "htm":
            try Self.markdownToHTML(content).write(to: output, atomically: true, encoding: .utf8)
        case "md", "markdown", "txt":
            try content.write(to: output, atomically: true, encoding: .utf8)
        default:
            return .fail("Формат .\(ext) не поддержан. Есть: docx, rtf, pdf, html, md, txt.")
        }

        await ledger.note(output)
        let size = FileLines.fileSize(output)
        return .ok("Собрано: \(display(output)) (\(Self.humanSize(size)), из markdown \(content.count) симв.)")
    }

    // MARK: Helpers

    private static func clipDocument(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(пусто)" }
        return ToolTruncation.characters(
            trimmed,
            limit: 30_000,
            note: "[документ обрезан на 30 000 символов; для PDF читай по страницам через page_from/page_to]"
        )
    }

    static func which(_ name: String) -> String? {
        [ "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)", "/usr/sbin/\(name)" ]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func unzipList(_ url: URL) -> [String] {
        guard let unzip = which("unzip") else { return [] }
        guard let output = try? runSync("\(unzip) -Z1 \(shellQuote(url.path))", cwd: url.deletingLastPathComponent(), timeout: 20) else {
            return []
        }
        return splitExit(output).body.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private static func unzipEntry(_ url: URL, _ entry: String) -> String? {
        guard let unzip = which("unzip") else { return nil }
        guard let output = try? runSync(
            "\(unzip) -p \(shellQuote(url.path)) \(shellQuote(entry))",
            cwd: url.deletingLastPathComponent(), timeout: 30
        ) else { return nil }
        let (status, body) = splitExit(output)
        return status == 0 ? body : nil
    }

    static func stripXML(_ xml: String, breaks: [String: String]) -> String {
        var text = xml
        for (marker, replacement) in breaks {
            text = text.replacingOccurrences(of: marker, with: replacement)
        }
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#xA;", with: "\n")
    }

    static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func trailingNumber(_ value: String) -> Int {
        Int(String(value.reversed().prefix { $0.isNumber }.reversed())) ?? 0
    }

    static func markdownToHTML(_ markdown: String) -> String {
        // textutil reads HTML in the system encoding unless told otherwise; without the
        // meta tag Cyrillic turns into mojibake on the way into the docx.
        var out = ["<html><head><meta charset=\"utf-8\"></head><body>"]
        var inCode = false
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                inCode.toggle()
                out.append(inCode ? "<pre>" : "</pre>")
                continue
            }
            if inCode {
                out.append(escapeHTML(line))
                continue
            }
            for (prefix, tag) in [("# ", "h1"), ("## ", "h2"), ("### ", "h3")] where line.hasPrefix(prefix) {
                out.append("<\(tag)>\(escapeHTML(String(line.dropFirst(prefix.count))))</\(tag)>")
                break
            }
            if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("<p></p>")
            } else {
                out.append("<p>\(escapeHTML(line))</p>")
            }
        }
        out.append("</body></html>")
        return out.joined(separator: "\n")
    }

    static func plainText(fromMarkdown markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        }.joined(separator: "\n")
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - Images

extension ToolRegistry {
    /// Reads an image, optionally normalizes EXIF orientation, crops, rotates and
    /// resizes it, and returns a file the chat can display.
    ///
    /// The old path sent screenshots as-is: a 4K phone screenshot cost tokens and
    /// arrived sideways. Everything here is ImageIO/CoreImage, so there are no external
    /// tools to install.
    func imageRead(_ args: [String: Any]) async throws -> ToolResult {
        guard let raw = args["path"] as? String else { return .fail("path обязателен") }
        let originalURL = resolve(raw)
        // A PDF is an image source too: render the requested page first, then the same
        // crop/rotate/resize pipeline applies. `sips` is the user's manual workaround,
        // not something the model should have to know.
        let isPDF = originalURL.pathExtension.lowercased() == "pdf"
        let page = max(1, Self.int(args, "page") ?? 1)
        let url: URL
        if isPDF {
            guard let rendered = Self.renderPDFPage(originalURL, page: page) else {
                return .fail("Не удалось отрисовать страницу \(page) из \(display(originalURL))")
            }
            url = rendered
        } else {
            url = originalURL
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return .fail("Не удалось открыть изображение: \(display(originalURL))")
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .fail("Формат не читается (не изображение?): \(display(url))")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientationRaw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: UInt32(orientationRaw)) ?? .up

        let originalWidth = cgImage.width
        let originalHeight = cgImage.height

        if Self.bool(args, "info") ?? false {
            let size = FileLines.fileSize(url)
            return .ok("image: \(originalWidth)x\(originalHeight), orientation \(orientationRaw), "
                + "\(Self.humanSize(size))")
        }

        var image = CIImage(cgImage: cgImage)
        if orientation != .up {
            image = image.oriented(forExifOrientation: Int32(orientation.rawValue))
        }

        if let x = Self.int(args, "crop_x"), let y = Self.int(args, "crop_y"),
           let width = Self.int(args, "crop_w"), let height = Self.int(args, "crop_h"),
           width > 0, height > 0 {
            // Crop is given in top-left pixel coordinates; CoreImage is bottom-left.
            let flippedY = image.extent.height - CGFloat(y) - CGFloat(height)
            image = image.cropped(to: CGRect(
                x: CGFloat(x), y: flippedY, width: CGFloat(width), height: CGFloat(height)
            ))
        }

        let degrees = Self.int(args, "rotate") ?? 0
        if degrees % 360 != 0 {
            let radians = CGFloat(degrees) * .pi / 180
            let extent = image.extent
            image = image
                .transformed(by: CGAffineTransform(translationX: extent.midX, y: extent.midY))
                .transformed(by: CGAffineTransform(rotationAngle: radians))
                .transformed(by: CGAffineTransform(translationX: -extent.midX, y: -extent.midY))
        }

        if let maxWidth = Self.int(args, "scale_down"), maxWidth > 0,
           image.extent.width > CGFloat(maxWidth) {
            let factor = CGFloat(maxWidth) / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        } else if let width = Self.int(args, "width"), width > 0 {
            let factor = CGFloat(width) / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        } else if let height = Self.int(args, "height"), height > 0 {
            let factor = CGFloat(height) / image.extent.height
            image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let rendered = context.createCGImage(image, from: image.extent) else {
            return .fail("Не удалось перерисовать изображение")
        }

        try AppPaths.ensureDirectory(AppPaths.artifactsDirectory)
        let output = AppPaths.artifactsDirectory
            .appendingPathComponent("image-\(UUID().uuidString.prefix(8)).png")
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            return .fail("Не удалось создать PNG")
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else {
            return .fail("Не удалось записать PNG")
        }

        var note = isPDF
            ? "PDF стр. \(page): \(rendered.width)x\(rendered.height)"
            : "image: \(originalWidth)x\(originalHeight) → \(rendered.width)x\(rendered.height)"
        if orientation != .up { note += ", EXIF-поворот применён" }
        if degrees % 360 != 0 { note += ", поворот \(degrees)°" }
        return .ok(note + "\n[image: \(output.path)]")
    }
}
