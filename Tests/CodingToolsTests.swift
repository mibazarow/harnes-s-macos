import XCTest
@testable import Harness

final class CodingToolsTests: XCTestCase {
    func testPatchAppliesAddAndRemove() throws {
        let original = """
        line one
        line two
        line three
        """
        let patch = """
        --- a/file
        +++ b/file
        @@ -1,3 +1,4 @@
         line one
        -line two
        +line two changed
        +line two extra
         line three
        """

        let result = try PatchApplier.apply(patch, to: original)
        XCTAssertEqual(result, "line one\nline two changed\nline two extra\nline three")
    }

    func testPatchRejectsMismatchedContext() {
        let original = "a\nb\nc"
        let patch = "@@ -1,3 +1,3 @@\n a\n-X\n+Y\n c"
        XCTAssertThrowsError(try PatchApplier.apply(patch, to: original))
    }

    func testPatchOnEmptyHunksThrows() {
        XCTAssertThrowsError(try PatchApplier.apply("no hunks here", to: "a"))
    }

    func testProjectInspectorDetectsSwift() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "name: Demo".write(to: root.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8)

        let profile = ProjectInspector(workspace: root).inspect()
        XCTAssertTrue(profile.swift)
        XCTAssertEqual(profile.kind, "Swift")
        XCTAssertNotNil(profile.testCommand)
    }

    func testProjectInspectorDetectsBitrix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("local/php_interface", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try "<?php".write(
            to: root.appendingPathComponent("local/php_interface/init.php"),
            atomically: true,
            encoding: .utf8
        )

        let profile = ProjectInspector(workspace: root).inspect()
        XCTAssertTrue(profile.bitrix)
        XCTAssertTrue(profile.php)
        XCTAssertEqual(profile.kind, "Битрикс")
        XCTAssertTrue(profile.notes.contains { $0.contains("init.php") })
    }

    func testProjectInspectorDetectsComposerName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try #"{"name":"acme/site"}"#.write(
            to: root.appendingPathComponent("composer.json"),
            atomically: true,
            encoding: .utf8
        )
        try "<?php echo 1;".write(
            to: root.appendingPathComponent("index.php"),
            atomically: true,
            encoding: .utf8
        )

        let profile = ProjectInspector(workspace: root).inspect()
        XCTAssertEqual(profile.name, "acme/site")
        XCTAssertEqual(profile.kind, "PHP")
    }
}

final class TreeRendererTests: XCTestCase {
    func testTreeIncludesHiddenFilesAndDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-\(UUID().uuidString)", isDirectory: true)
        let component = root.appendingPathComponent("local/components/demo.hello", isDirectory: true)
        let template = component.appendingPathComponent("templates/.default", isDirectory: true)
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "class".write(to: component.appendingPathComponent("class.php"), atomically: true, encoding: .utf8)
        try "desc".write(to: component.appendingPathComponent(".description.php"), atomically: true, encoding: .utf8)
        try "tpl".write(to: template.appendingPathComponent("template.php"), atomically: true, encoding: .utf8)

        let output = ToolRegistry.renderTree(root: root, depth: 8) { $0.lastPathComponent }

        XCTAssertTrue(output.contains(".description.php"), "скрытые файлы должны быть видны:\n\(output)")
        XCTAssertTrue(output.contains(".default/"), "скрытые каталоги должны быть видны:\n\(output)")
        XCTAssertTrue(output.contains("template.php"), "содержимое .default должно быть видно:\n\(output)")
    }

    func testTreeSkipsNoiseDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("node_modules/pkg", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        try "x".write(to: root.appendingPathComponent("node_modules/pkg/index.js"), atomically: true, encoding: .utf8)
        try "y".write(to: root.appendingPathComponent("src/main.js"), atomically: true, encoding: .utf8)

        let output = ToolRegistry.renderTree(root: root, depth: 8) { $0.lastPathComponent }

        XCTAssertFalse(output.contains("node_modules"))
        XCTAssertTrue(output.contains("src/"))
        XCTAssertTrue(output.contains("main.js"))
    }
}
