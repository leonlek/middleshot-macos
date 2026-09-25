import Cocoa

/// The Safe to Clean outline: one expandable row per group, its items below.
/// Owns the outline view; the Disk tab owns the data and does the removing.
final class CleanupListController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Items to remove, with the group they came from. Fired for a single row's
    /// button and for a group's "Clean …" button alike.
    var onClean: (([CleanupItem], CleanupGroup) -> Void)?
    var onReveal: ((URL) -> Void)?

    let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()

    /// Outline rows must be objects that keep their identity across reloads,
    /// so expansion can be restored by kind.
    private final class GroupNode {
        let group: CleanupGroup
        let items: [ItemNode]
        init(_ group: CleanupGroup) {
            self.group = group
            items = group.items.map { ItemNode($0) }
        }
    }

    private final class ItemNode {
        let item: CleanupItem
        init(_ item: CleanupItem) { self.item = item }
    }

    private var nodes: [GroupNode] = []
    private var expandedKinds: Set<CleanupGroup.Kind> = []
    private var pendingIDs: Set<String> = []

    override init() {
        super.init()
        let columns: [(id: String, title: String, width: CGFloat, alignment: NSTextAlignment)] = [
            ("name", "Item", 380, .left),
            ("size", "Size", 90, .right),
            ("actions", "", 200, .right),
        ]
        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.headerCell.alignment = spec.alignment
            if spec.id == "name" {
                column.minWidth = 240
            } else {
                column.minWidth = spec.width
                column.maxWidth = spec.width
            }
            outlineView.addTableColumn(column)
            if spec.id == "name" {
                outlineView.outlineTableColumn = column
            }
        }
        outlineView.style = .inset
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.selectionHighlightStyle = .none
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.indentationPerLevel = 14
        outlineView.dataSource = self
        outlineView.delegate = self

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
    }

    func show(_ groups: [CleanupGroup], pending: Set<String>) {
        pendingIDs = pending
        nodes = groups.map(GroupNode.init)
        outlineView.reloadData()
        for node in nodes where expandedKinds.contains(node.group.kind) {
            outlineView.expandItem(node)
        }
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: return nodes.count
        case let group as GroupNode: return group.items.count
        default: return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? GroupNode {
            return group.items[index]
        }
        return nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is GroupNode
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? GroupNode {
            expandedKinds.insert(node.group.kind)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? GroupNode {
            expandedKinds.remove(node.group.kind)
        }
    }

    // MARK: - Cells

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        item is GroupNode ? 52 : 42
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let node = item as? GroupNode {
            return groupCell(node, column: tableColumn?.identifier.rawValue)
        }
        if let node = item as? ItemNode {
            return itemCell(node, column: tableColumn?.identifier.rawValue)
        }
        return nil
    }

    private func groupCell(_ node: GroupNode, column: String?) -> NSView? {
        let group = node.group
        switch column {
        case "name":
            let icon = NSImageView(image: NSImage(systemSymbolName: group.symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
            icon.contentTintColor = .controlAccentColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 24)])

            let title = DashboardStyle.label(group.title, weight: .semibold)
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            var titleViews: [NSView] = [title]
            let recommended = group.recommendedItems.count
            if recommended > 0 {
                titleViews.append(ChipView(text: "\(recommended) recommended", color: .systemGreen))
            }
            let info = NSButton(image: NSImage(systemSymbolName: "info.circle",
                                               accessibilityDescription: "About \(group.title)") ?? NSImage(),
                                target: self, action: #selector(infoPressed(_:)))
            info.isBordered = false
            info.contentTintColor = .secondaryLabelColor
            info.toolTip = "คืออะไร ลบได้ไหม"
            titleViews.append(info)
            let top = NSStackView(views: titleViews)
            top.spacing = 6
            let explanation = DashboardStyle.label(group.explanation, size: 11.5, color: .secondaryLabelColor)
            explanation.lineBreakMode = .byTruncatingTail
            explanation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            explanation.toolTip = group.explanation
            let texts = NSStackView(views: [top, explanation])
            texts.orientation = .vertical
            texts.alignment = .leading
            texts.spacing = 2
            texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [icon, texts])
            row.spacing = 8
            return centeredCell(row)
        case "size":
            let label = DashboardStyle.numberLabel()
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            label.stringValue = DashboardStyle.bytes(group.size)
            return centeredCell(label, alignment: .trailing)
        case "actions":
            let recommended = group.recommendedItems
            // A permanent delete (simulators, runtimes) is never offered for a
            // whole group — only for its recommended items or one row at a time.
            let permanent = group.items.contains(where: \.isPermanent)
            let targets = recommended.isEmpty ? (permanent ? [] : group.cleanableItems) : recommended
            guard !targets.isEmpty, !targets.contains(where: { pendingIDs.contains($0.id) }) else { return nil }
            let title = recommended.isEmpty ? "Clean All…" : "Clean Recommended…"
            let button = NSButton(title: title, target: self, action: #selector(cleanGroupPressed(_:)))
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.toolTip = "\(targets.count) item\(targets.count == 1 ? "" : "s") · \(DashboardStyle.bytes(targets.reduce(0) { $0 + $1.size }))"
            return centeredCell(button, alignment: .trailing)
        default:
            return nil
        }
    }

    private func itemCell(_ node: ItemNode, column: String?) -> NSView? {
        let item = node.item
        switch column {
        case "name":
            // An app's own icon when there is one; otherwise the group's symbol,
            // tinted like a list glyph.
            let chip = item.recommendation.map { _ in ChipView(text: "Recommended", color: .systemGreen) }
            let detail = [item.detail, item.recommendation].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " · ")
            if let path = item.iconPath {
                return nameCell(icon: NSWorkspace.shared.icon(forFile: path), name: item.title, chip: chip,
                                detail: detail, detailToolTip: item.revealURL?.path)
            }
            let symbol = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage()
            return nameCell(icon: symbol.withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? symbol,
                            name: item.title, chip: chip, detail: detail, detailToolTip: item.revealURL?.path,
                            iconTint: .secondaryLabelColor)
        case "size":
            let label = DashboardStyle.numberLabel()
            label.stringValue = DashboardStyle.bytes(item.size)
            return centeredCell(label, alignment: .trailing)
        case "actions":
            var views: [NSView] = []
            if item.revealURL != nil {
                let reveal = NSButton(image: NSImage(systemSymbolName: "magnifyingglass",
                                                     accessibilityDescription: "Show in Finder") ?? NSImage(),
                                      target: self, action: #selector(revealPressed(_:)))
                reveal.isBordered = false
                reveal.contentTintColor = .secondaryLabelColor
                reveal.toolTip = "Show in Finder"
                views.append(reveal)
            }
            if pendingIDs.contains(item.id) {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.startAnimation(nil)
                views += [spinner, DashboardStyle.label("Deleting…", size: 11.5, color: .secondaryLabelColor)]
            } else if let reason = item.blockedReason {
                views.append(DashboardStyle.protectedLabel(reason: reason, text: "In use"))
            } else {
                views.append(DashboardStyle.destructiveButton(item.isPermanent ? "Delete" : "Move to Trash",
                                                              target: self, action: #selector(cleanItemPressed(_:))))
            }
            let stack = NSStackView(views: views)
            stack.spacing = 8
            return centeredCell(stack, alignment: .trailing)
        default:
            return nil
        }
    }

    // MARK: - Actions

    @objc private func cleanGroupPressed(_ sender: NSButton) {
        guard let node = outlineView.item(atRow: outlineView.row(for: sender)) as? GroupNode else { return }
        let recommended = node.group.recommendedItems
        let permanent = node.group.items.contains(where: \.isPermanent)
        let targets = recommended.isEmpty ? (permanent ? [] : node.group.cleanableItems) : recommended
        guard !targets.isEmpty else { return }
        onClean?(targets, node.group)
    }

    private var infoPopover: NSPopover?

    /// The group's guide in a popover under the ⓘ: what, what deleting costs, when.
    @objc private func infoPressed(_ sender: NSButton) {
        guard let node = outlineView.item(atRow: outlineView.row(for: sender)) as? GroupNode else { return }
        infoPopover?.close()
        let guide = node.group.guide
        let width: CGFloat = 340

        func paragraph(_ heading: String, _ text: String) -> NSView {
            let title = DashboardStyle.label(heading, size: 11, weight: .semibold, color: .secondaryLabelColor)
            let body = NSTextField(wrappingLabelWithString: text)
            body.font = .systemFont(ofSize: 12.5)
            body.preferredMaxLayoutWidth = width
            let stack = NSStackView(views: [title, body])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            return stack
        }
        let heading = DashboardStyle.label(node.group.title, size: 14, weight: .semibold)
        let content = NSStackView(views: [
            heading,
            paragraph("คืออะไร", guide.what),
            paragraph("ถ้าลบจะเป็นอย่างไร", guide.cost),
            paragraph("ควรลบเมื่อไหร่", guide.when),
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.setCustomSpacing(8, after: heading)
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: width + 32).isActive = true

        let controller = NSViewController()
        controller.view = content
        content.layoutSubtreeIfNeeded()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = content.fittingSize
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        infoPopover = popover
    }

    @objc private func cleanItemPressed(_ sender: NSButton) {
        let row = outlineView.row(for: sender)
        guard let node = outlineView.item(atRow: row) as? ItemNode,
              let group = outlineView.parent(forItem: node) as? GroupNode else { return }
        onClean?([node.item], group.group)
    }

    @objc private func revealPressed(_ sender: NSButton) {
        guard let node = outlineView.item(atRow: outlineView.row(for: sender)) as? ItemNode,
              let url = node.item.revealURL else { return }
        onReveal?(url)
    }
}
