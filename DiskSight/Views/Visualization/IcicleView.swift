import SwiftUI

struct IcicleView: View {
    let nodes: [FileNode]
    let onDrillDown: (FileNode) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredPath: String?
    @State private var tooltipNode: FileNode?
    @State private var tooltipPosition: CGPoint = .zero
    @State private var currentRects: [IcicleRect] = []

    var body: some View {
        GeometryReader { geometry in
            let rects = IcicleLayout.layout(
                nodes: nodes,
                in: CGRect(origin: .zero, size: geometry.size)
            )

            Canvas { context, size in
                for item in rects {
                    let insetRect = item.rect.insetBy(dx: 0.5, dy: 0.5)
                    guard insetRect.width > 0, insetRect.height > 0 else { continue }

                    let isHovered = item.node.path == hoveredPath
                    let color = TreemapColor.forNode(item.node)
                    let brightness = isHovered ? 0.15 : 0.0

                    let fillColor = Color(
                        red: min(color.r + brightness, 1.0),
                        green: min(color.g + brightness, 1.0),
                        blue: min(color.b + brightness, 1.0)
                    )

                    let path = Rectangle().path(in: insetRect)
                    context.fill(path, with: .color(fillColor))
                    let strokeColor: Color = colorScheme == .dark ? .white.opacity(0.15) : .black.opacity(0.2)
                    context.stroke(path, with: .color(strokeColor), lineWidth: 0.5)

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
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if let hit = currentRects.first(where: { $0.rect.contains(location) }) {
                        hoveredPath = hit.node.path
                        tooltipNode = hit.node
                        tooltipPosition = CGPoint(x: location.x + 15, y: location.y - 10)
                    } else {
                        hoveredPath = nil
                        tooltipNode = nil
                    }
                case .ended:
                    hoveredPath = nil
                    tooltipNode = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                if let hit = currentRects.first(where: { $0.rect.contains(value.location) }),
                   hit.node.isDirectory {
                    onDrillDown(hit.node)
                }
            })
            .contextMenu {
                if let node = tooltipNode {
                    VisualizationContextMenu(node: node)
                }
            }
            .overlay(alignment: .topLeading) {
                if let node = tooltipNode {
                    VisualizationTooltip(node: node)
                        .fixedSize()
                        .position(x: min(max(tooltipPosition.x + 70, 150), geometry.size.width - 150),
                                  y: min(max(tooltipPosition.y - 60, 60), geometry.size.height - 80))
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: nodes.count) {
                currentRects = rects
            }
            .onAppear {
                currentRects = rects
            }
        }
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
