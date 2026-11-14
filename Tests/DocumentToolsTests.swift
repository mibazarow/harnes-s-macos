import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Harness

final class DocumentToolsTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-docs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    private var tool: ToolRegistry {
        ToolRegistry(workspace: sandbox, memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil)
    }

    private func path(_ name: String) -> URL { sandbox.appendingPathComponent(name) }

    // MARK: Plain text

    func testDocReadDelegatesPlainTextToTheWindowedReader() async throws {
        try (1...100).map(String.init).joined(separator: "\n").write(
            to: path("notes.md"), atomically: true, encoding: .utf8
        )

        let result = try await tool.docRead(["path": path("notes.md").path])

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("1: 1"), result.output)
        XCTAssertTrue(result.output.contains("offset=41"), result.output)
    }

    // MARK: docx

    func testDocReadAndWriteDocx() async throws {
        let html = "<html><head><meta charset=\"utf-8\"></head><body><p>Привет из docx</p><p>второй абзац</p></body></html>"
        let htmlURL = path("source.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        let docx = path("out.docx")
        _ = try ToolRegistry.runSync(
            "/usr/bin/textutil -convert docx -output \(docx.path) \(htmlURL.path)",
            cwd: sandbox, timeout: 30
        )

        let read = try await tool.docRead(["path": docx.path])
        XCTAssertFalse(read.isError, read.output)
        XCTAssertTrue(read.output.contains("Привет из docx"), read.output)
        XCTAssertTrue(read.output.contains("второй абзац"), read.output)

        let written = path("built.docx")
        let write = try await tool.docWrite([
            "path": written.path,
            "content": "# Заголовок\n\nТело документа"
        ])
        XCTAssertFalse(write.isError, write.output)
        let back = try await tool.docRead(["path": written.path])
        XCTAssertTrue(back.output.contains("Заголовок"), back.output)
        XCTAssertTrue(back.output.contains("Тело документа"), back.output)
    }

    // MARK: pdf

    func testDocReadPdfWithPageRange() async throws {
        let text = path("pages.txt")
        try (1...60).map { "Страница \($0)" }.joined(separator: "\n\n").write(
            to: text, atomically: true, encoding: .utf8
        )
        let pdf = path("doc.pdf")
        _ = try ToolRegistry.runSync(
            "/usr/sbin/cupsfilter -m application/pdf \(text.path) > \(pdf.path)",
            cwd: sandbox, timeout: 60
        )
        guard FileManager.default.fileExists(atPath: pdf.path) else {
            throw XCTSkip("cupsfilter недоступен")
        }

        let result = try await tool.docRead([
            "path": pdf.path, "page_from": 1, "page_to": 1
        ])

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("стран"), result.output)
        XCTAssertTrue(result.output.contains("Страница 1"), result.output)
    }

    // MARK: zip-based formats

    func testDocReadPptxSlides() async throws {
        let root = path("slides-src")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("ppt/slides"), withIntermediateDirectories: true
        )
        try #"<p:sld><a:t>Заголовок слайда</a:t><a:t>второй блок</a:t></p:sld>"#
            .write(to: root.appendingPathComponent("ppt/slides/slide1.xml"), atomically: true, encoding: .utf8)
        let pptx = path("deck.pptx")
        _ = try ToolRegistry.runSync(
            "/usr/bin/zip -qr \(pptx.path) .", cwd: root, timeout: 30
        )

        let result = try await tool.docRead(["path": pptx.path])

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("Слайд 1"), result.output)
        XCTAssertTrue(result.output.contains("Заголовок слайда"), result.output)
    }

    func testDocReadOdtParagraphs() async throws {
        let root = path("odt-src")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"<office><text:p>Первый абзац</text:p><text:p>Второй</text:p></office>"#
            .write(to: root.appendingPathComponent("content.xml"), atomically: true, encoding: .utf8)
        let odt = path("doc.odt")
        _ = try ToolRegistry.runSync("/usr/bin/zip -qr \(odt.path) .", cwd: root, timeout: 30)

        let result = try await tool.docRead(["path": odt.path])

        XCTAssertTrue(result.output.contains("Первый абзац"), result.output)
        XCTAssertTrue(result.output.contains("Второй"), result.output)
    }

    func testDocReadXlsxFallsBackToSharedStrings() async throws {
        let root = path("xlsx-src")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("xl"), withIntermediateDirectories: true
        )
        try #"<sst><si><t>Ячейка один</t></si><si><t>Ячейка два</t></si></sst>"#
            .write(to: root.appendingPathComponent("xl/sharedStrings.xml"), atomically: true, encoding: .utf8)
        let xlsx = path("book.xlsx")
        _ = try ToolRegistry.runSync("/usr/bin/zip -qr \(xlsx.path) .", cwd: root, timeout: 30)

        let result = try await tool.docRead(["path": xlsx.path])

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("Ячейка один"), result.output)
    }

    // MARK: images

    func testImageReadResizesAndReportsDimensions() async throws {
        let url = try makePNG(width: 63, height: 47)

        let info = try await tool.imageRead(["path": url.path, "info": true])
        XCTAssertTrue(info.output.contains("63x47"), info.output)

        let resized = try await tool.imageRead(["path": url.path, "width": 32])
        XCTAssertFalse(resized.isError, resized.output)
        XCTAssertTrue(resized.output.contains("→ 32x"), resized.output)
        XCTAssertTrue(resized.output.contains("[image: "), resized.output)

        let outPath = try XCTUnwrap(resized.output.split(separator: "\n").last?
            .dropFirst("[image: ".count).dropLast())
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: String(outPath)) as CFURL, nil)
        let image = try XCTUnwrap(source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(image.width, 32)
    }

    // MARK: OCR

    func testOcrReturnsWordsAndPixelBoxes() async throws {
        let url = try makeTextImage("HELLO 123")

        let plain = try tool.ocr(["path": url.path, "lang": ["en"]])
        XCTAssertTrue(plain.output.uppercased().contains("HELLO"), plain.output)

        let coords = try tool.ocr(["path": url.path, "lang": ["en"], "coords": true])
        XCTAssertTrue(coords.output.contains("[x="), coords.output)
        XCTAssertTrue(coords.output.contains("y="), coords.output)
    }

    private func makeTextImage(_ text: String) throws -> URL {
        let size = NSSize(width: 600, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 30, y: 50), withAttributes: [
            .font: NSFont.systemFont(ofSize: 64),
            .foregroundColor: NSColor.black
        ])
        image.unlockFocus()
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let url = path("text.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makePNG(width: Int, height: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let url = path("pixel.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
