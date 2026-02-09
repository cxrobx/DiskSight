import SwiftUI

struct SunburstView: View {
    let nodes: [FileNode]
    let onDrillDown: (FileNode) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredPath: String?
    @State private var tooltipNode: FileNode?
    @State private var tooltipPosition: CGPoint = .zero
    @State private var currentArcs: [SunburstArc] = []
    @State private var center: CGPoint = .zero
    @State private var maxRadius: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let c = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let r = min(geometry.size.width, geometry.size.height) / 2 - 20
            let arcs = SunburstLayout.layout(nodes: nodes, maxRadius: r)

            Canvas { context, size in
                for arc in arcs {
                    let path = arcPath(
                        center: c,
                        innerRadius: arc.innerRadius,
                        outerRadius: arc.outerRadius,
                        startAngle: arc.startAngle,
                        endAngle: arc.endAngle
                    )

                    let isHovered = arc.node.path == hoveredPath
                    let color = TreemapColor.forNode(arc.node)
                    let brightness = isHovered ? 0.15 : 0.0

                    let fillColor = Color(
                        red: min(color.r + brightness, 1.0),
                        green: min(color.g + brightness, 1.0),
                        blue: min(color.b + brightness, 1.0)
                    )

                    context.fill(Path(path), with: .color(fillColor))
                    let strokeColor: Color = colorScheme == .dark ? .white.opacity(0.15) : .black.opacity(0.3)
                    context.stroke(Path(path), with: .color(strokeColor), lineWidth: 0.5)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if let hit = hitTest(location: location, arcs: currentArcs, center: center) {
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
                if let hit = hitTest(location: value.location, arcs: currentArcs, center: center),
                   hit.node.isDirectory {
                    onDrillDown(hit.node)
                }
            })
            .contextMenu {
                if let node = tooltipNode {
                    VisualizationContextMenu(node: node)
                }
            }
            .overlay {
                GeometryReader { geo in
                    if let node = tooltipNode {
                        VisualizationTooltip(node: node)
                            .fixedSize()
                            .position(x: min(max(tooltipPosition.x + 70, 150), geo.size.width - 150),
                                      y: min(max(tooltipPosition.y - 60, 60), geo.size.height - 80))
                            .allowsHitTesting(false)
                    }
                }
            }
            .onChange(of: nodes.count) {
                currentArcs = arcs
                center = c
                maxRadius = r
            }
            .onAppear {
                currentArcs = arcs
                center = c
                maxRadius = r
            }
        }
    }

    private func hitTest(location: CGPoint, arcs: [SunburstArc], center: CGPoint) -> SunburstArc? {
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        var angle = atan2(dy, dx)
        // Normalize angle to match arc range
        if angle < -Double.pi / 2 {
            angle += 2 * Double.pi
        }

        return arcs.first { arc in
            distance >= arc.innerRadius && distance <= arc.outerRadius &&
            angle >= arc.startAngle && angle <= arc.endAngle
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
