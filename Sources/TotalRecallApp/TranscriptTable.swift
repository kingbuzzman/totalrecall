import AppKit
import AppSupport
import SwiftUI

/// The transcript as a native table: time, speaker and words, a row per line, your lines and everyone else's tinted a
/// color each. A three-hour meeting is thousands of lines, so it is an `NSTableView`, which only makes the rows on
/// screen, given the exact height of every row, measured from its words: SwiftUI's lazy stacks and lists guess the
/// height of the rows off screen, which leaves a jump to the latest line short of it, and its plain stacks keep every
/// row's views, hundreds of megabytes for such a meeting.
///
/// It follows the latest line while it is scrolled to the bottom: new lines, and the view getting shorter, keep it
/// there, as whether it is at the bottom is looked at just before each, while nothing has moved yet. Scrolled up, it
/// stays put.
struct TranscriptTable: NSViewRepresentable {
    let lines: [TranscriptLine]
    /// Set to whether it is scrolled to the bottom, as the user scrolls.
    @Binding var isAtBottom: Bool
    /// Changed to scroll to the latest line, such as from a button.
    let scrollToLatestRequests: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FollowingScrollView {
        let table = NSTableView()
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 12, height: 0)
        table.gridStyleMask = []
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = false
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (Column.time, "Time", 64), (Column.speaker, "Speaker", 84), (Column.text, "Text", 300),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = identifier == Column.text ? 120 : 40
            column.resizingMask = identifier == Column.text ? .autoresizingMask : .userResizingMask
            table.addTableColumn(column)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scrollView = FollowingScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.attach(table: table, scrollView: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: FollowingScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onScroll = { isAtBottom in
            // Not while SwiftUI is updating its views, which this is called from.
            DispatchQueue.main.async { if self.isAtBottom != isAtBottom { self.isAtBottom = isAtBottom } }
        }
        coordinator.show(lines)
        if coordinator.scrollToLatestRequests != scrollToLatestRequests {
            coordinator.scrollToLatestRequests = scrollToLatestRequests
            scrollView.scrollToBottom()
        }
    }

    enum Column {
        static let time = NSUserInterfaceItemIdentifier("time")
        static let speaker = NSUserInterfaceItemIdentifier("speaker")
        static let text = NSUserInterfaceItemIdentifier("text")
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        /// Around each row, and between its lines' words and the row's edge.
        static let verticalPadding = 5.0
        static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        static let speakerFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        var scrollToLatestRequests = 0
        var onScroll: ((Bool) -> Void)?
        private var lines: [TranscriptLine] = []
        /// Each row's height, for the text column's width it was measured at.
        private var heights: [CGFloat] = []
        private var measuredWidth: CGFloat = 0
        private weak var table: NSTableView?
        private weak var scrollView: FollowingScrollView?

        func attach(table: NSTableView, scrollView: FollowingScrollView) {
            self.table = table
            self.scrollView = scrollView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(didScroll),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(columnDidResize),
                name: NSTableView.columnDidResizeNotification,
                object: table
            )
        }

        /// Shows `newLines`: adds the lines after those shown, following them if at the bottom, or shows them afresh,
        /// as for a new recording.
        func show(_ newLines: [TranscriptLine]) {
            guard let table, let scrollView, newLines != lines else { return }
            let follows = scrollView.isAtBottom
            if newLines.count > lines.count, Array(newLines.prefix(lines.count)) == lines {
                let added = lines.count..<newLines.count
                lines = newLines
                heights += added.map { height(of: newLines[$0]) }
                table.insertRows(at: IndexSet(integersIn: added), withAnimation: [])
            } else {
                lines = newLines
                heights = lines.map(height(of:))
                table.reloadData()
            }
            if follows { scrollView.scrollToBottom() }
        }

        @objc private func didScroll() {
            if let scrollView { onScroll?(scrollView.isAtBottom) }
        }

        /// The words wrap anew at the text column's new width, so every row is measured again, staying at the bottom
        /// if it was.
        @objc private func columnDidResize() {
            guard let table, let scrollView, textWidth != measuredWidth else { return }
            let follows = scrollView.isAtBottom
            heights = lines.map(height(of:))
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<lines.count))
            if follows { scrollView.scrollToBottom() }
        }

        private var textWidth: CGFloat {
            table?.tableColumn(withIdentifier: Column.text)?.width ?? 300
        }

        /// How tall a row is: its words, wrapped at the text column's width, and the padding around them.
        private func height(of line: TranscriptLine) -> CGFloat {
            measuredWidth = textWidth
            let bounds = NSAttributedString(string: line.text, attributes: [.font: Self.font]).boundingRect(
                with: NSSize(width: max(measuredWidth - 4, 1), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let oneLine = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
            return max(ceil(bounds.height), oneLine) + 2 * Self.verticalPadding
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            lines.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            row < heights.count ? heights[row] : 20
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier, row < lines.count else { return nil }
            let line = lines[row]
            let cell =
                tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
                ?? Self.makeCell(identifier)
            guard let field = cell.textField else { return cell }
            switch identifier {
            case Column.time:
                field.stringValue = line.time
            case Column.speaker:
                field.stringValue = line.speaker
                field.textColor = line.side.color
            default:
                field.stringValue = line.text
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            // Reused, as the cells are: a new one for each row that comes into view would pile up as it scrolls.
            let rowView =
                tableView.makeView(withIdentifier: TintedRowView.identifier, owner: nil) as? TintedRowView
                ?? TintedRowView()
            rowView.tint =
                row < lines.count && lines[row].side != .unknown
                ? lines[row].side.color.withAlphaComponent(0.12) : nil
            return rowView
        }

        /// A cell of a column, its words inset from the row's top by the padding its height was measured with.
        private static func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let field = NSTextField(wrappingLabelWithString: "")
            field.isSelectable = true
            field.drawsBackground = false
            field.translatesAutoresizingMaskIntoConstraints = false
            switch identifier {
            case Column.time:
                field.font = timeFont
                field.textColor = .secondaryLabelColor
                field.maximumNumberOfLines = 1
            case Column.speaker:
                field.font = speakerFont
                field.maximumNumberOfLines = 1
                field.lineBreakMode = .byTruncatingTail
            default:
                field.font = font
                field.textColor = .labelColor
            }
            let cell = NSTableCellView()
            cell.identifier = identifier
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.topAnchor.constraint(equalTo: cell.topAnchor, constant: verticalPadding),
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            ])
            return cell
        }
    }
}

/// A row tinted by who spoke it.
private final class TintedRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("row")

    var tint: NSColor? {
        didSet { needsDisplay = true }
    }

    convenience init() {
        self.init(frame: .zero)
        identifier = Self.identifier
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let tint else { return super.drawBackground(in: dirtyRect) }
        tint.setFill()
        bounds.fill()
    }
}

/// A scroll view that stays at the bottom when it gets shorter or taller, as the strip of words still being recognized
/// below it comes, goes or wraps onto another line, if it was at the bottom just before.
final class FollowingScrollView: NSScrollView {
    /// At the bottom, or close enough; so is one not laid out yet, so it opens on the latest line.
    var isAtBottom: Bool {
        ScrollFollowing.Geometry(
            offset: contentView.bounds.minY,
            visibleHeight: contentView.bounds.height,
            contentHeight: Double(documentView?.frame.height ?? 0)
        )
        .isAtBottom
    }

    override func setFrameSize(_ newSize: NSSize) {
        let follows = isAtBottom
        super.setFrameSize(newSize)
        if follows { scrollToBottom() }
    }

    func scrollToBottom() {
        guard let document = documentView else { return }
        document.layoutSubtreeIfNeeded()
        let bottom = max(0, document.frame.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: bottom))
        reflectScrolledClipView(contentView)
    }
}

extension TranscriptLine.Side {
    /// You in blue, everyone else in orange: a pair that stays apart in light and dark mode, and for color blindness.
    var color: NSColor {
        switch self {
        case .you: .systemBlue
        case .them: .systemOrange
        case .unknown: .secondaryLabelColor
        }
    }
}
