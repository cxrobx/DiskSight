import SwiftUI

struct SunburstView: View {
    let nodes: [FileNode]
    let onDrillDown: (FileNode) -> Void

    @State private var hoveredPath: String?
    @State private var tooltipNode: FileNode?
    @State private var tooltipPosition: CGPoint = .zero

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let maxRadius = min(geometry.size.width, geometry.size.height) / 2 - 20
            let arcs = SunburstLayout.layout(nodes: nodes, maxRadius: maxRadius)

            ZStack {
                Canvas { context, size in
                    for arc in arcs {
                        let path = arcPath(
                            center: center,
                            innerRadius: arc.innerRadius,
                            outerRadius: arc.outerRadius,
                            startAngle: arc.startAngle,
                            endAngle: arc.endAngle
                        )

                        let isHovered = arc.node.path == hoveredPath
                        let color = TreemapColor.forFileType(arc.node.fileType)
                        let brightness = isHovered ? 0.15 : 0.0

                        let fillColor = Color(
                            red: min(color.r + brightness, 1.0),
                            green: min(color.g + brightness, 1.0),
                            blue: min(color.b + brightness, 1.0)
                        )

                        context.fill(Path(path), with: .color(fillColor))
                        context.stroke(Path(path), with: .color(.black.opacity(0.3)), lineWidth: 0.5)
                    }
                }

                // Hit testing overlays
                ForEach(arcs) { arc in
                    ArcHitArea(
                        center: center,
                        innerRadius: arc.innerRadius,
                        outerRadius: arc.outerRadius,
                        startAngle: arc.startAngle,
                        endAngle: arc.endAngle
                    )
                    .fill(.clear)
                    .onHover { isHovering in
                        hoveredPath = isHovering ? arc.node.path : nil
                        if isHovering {
                            tooltipNode = arc.node
                            let midAngle = (arc.startAngle + arc.endAngle) / 2
                            let midRadius = (arc.innerRadius + arc.outerRadius) / 2
                            tooltipPosition = CGPoint(
                                x: center.x + cos(midAngle) * midRadius,
                                y: center.y + sin(midAngle) * midRadius
                            )
                        } else if hoveredPath == nil {
                            tooltipNode = nil
                        }
                    }
                    .onTapGesture {
                        if arc.node.isDirectory {
                            onDrillDown(arc.node)
                        }
                    }
                }

                // Tooltip
                if let node = tooltipNode {
                    SunburstTooltip(node: node)
                        .position(tooltipPosition)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func arcPath(center: CGPoint, innerRadius: CGFloat, outerRadius: CGFloat, startAngle: Double, endAngle: Double) -> CGMutablePath {
        let path = CGMutablePath()
        path.addArc(center: center, radius: outerRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: endAngle, endAngle: startAngle, clockwise: true)
        path.closeSubpath()
        return path
    }
}

struct ArcHitArea: Shape {
    let center: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let startAngle: Double
    let endAngle: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: .radians(startAngle), endAngle: .radians(endAngle), clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: .radians(endAngle), endAngle: .radians(startAngle), clockwise: true)
        path.closeSubpath()
        return path
    }
}

private struct SunburstTooltip: View {
    let node: FileNode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(node.name)
                .font(.caption.bold())
            Text(SizeFormatter.format(node.size))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
    }
}

struct SunburstArc: Identifiable {
    let id: String
    let node: FileNode
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let startAngle: Double
    let endAngle: Double
    let depth: Int
}

enum SunburstLayout {
    static func layout(nodes: [FileNode], maxRadius: CGFloat, maxDepth: Int = 4) -> [SunburstArc] {
        guard !nodes.isEmpty else { return [] }

        let totalSize = nodes.reduce(Int64(0)) { $0 + max($1.size, 0) }
        guard totalSize > 0 else { return [] }

        let ringWidth = maxRadius / CGFloat(maxDepth + 1)
        var arcs: [SunburstArc] = []

        var currentAngle = -Double.pi / 2 // Start from top

        for node in nodes.sorted(by: { $0.size > $1.size }) {
            let fraction = Double(max(node.size, 0)) / Double(totalSize)
            let sweep = fraction * 2 * Double.pi

            guard sweep > 0.01 else { continue } // Skip tiny slices

            let endAngle = currentAngle + sweep

            arcs.append(SunburstArc(
                id: node.path,
                node: node,
                innerRadius: ringWidth,
                outerRadius: ringWidth * 2,
                startAngle: currentAngle,
                endAngle: endAngle,
                depth: 0
            ))

            currentAngle = endAngle
        }

        return arcs
    }
}
