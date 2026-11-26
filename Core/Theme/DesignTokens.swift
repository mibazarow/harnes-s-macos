import CoreGraphics

/// Step 1 of the design migration: every metric a view uses comes from here.
///
/// A literal is allowed in a view only when it is `0`, a hairline, or computed. Values
/// that were already in the views and sit off the 4 pt grid are kept at their exact size
/// under `offGrid*` names: folding them onto the grid would move the layout by a point,
/// and that is a separate visual decision with its own screenshot, not a rename.
enum Spacing {
    static let hairline: CGFloat = 1
    static let zero: CGFloat = 0

    static let tight: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let section: CGFloat = 24
    static let page: CGFloat = 40

    // Exact legacy values. See the note above.
    static let offGrid2: CGFloat = 2
    static let offGrid3: CGFloat = 3
    static let offGrid5: CGFloat = 5
    static let offGrid6: CGFloat = 6
    static let offGrid10: CGFloat = 10
    static let offGrid14: CGFloat = 14
    static let offGrid15: CGFloat = 15
    static let offGrid18: CGFloat = 18
    static let offGrid20: CGFloat = 20
    static let offGrid28: CGFloat = 28
    static let offGrid32: CGFloat = 32
    static let offGrid38: CGFloat = 38
}

enum Radius {
    /// Buttons and text fields — the system radius on macOS.
    static let control: CGFloat = 6
    /// Cards, popovers, the composer: larger than a row.
    static let panel: CGFloat = 10
    static let small: CGFloat = 4
    static let medium: CGFloat = 8
}

enum Size {
    static let controlSmall: CGFloat = 20
    static let controlRegular: CGFloat = 24
    static let row: CGFloat = 28
    static let composerMin: CGFloat = 32
    static let composerMaxHeight: CGFloat = 180
    static let iconSmall: CGFloat = 11
    static let iconMedium: CGFloat = 12
}

enum Layout {
    /// The chat column never grows past this, whatever the window does.
    static let chatContainer: CGFloat = 1100
    /// Prose inside the container. Code blocks and tables use the full container width.
    static let textColumn: CGFloat = 760
    static let settingsWidth: CGFloat = 620
    static let settingsHeight: CGFloat = 520
}

enum FontSize {
    /// The transcript's own size, driven by the user's setting.
    static let transcriptDefault: CGFloat = 13
    static let transcriptMin: CGFloat = 11
    static let transcriptMax: CGFloat = 20
    /// Code is one step under the body, as in Xcode.
    static let codeOffset: CGFloat = -1
    static let minReadable: CGFloat = 9
    /// The quick-input panel: one step above body, its hint is caption-sized.
    static let panelField: CGFloat = 16
    static let panelHint: CGFloat = 11
}
