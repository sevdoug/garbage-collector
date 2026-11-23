import AppKit
import ScanCore
import SwiftUI

/// A treemap rectangle, already laid out.
struct TreemapCell {
    /// `nil` for the "others" block (tail of items too small to draw one by one).
    let node: FileNode?
    /// Direct child of the current folder this rectangle belongs to.
    let top: FileNode?
    let topIndex: Int
    let rect: CGRect
    let depth: Int
    /// Folder drawn as a frame, with its contents on top.
    let isFrame: Bool
    let hasHeader: Bool
    let variant: Int
}

enum TreemapLayout {
    private static let maxDepth = 3
    private static let maxChildrenPerLevel = 160
    private static let headerHeight: CGFloat = 15

    static func cells(for directory: FileNode, size: CGSize) -> [TreemapCell] {
        var cells: [TreemapCell] = []
        guard size.width > 4, size.height > 4 else { return cells }
        build(directory, in: CGRect(origin: .zero, size: size), depth: 0, top: nil, topIndex: 0, into: &cells)
        return cells
    }

    private static func build(
        _ directory: FileNode,
        in rect: CGRect,
        depth: Int,
        top: FileNode?,
        topIndex: Int,
        into cells: inout [TreemapCell]
    ) {
        // Children arrive sorted largest first; the zero-sized ones are at the end.
        let sized = directory.children.prefix { $0.size > 0 }
        let shown = sized.prefix(maxChildrenPerLevel)
        var weights = shown.map { Double($0.size) }
        let rest = sized.dropFirst(shown.count).reduce(Int64(0)) { $0 + $1.size }
        if rest > 0 { weights.append(Double(rest)) }

        let rects = Treemap.squarify(
            weights: weights,
            in: TreemapRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        )

        for (index, layout) in rects.enumerated() {
            let cellRect = CGRect(x: layout.x, y: layout.y, width: layout.width, height: layout.height)
            guard cellRect.width >= 1.5, cellRect.height >= 1.5 else { continue }
            let node = index < shown.count ? shown[shown.startIndex + index] : nil
            let cellTop = depth == 0 ? node : top
            let cellTopIndex = depth == 0 ? index : topIndex

            let canNest = node.map { $0.isDirectory && !$0.children.isEmpty } ?? false
            if let node, canNest, depth < maxDepth, min(cellRect.width, cellRect.height) >= 22 {
                let hasHeader = cellRect.height >= 46 && cellRect.width >= 64
                cells.append(TreemapCell(node: node, top: cellTop, topIndex: cellTopIndex, rect: cellRect, depth: depth, isFrame: true, hasHeader: hasHeader, variant: index))
                var inner = cellRect.insetBy(dx: 2, dy: 2)
                if hasHeader {
                    inner.origin.y += headerHeight
                    inner.size.height -= headerHeight
                }
                build(node, in: inner, depth: depth + 1, top: cellTop, topIndex: cellTopIndex, into: &cells)
            } else {
                cells.append(TreemapCell(node: node, top: cellTop, topIndex: cellTopIndex, rect: cellRect, depth: depth, isFrame: false, hasHeader: false, variant: index))
            }
        }
    }
}

/// Keeps the layout between redraws: moving the mouse redraws the canvas but does not recompute the treemap.
@MainActor
private final class TreemapCache {
    private var key: Key?
    private var cells: [TreemapCell] = []

    struct Key: Equatable {
        let directory: FileNode.ID
        let revision: Int
        let size: CGSize
    }

    func cells(for directory: FileNode, revision: Int, size: CGSize) -> [TreemapCell] {
        let newKey = Key(directory: directory.id, revision: revision, size: size)
        if newKey != key {
            key = newKey
            cells = TreemapLayout.cells(for: directory, size: size)
        }
        return cells
    }
}

struct TreemapPanel: View {
    @Environment(AppModel.self) private var model
    @State private var cache = TreemapCache()
    @State private var hovered: TreemapCell?

    var body: some View {
        let revision = model.revision
        VStack(spacing: 0) {
            GeometryReader { proxy in
                if let directory = model.current {
                    let cells = cache.cells(for: directory, revision: revision, size: proxy.size)
                    canvas(cells: cells, hovered: hovered)
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let point): hovered = cells.last { $0.rect.contains(point) }
                            case .ended: hovered = nil
                            }
                        }
                        .gesture(SpatialTapGesture(count: 2).onEnded { tap in
                            if let top = cells.last(where: { $0.rect.contains(tap.location) })?.top { model.open(top) }
                        })
                        .simultaneousGesture(SpatialTapGesture(count: 1).onEnded { tap in
                            if let top = cells.last(where: { $0.rect.contains(tap.location) })?.top {
                                model.select(top, extending: NSEvent.modifierFlags.contains(.command))
                            }
                        })
                        .overlay {
                            if cells.isEmpty {
                                ContentUnavailableView("Nothing to show", systemImage: "square.grid.2x2", description: Text("This folder takes up no space."))
                            }
                        }
                }
            }
            // What is under the mouse points at the old tree once the folder or its contents change.
            .onChange(of: revision) { hovered = nil }
            .onChange(of: model.current?.id) { hovered = nil }
            if let directory = model.current {
                HoverInfo(cell: hovered, directory: directory)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func canvas(cells: [TreemapCell], hovered: TreemapCell?) -> some View {
        let selection = model.selection
        return Canvas { context, _ in
            for cell in cells {
                let shape = Path(roundedRect: cell.rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: cell.depth == 0 ? 3 : 2)
                context.fill(shape, with: .color(Self.color(for: cell)))
                Self.drawLabel(for: cell, in: &context)
            }
            // Highlights on top of everything: selection and hovered item (always the direct child of the current folder).
            for cell in cells where cell.depth == 0 {
                guard let node = cell.node else { continue }
                let outline = Path(roundedRect: cell.rect.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 3)
                if selection.contains(node.id) {
                    context.stroke(outline, with: .color(.white), lineWidth: 3)
                    context.stroke(outline, with: .color(.accentColor), lineWidth: 2)
                } else if let hoveredTop = hovered?.top, hoveredTop === node {
                    context.stroke(outline, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                }
            }
            if let hovered, hovered.depth > 0 {
                let outline = Path(roundedRect: hovered.rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2)
                context.stroke(outline, with: .color(.white.opacity(0.85)), lineWidth: 1)
            }
        }
    }

    private static func color(for cell: TreemapCell) -> Color {
        guard let node = cell.node, !node.isAggregate else {
            return Palette.aggregate.opacity(cell.depth == 0 ? 1 : 0.75)
        }
        return cell.isFrame
            ? Palette.frame(cell.topIndex, depth: cell.depth)
            : Palette.leaf(cell.topIndex, variant: cell.variant + cell.depth)
    }

    private static func drawLabel(for cell: TreemapCell, in context: inout GraphicsContext) {
        guard let node = cell.node else { return }
        if cell.isFrame {
            guard cell.hasHeader else { return }
            let area = CGRect(x: cell.rect.minX + 5, y: cell.rect.minY + 2, width: cell.rect.width - 10, height: 14)
            var clipped = context
            clipped.clip(to: Path(area))
            let weight: Font.Weight = cell.depth == 0 ? .semibold : .regular
            clipped.draw(
                Text("\(node.name)  \(Text(Format.bytes(node.size)).foregroundStyle(.white.opacity(0.7)))")
                    .font(.system(size: 10.5, weight: weight))
                    .foregroundStyle(.white),
                at: CGPoint(x: area.minX, y: area.minY),
                anchor: .topLeading
            )
        } else if cell.rect.width >= 60, cell.rect.height >= 30 {
            let area = cell.rect.insetBy(dx: 5, dy: 4)
            var clipped = context
            clipped.clip(to: Path(area))
            let name = node.isAggregate ? String(localized: "small files") : node.name
            clipped.draw(
                Text(name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.black.opacity(0.8)),
                at: CGPoint(x: area.minX, y: area.minY),
                anchor: .topLeading
            )
            clipped.draw(
                Text(Format.bytes(node.size)).font(.system(size: 10)).foregroundStyle(.black.opacity(0.55)),
                at: CGPoint(x: area.minX, y: area.minY + 13),
                anchor: .topLeading
            )
        }
    }
}

/// Treemap footer: what is under the mouse, with its path relative to the current folder.
private struct HoverInfo: View {
    let cell: TreemapCell?
    let directory: FileNode

    var body: some View {
        HStack(spacing: 8) {
            if let cell {
                Text(description(of: cell))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                Text(Format.bytes(size(of: cell))).monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text("Hover for details · click selects · double-click opens the folder")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func size(of cell: TreemapCell) -> Int64 {
        cell.node?.size ?? 0
    }

    private func description(of cell: TreemapCell) -> String {
        guard let node = cell.node else { return String(localized: "Other smaller items") }
        // Path from the current folder to the item, without repeating the current folder.
        var names: [String] = []
        var cursor: FileNode? = node.isAggregate ? node.parent : node
        while let current = cursor, current !== directory {
            names.append(current.name)
            cursor = current.parent
        }
        var text = names.reversed().joined(separator: " › ")
        if node.isAggregate {
            text += (text.isEmpty ? "" : " › ") + String(localized: "\(Format.files(node.fileCount)) smaller than 1 MB")
        }
        return text
    }
}
