import AppKit
import SwiftUI

struct WorkspaceLayoutView: NSViewRepresentable {
    let workspace: Workspace
    let store: WorkspaceStore
    let sessions: TerminalSessionRegistry
    let contents: PaneContentRegistry
    func makeNSView(context: Context) -> WorkspaceLayoutHost {
        let host = WorkspaceLayoutHost(); host.update(
            workspace,
            store: store,
            sessions: sessions,
            contents: contents
        ); return host
    }

    func updateNSView(_ host: WorkspaceLayoutHost, context: Context) {
        host.update(workspace, store: store, sessions: sessions, contents: contents)
    }
}

final class WorkspaceLayoutHost: NSView {
    private(set) var workspace: Workspace?
    private(set) weak var store: WorkspaceStore?
    private var root: NSView?
    private(set) var groups: [UUID: PaneGroupView] = [:]
    private var splits: [UUID: PercentageSplitView] = [:]
    private var empty: NSHostingView<AnyView>?
    private lazy var overlay = WorkspaceDockOverlay(host: self)
    private var focusMonitor: Any?
    override var isFlipped: Bool { true }

    func update(
        _ workspace: Workspace,
        store: WorkspaceStore,
        sessions: TerminalSessionRegistry,
        contents: PaneContentRegistry
    ) {
        self.workspace = workspace; self.store = store
        contents.synchronize(workspace)
        var seenGroups = Set<UUID>(), seenSplits = Set<UUID>()
        func build(_ node: WorkspaceLayout) -> NSView {
            switch node {
            case let .group(group):
                seenGroups.insert(group.id)
                let view = groups[group.id] ?? PaneGroupView(host: self, groupID: group.id)
                groups[group.id] = view
                view.update(group, workspace: workspace, store: store, sessions: sessions, contents: contents)
                return view
            case let .split(split):
                seenSplits.insert(split.id)
                let view = splits[split.id] ?? PercentageSplitView()
                splits[split.id] = view
                view.isVertical = split.axis == .horizontal
                view.percent = split.firstPercent
                view.completedResize = { [weak store] percent in store?.setSplitPercent(
                    percent,
                    splitID: split.id,
                    in: workspace.id
                ) }
                view.setChildren(build(split.first), build(split.second))
                return view
            }
        }
        let next: NSView
        if let layout = workspace.layout { next = build(layout) }
        else {
            if empty == nil {
                empty = NSHostingView(rootView: AnyView(VStack(spacing: 12) {
                    Image(systemName: "rectangle.split.2x2").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Add a pane to this workspace")
                    PaneTypeMenu(workspaceID: workspace.id).environmentObject(store)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)))
            }
            next = empty!
        }
        if root !== next {
            if root?.superview === self { root?.removeFromSuperview() }
            root = next; next.removeFromSuperview(); addSubview(next)
        }
        groups = groups.filter { seenGroups.contains($0.key) }
        splits = splits.filter { seenSplits.contains($0.key) }
        if overlay.superview == nil { addSubview(overlay); overlay.isHidden = true }
        else { addSubview(overlay, positioned: .above, relativeTo: nil) }
        needsLayout = true
    }

    override func layout() {
        super.layout(); root?.frame = bounds; overlay.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let focusMonitor { NSEvent.removeMonitor(focusMonitor); self.focusMonitor = nil }
        if window != nil {
            focusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                guard let self, event.window === window, let workspace else { return event }
                let point: NSPoint = if event.type == .keyDown, let view = window?.firstResponder as? NSView {
                    convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
                } else { convert(event.locationInWindow, from: nil) }
                if let group = groups.values.first(where: { $0.convert($0.bounds, to: self).contains(point) }),
                   let selected = group.group?.selectedPaneID, workspace.focusedGroupID != group.groupID
                {
                    // Defer publication until the receiving control has handled its event.
                    DispatchQueue.main.async { [weak self] in self?.store?.selectPane(selected, in: workspace.id) }
                }
                return event
            }
        }
    }

    func beginDocking() { overlay.frame = bounds; overlay.isHidden = false; overlay.target = nil }
    func endDocking() { overlay.isHidden = true; overlay.target = nil }
    func updateDocking(at point: NSPoint, payload: PaneDragPayload) {
        _ = overlay.updateTarget(at: point, payload: payload)
        overlay.displayIfNeeded()
    }

    func finishDocking(at point: NSPoint, payload: PaneDragPayload) {
        if overlay.updateTarget(at: point, payload: payload) { _ = overlay.performDrop(payload) }
        endDocking()
    }

    func close(_ paneID: UUID) {
        guard let workspace else { return }; store?.removePane(id: paneID, from: workspace.id)
    }

    func menu(for paneID: UUID?, groupID: UUID) -> NSMenu {
        let menu = NSMenu()
        guard let workspace, let store else { return menu }
        for kind in PaneKind.allCases {
            menu.addAction("Add \(kind.title)", symbol: kind.symbol) {
                PaneCreation.add(kind, workspaceID: workspace.id, groupID: groupID, store: store)
            }
        }
        menu.addItem(.separator())
        for edge in DockEdge.allCases {
            menu.addAction("Move \(paneID == nil ? "Group" : "Pane") to Workspace \(edge.rawValue.capitalized)") {
                store.dock(paneID: paneID, groupID: paneID == nil ? groupID : nil, in: workspace.id, edge: edge)
            }
        }
        for edge in DockEdge.allCases {
            let submenu = NSMenu(title: "Split \(edge.rawValue.capitalized)")
            for kind in PaneKind.allCases {
                submenu.addAction("New \(kind.title)", symbol: kind.symbol) {
                    PaneCreation.add(kind, workspaceID: workspace.id, groupID: groupID, edge: edge, store: store)
                }
            }
            if let paneID, (workspace.layout?.group(containing: paneID)?.paneIDs.count ?? 0) > 1 {
                submenu.addItem(.separator())
                submenu.addAction("Move This Tab to New Split") {
                    store.dock(paneID: paneID, in: workspace.id, targetGroupID: groupID, edge: edge)
                }
            }
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu; menu.addItem(item)
        }
        for other in workspace.layout?.groups.filter({ $0.id != groupID }) ?? [] {
            let name = workspace.panes.first(where: { $0.id == other.selectedPaneID })?.title ?? "Group"
            menu.addAction("Move \(paneID == nil ? "Group" : "Pane") into \(name)") {
                store.dock(
                    paneID: paneID,
                    groupID: paneID == nil ? groupID : nil,
                    in: workspace.id,
                    targetGroupID: other.id
                )
            }
        }
        if let paneID { menu.addItem(.separator()); menu.addAction("Close Pane") { [weak self] in
            self?.close(paneID)
        } }
        return menu
    }
}

/// NSSplitView handles divider tracking; proportional geometry is reapplied
/// only outside a drag. Window resizes never call completedResize.
final class PercentageSplitView: NSSplitView, NSSplitViewDelegate {
    var percent = 50.0 { didSet { if percent != oldValue { needsLayout = true } } }
    var completedResize: ((Double) -> Void)?
    private var dragging = false
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); dividerStyle = .thin; delegate = self
    }

    required init?(coder: NSCoder) { nil }
    func setChildren(_ first: NSView, _ second: NSView) {
        guard subviews.count != 2 || subviews[0] !== first || subviews[1] !== second else { return }
        subviews.forEach { $0.removeFromSuperview() }
        first.removeFromSuperview(); second.removeFromSuperview(); addSubview(first); addSubview(second)
        needsLayout = true
    }

    static func firstLength(available: CGFloat, percent: Double, minimumFirst: CGFloat,
                            minimumSecond: CGFloat) -> CGFloat
    {
        let proposed = max(0, available) * percent / 100
        if available >= minimumFirst +
            minimumSecond { return min(max(proposed, minimumFirst), available - minimumSecond) }
        return proposed
    }

    private func minimum(_ view: NSView, alongHorizontal: Bool) -> CGFloat {
        guard let split = view as? PercentageSplitView,
              split.subviews.count == 2 else { return alongHorizontal ? 180 : 130 }
        let sizes = split.subviews.map { minimum($0, alongHorizontal: alongHorizontal) }
        return split.isVertical == alongHorizontal ? sizes[0] + sizes[1] + split.dividerThickness : max(
            sizes[0],
            sizes[1]
        )
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        if dragging { super.resizeSubviews(withOldSize: oldSize) } else { applyPercentage() }
    }

    override func layout() { super.layout(); if !dragging { applyPercentage() } }
    private func applyPercentage() {
        guard subviews.count == 2, bounds.width > 0, bounds.height > 0 else { return }
        let available = max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
        let first = Self.firstLength(available: available, percent: percent,
                                     minimumFirst: minimum(subviews[0], alongHorizontal: isVertical),
                                     minimumSecond: minimum(
                                         subviews[1],
                                         alongHorizontal: isVertical
                                     ))
        if isVertical {
            subviews[0].frame = NSRect(x: 0, y: 0, width: first, height: bounds.height)
            subviews[1].frame = NSRect(
                x: first + dividerThickness,
                y: 0,
                width: max(0, available - first),
                height: bounds.height
            )
        } else {
            subviews[0].frame = NSRect(x: 0, y: 0, width: bounds.width, height: first)
            subviews[1].frame = NSRect(
                x: 0,
                y: first + dividerThickness,
                width: bounds.width,
                height: max(0, available - first)
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard subviews.count == 2 else { super.mouseDown(with: event); return }
        let before = subviews[0].frame.size
        dragging = true; super.mouseDown(with: event); dragging = false
        let available = (isVertical ? bounds.width : bounds.height) - dividerThickness
        let length = isVertical ? subviews[0].frame.width : subviews[0].frame.height
        guard available > 0, before != subviews[0].frame.size else { return }
        percent = min(99.9, max(0.1, length / available * 100))
        completedResize?(percent)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard subviews.count == 2 else { return proposedMinimumPosition }
        let available = max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
        return min(minimum(subviews[0], alongHorizontal: isVertical), available / 2)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard subviews.count == 2 else { return proposedMaximumPosition }
        let available = max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
        return available - min(minimum(subviews[1], alongHorizontal: isVertical), available / 2)
    }
}

final class PaneGroupView: NSView {
    let groupID: UUID
    private weak var host: WorkspaceLayoutHost?
    private(set) var group: PaneGroup?
    private let header = NSView()
    private let tabScroll = NSScrollView()
    private let tabStrip = NSView()
    private let body = NSView()
    private var tabs: [UUID: PaneDragButton] = [:]
    private var grip: PaneDragButton!
    private var add: ActionButton!
    private var actions: ActionButton!
    private var activeView: NSView?
    override var isFlipped: Bool { true }
    init(host: WorkspaceLayoutHost, groupID: UUID) {
        self.host = host; self.groupID = groupID
        super.init(frame: .zero)
        wantsLayer = true; layer?.borderWidth = 1; layer?.cornerRadius = 5
        header.wantsLayer = true; header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        tabScroll.documentView = tabStrip; tabScroll.hasHorizontalScroller = true; tabScroll
            .autohidesScrollers = true; tabScroll.drawsBackground = false
        grip = PaneDragButton(title: "Move Group", symbol: "line.3.horizontal", host: host)
        grip.title = ""; grip.toolTip = "Drag to move the whole group"; grip.setAccessibilityLabel("Move Group")
        add = ActionButton("Add Pane", symbol: "plus") { [weak self] in self?.showMenu(onlyAdd: true) }
        actions = ActionButton("Group Actions", symbol: "ellipsis") { [weak self] in self?.showMenu(onlyAdd: false) }
        [grip!, tabScroll, add!, actions!].forEach { header.addSubview($0) }
        addSubview(header); addSubview(body)
    }

    required init?(coder: NSCoder) { nil }
    func update(
        _ group: PaneGroup,
        workspace: Workspace,
        store: WorkspaceStore,
        sessions: TerminalSessionRegistry,
        contents: PaneContentRegistry
    ) {
        self.group = group
        layer?
            .borderColor = (workspace.focusedGroupID == group.id ? NSColor.controlAccentColor : NSColor.separatorColor)
            .cgColor
        grip.payload = PaneDragPayload(workspaceID: workspace.id, paneID: nil, groupID: group.id)
        grip.menu = host?.menu(for: nil, groupID: group.id)
        for id in tabs.keys
            .filter({ !group.paneIDs.contains($0) })
        {
            tabs.removeValue(forKey: id)?.removeFromSuperview()
        }
        for id in group.paneIDs {
            guard let pane = workspace.panes.first(where: { $0.id == id }), let host else { continue }
            let button = tabs[id] ?? PaneDragButton(title: pane.title, symbol: pane.kind.symbol, host: host)
            button.title = pane.title; button.image = NSImage(
                systemSymbolName: pane.kind.symbol,
                accessibilityDescription: pane.kind.title
            )
            button.state = group.selectedPaneID == id ? .on : .off
            button.contentTintColor = group.selectedPaneID == id ? .controlAccentColor : .labelColor
            button.toolTip = pane.kind == .terminal ? pane.directoryPath : pane.title
            button.setAccessibilityLabel("\(pane.kind.title): \(pane.title)")
            button.payload = PaneDragPayload(workspaceID: workspace.id, paneID: id, groupID: group.id)
            button.clicked = { store.selectPane(id, in: workspace.id) }
            button.menu = host.menu(for: id, groupID: group.id)
            if tabs[id] == nil { tabStrip.addSubview(button); tabs[id] = button }
        }
        if let pane = workspace.panes.first(where: { $0.id == group.selectedPaneID }) {
            let view = contents.view(for: pane, workspaceID: workspace.id, store: store, sessions: sessions)
            if activeView !== view {
                if activeView?.superview === body { activeView?.removeFromSuperview() }
                view.removeFromSuperview(); body.addSubview(view); activeView = view
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 1, y: 1, width: max(0, bounds.width - 2), height: 34)
        body.frame = NSRect(x: 1, y: 35, width: max(0, bounds.width - 2), height: max(0, bounds.height - 36))
        activeView?.frame = body.bounds
        grip.frame = NSRect(x: 4, y: 5, width: 20, height: 24)
        add.frame = NSRect(x: max(24, header.bounds.width - 54), y: 5, width: 24, height: 24)
        actions.frame = NSRect(x: max(48, header.bounds.width - 28), y: 5, width: 24, height: 24)
        tabScroll.frame = NSRect(x: 28, y: 1, width: max(0, header.bounds.width - 86), height: 32)
        var x: CGFloat = 0
        for id in group?.paneIDs ?? [] {
            guard let tab = tabs[id] else { continue }
            let width = min(180, max(100, tab.intrinsicContentSize.width + 18))
            tab.frame = NSRect(x: x, y: 2, width: width, height: 28); x += width + 3
        }
        tabStrip.frame = NSRect(x: 0, y: 0, width: max(x, tabScroll.contentSize.width), height: 30)
        host?.store?.groupSizes[groupID] = bounds.size
    }

    func tabBefore(pointInHost: NSPoint) -> UUID? {
        guard let host else { return nil }
        let point = tabStrip.convert(pointInHost, from: host)
        return group?.paneIDs.first { id in tabs[id].map { point.x < $0.frame.midX } ?? false }
    }

    private func showMenu(onlyAdd: Bool) {
        guard let host else { return }
        let menu = host.menu(for: onlyAdd ? nil : group?.selectedPaneID, groupID: groupID)
        if onlyAdd { while menu.items.count > PaneKind.allCases.count {
            menu.removeItem(at: menu.items.count - 1)
        } }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.width - 60, y: 34), in: self)
    }
}

struct PaneDragPayload: Codable {
    let workspaceID: UUID
    let paneID: UUID?
    let groupID: UUID
    static let pasteboardType = NSPasteboard.PasteboardType("com.multiterminal.workspace-pane")
}

final class PaneDragButton: NSButton {
    var payload: PaneDragPayload?
    var clicked: (() -> Void)?
    private weak var host: WorkspaceLayoutHost?
    init(title: String, symbol: String, host: WorkspaceLayoutHost) {
        self.host = host; super.init(frame: .zero)
        self.title = title; image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        imagePosition = .imageLeading; bezelStyle = .inline; isBordered = false
        font = .systemFont(ofSize: 11, weight: .medium); lineBreakMode = .byTruncatingTail
        target = self; action = #selector(activate)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func activate() { clicked?() }
    override func mouseDown(with event: NSEvent) {
        guard let window, let payload else { super.mouseDown(with: event); return }
        var isDragging = false
        defer {
            if isDragging { host?.endDocking(); NSCursor.pop() }
        }
        // All docking is local to this workspace. Track the gesture directly,
        // so embedded web/terminal views cannot take over the destination.
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged, .keyDown]) {
            if next.type == .keyDown {
                if next.keyCode == 53 { return }
                continue
            }
            if next.type == .leftMouseUp {
                if isDragging { host?.finishDocking(at: next.locationInWindow, payload: payload) }
                else { clicked?() }
                return
            }
            let delta = next.locationInWindow - event.locationInWindow
            if !isDragging {
                if hypot(delta.x, delta.y) < 4 { continue }
                isDragging = true; host?.beginDocking(); NSCursor.closedHand.push()
            }
            host?.updateDocking(at: next.locationInWindow, payload: payload)
        }
    }
}

private extension NSPoint {
    static func - (lhs: NSPoint, rhs: NSPoint) -> NSPoint { NSPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
}

struct DockTarget {
    var groupID: UUID?
    var edge: DockEdge?
    var beforePaneID: UUID?
    var frame: NSRect
}

final class WorkspaceDockOverlay: NSView {
    private weak var host: WorkspaceLayoutHost?
    var target: DockTarget? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    init(host: WorkspaceLayoutHost) {
        self.host = host; super.init(frame: .zero)
        registerForDraggedTypes([PaneDragPayload.pasteboardType])
    }

    required init?(coder: NSCoder) { nil }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let data = sender.draggingPasteboard.data(forType: PaneDragPayload.pasteboardType),
              let payload = try? JSONDecoder().decode(PaneDragPayload.self, from: data) else { return [] }
        return updateTarget(at: sender.draggingLocation, payload: payload) ? .move : []
    }

    func updateTarget(at windowPoint: NSPoint, payload: PaneDragPayload) -> Bool {
        guard let host, payload.workspaceID == host.workspace?.id else { target = nil; return false }
        let p = convert(windowPoint, from: nil)
        guard bounds.contains(p) else { target = nil; return false }
        var edge: DockEdge?
        if p.x < 22 { edge = .left } else if p.x > bounds.width - 22 { edge = .right }
        else if p.y < 18 { edge = .top } else if p.y > bounds.height - 18 { edge = .bottom }
        if let edge { target = DockTarget(edge: edge, frame: half(bounds, edge)); return true }
        guard let group = host.groups.values.first(where: { $0.convert($0.bounds, to: self).contains(p) })
        else { target = nil; return false }
        let frame = group.convert(group.bounds, to: self)
        let local = NSPoint(x: p.x - frame.minX, y: p.y - frame.minY)
        if local.y < 35 {
            target = DockTarget(
                groupID: group.groupID,
                beforePaneID: group.tabBefore(pointInHost: p),
                frame: NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: 34)
            )
        } else {
            if local.x < frame.width * 0.23 { edge = .left } else if local.x > frame.width * 0.77 { edge = .right }
            else if local.y < frame.height * 0.27 { edge = .top }
            else if local.y > frame.height * 0.77 { edge = .bottom }
            target = DockTarget(groupID: group.groupID, edge: edge, frame: edge.map { half(frame, $0) } ?? frame)
        }
        return true
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { target = nil }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        draggingUpdated(sender) == .move && target != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let data = sender.draggingPasteboard.data(forType: PaneDragPayload.pasteboardType),
              let payload = try? JSONDecoder().decode(PaneDragPayload.self, from: data) else { return false }
        return performDrop(payload)
    }

    func performDrop(_ payload: PaneDragPayload) -> Bool {
        guard let host, let target, payload.workspaceID == host.workspace?.id else { return false }
        host.store?.dock(
            paneID: payload.paneID,
            groupID: payload.paneID == nil ? payload.groupID : nil,
            in: payload.workspaceID,
            targetGroupID: target.groupID,
            edge: target.edge,
            beforePaneID: target.beforePaneID
        )
        host.endDocking(); return true
    }

    private func half(_ frame: NSRect, _ edge: DockEdge) -> NSRect {
        switch edge {
        case .left: NSRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: NSRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top: NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom: NSRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let target else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        let path = NSBezierPath(roundedRect: target.frame.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6)
        path.fill(); NSColor.controlAccentColor.setStroke(); path.lineWidth = 2; path.stroke()
    }
}

private final class ClosureMenuItem: NSMenuItem {
    let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler; super.init(title: title, action: #selector(invoke), keyEquivalent: ""); target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not used") }
    @objc private func invoke() { handler() }
}

private extension NSMenu {
    func addAction(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        let item = ClosureMenuItem(title: title, handler: handler)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        addItem(item)
    }
}
