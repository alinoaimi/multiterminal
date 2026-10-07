import Foundation

enum SplitAxis: String, Codable { case horizontal, vertical }
enum DockEdge: String, Codable, CaseIterable { case left, right, top, bottom
    var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    var insertsFirst: Bool { self == .left || self == .top }
}

struct PaneGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var paneIDs: [UUID]
    var selectedPaneID: UUID

    init(id: UUID = UUID(), paneIDs: [UUID], selectedPaneID: UUID? = nil) {
        self.id = id
        self.paneIDs = paneIDs
        self.selectedPaneID = selectedPaneID ?? paneIDs[0]
    }
}

struct PaneSplit: Codable, Equatable, Identifiable {
    var id = UUID()
    var axis: SplitAxis
    var firstPercent: Double = 50
    var first: WorkspaceLayout
    var second: WorkspaceLayout
}

/// Percentages are relative to each split's available content area, excluding
/// its divider. Display geometry is derived from this tree, never persisted.
indirect enum WorkspaceLayout: Codable, Equatable, Identifiable {
    case group(PaneGroup)
    case split(PaneSplit)

    var id: UUID {
        switch self { case let .group(g): g.id; case let .split(s): s.id }
    }

    var groups: [PaneGroup] {
        switch self { case let .group(g): [g]; case let .split(s): s.first.groups + s.second.groups }
    }

    var paneIDs: [UUID] { groups.flatMap(\.paneIDs) }
    func group(containing paneID: UUID) -> PaneGroup? { groups.first { $0.paneIDs.contains(paneID) } }

    func isValid(paneIDs expected: [UUID]) -> Bool {
        var nodeIDs = Set<UUID>()
        func check(_ node: WorkspaceLayout) -> Bool {
            guard nodeIDs.insert(node.id).inserted else { return false }
            switch node {
            case let .group(g): return !g.paneIDs.isEmpty && g.paneIDs.contains(g.selectedPaneID)
            case let .split(s):
                return s.firstPercent.isFinite && s.firstPercent > 0 && s.firstPercent < 100
                    && check(s.first) && check(s.second)
            }
        }
        return check(self) && paneIDs.count == expected.count && Set(paneIDs) == Set(expected)
    }

    func replacing(id target: UUID, with replacement: WorkspaceLayout) -> WorkspaceLayout {
        if id == target { return replacement }
        guard case var .split(s) = self else { return self }
        s.first = s.first.replacing(id: target, with: replacement)
        s.second = s.second.replacing(id: target, with: replacement)
        return .split(s)
    }

    func updatingGroup(_ id: UUID, _ transform: (inout PaneGroup) -> Void) -> WorkspaceLayout {
        guard var group = groups.first(where: { $0.id == id }) else { return self }
        transform(&group)
        return replacing(id: id, with: .group(group))
    }

    func settingPercent(_ percent: Double, splitID: UUID) -> WorkspaceLayout {
        guard percent.isFinite, percent > 0, percent < 100, case var .split(s) = self else { return self }
        if s.id == splitID { s.firstPercent = percent }
        else {
            s.first = s.first.settingPercent(percent, splitID: splitID)
            s.second = s.second.settingPercent(percent, splitID: splitID)
        }
        return .split(s)
    }

    func removing(paneIDs removed: Set<UUID>) -> WorkspaceLayout? {
        switch self {
        case var .group(g):
            let oldIndex = g.paneIDs.firstIndex(of: g.selectedPaneID) ?? 0
            g.paneIDs.removeAll { removed.contains($0) }
            guard !g.paneIDs.isEmpty else { return nil }
            if !g.paneIDs
                .contains(g.selectedPaneID) { g.selectedPaneID = g.paneIDs[min(oldIndex, g.paneIDs.count - 1)] }
            return .group(g)
        case var .split(s):
            let first = s.first.removing(paneIDs: removed), second = s.second.removing(paneIDs: removed)
            guard let first else { return second }
            guard let second else { return first }
            s.first = first; s.second = second
            return .split(s)
        }
    }

    func docking(_ incoming: WorkspaceLayout, at edge: DockEdge) -> WorkspaceLayout {
        .split(PaneSplit(axis: edge.axis, first: edge.insertsFirst ? incoming : self,
                         second: edge.insertsFirst ? self : incoming))
    }

    static func legacyGrid(paneIDs: [UUID]) -> WorkspaceLayout? {
        guard !paneIDs.isEmpty else { return nil }
        let columns = Int(ceil(sqrt(Double(paneIDs.count))))
        var rows: [WorkspaceLayout] = []
        for start in stride(from: 0, to: paneIDs.count, by: columns) {
            rows.append(equalSplits(Array(paneIDs[start ..< min(start + columns, paneIDs.count)]).map {
                .group(PaneGroup(paneIDs: [$0]))
            }, axis: .horizontal))
        }
        return equalSplits(rows, axis: .vertical)
    }

    private static func equalSplits(_ nodes: [WorkspaceLayout], axis: SplitAxis) -> WorkspaceLayout {
        guard nodes.count > 1 else { return nodes[0] }
        return .split(PaneSplit(axis: axis, firstPercent: 100 / Double(nodes.count), first: nodes[0],
                                second: equalSplits(Array(nodes.dropFirst()), axis: axis)))
    }
}
