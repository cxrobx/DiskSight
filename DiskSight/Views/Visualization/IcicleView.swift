import SwiftUI

struct IcicleView: View {
    let nodes: [FileNode]
    let onDrillDown: (FileNode) -> Void

    @State private var hoveredPath: String?
    @State private var tooltipNode: FileNode?
    @State private var tooltipPosition: CGPoint = .zero

    var body: some View {
        GeometryReader { geometry in
            let rects = IcicleLayout.layout(
                nodes: nodes,
                in: CGRect(origin: .zero, size: geometry.size)
            )

            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for item in rects {
                        let insetRect = item.rect.insetBy(dx: 0.5, dy: 0.5)
                        guard insetRect.width > 0, insetRect.height > 0 else { continue }

                        let isHovered = item.node.path == hoveredPath
                        let color = TreemapColor.forFileType(item.node.fileType)
                        let brightness = isHovered ? 0.15 : 0.0

                        let fillColor = Color(
                            red: min(color.r + brightness, 1.0),
                            green: min(color.g + brightness, 1.0),
                            blue: min(color.b + brightness, 1.0)
                        )

                        let path = Rectangle().path(in: insetRect)
                        context.fill(path, with: .color(fillColor))
                        context.stroke(path, with: .color(.black.opacity(0.2)), lineWidth: 0.5)

                        // Label
                        if insetRect.width > 40 && insetRect.height > 16 {
                            let label = item.node.name
                            let text = context.resolve(Text(label)
                                .font(.system(size: min(11, insetRect.height - 4)))
                                .foregroundStyle(.white))

                            let textRect = CGRect(
                                x: insetRect.minX + 4,
                                y: insetRect.minY + 2,
                                width: insetRect.width - 8,
                                height: insetRect.height - 4
                            )
                            context.draw(text, in: textRect)
                        }
                    }
                }

                // Hit testing
                ForEach(rects) { item in
                    Rectangle()
                        .fill(.clear)
                        .frame(width: item.rect.width, height: item.rect.height)
                        .position(x: item.rect.midX, y: item.rect.midY)
                        .onHover { isHovering in
                            hoveredPath = isHovering ? item.node.path : nil
                            if isHovering {
                                tooltipNode = item.node
                                tooltipPosition = CGPoint(x: item.rect.midX, y: item.rect.minY - 10)
                            } else if hoveredPath == nil {
                                tooltipNode = nil
                            }
                        }
                        .onTapGesture {
                            if item.node.isDirectory {
                                onDrillDown(item.node)
                            }
                        }
                }

                // Tooltip
                if let node = tooltipNode {
                    IcicleTooltip(node: node)
                        .position(x: min(max(tooltipPosition.x, 100), geometry.size.width - 100),
                                  y: max(tooltipPosition.y, 30))
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct IcicleTooltip: View {
    let node: FileNode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(node.name)
                .font(.caption.bold())
            Text(SizeFormatter.format(node.size))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if node.isDirectory {
                Text("Click to explore")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
    }
}

struct IcicleRect: Identifiable {
    let id: String
    let node: FileNode
    let rect: CGRect
    let depth: Int
}

enum IcicleLayout {
    /// Icicle plot: root at top, children stacked below, width proportional to size
    static func layout(nodes: [FileNode], in rect: CGRect) -> [IcicleRect] {
        guard !nodes.isEmpty, rect.width > 0, rect.height > 0 else { return [] }

        let totalSize = nodes.reduce(Int64(0)) { $0 + max($1.size, 0) }
        guard totalSize > 0 else { return [] }

        let rowHeight = max(rect.height / 6, 24) // Up to 6 levels visible
        var results: [IcicleRect] = []
        var x: CGFloat = rect.minX

        for node in nodes.sorted(by: { $0.size > $1.size }) {
            let fraction = CGFloat(max(node.size, 0)) / CGFloat(totalSize)
            let width = rect.width * fraction

            guard width >= 1 else { continue }

            results.append(IcicleRect(
                id: node.path,
                node: node,
                rect: CGRect(x: x, y: rect.minY, width: width, height: rowHeight),
                depth: 0
            ))

            x += width
        }

        return results
    }
}
