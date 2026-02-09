import SwiftUI

struct TreemapView: View {
    let nodes: [FileNode]
    let onDrillDown: (FileNode) -> Void

    @State private var hoveredId: String?
    @State private var tooltipNode: FileNode?
    @State private var tooltipPosition: CGPoint = .zero
    @State private var currentRects: [TreemapRect] = []

    var body: some View {
        GeometryReader { geometry in
            let rects = TreemapAlgorithm.layout(
                nodes: nodes,
                in: CGRect(origin: .zero, size: geometry.size)
            )

            Canvas { context, size in
                for item in rects {
                    let insetRect = item.rect.insetBy(dx: 1, dy: 1)
                    guard insetRect.width > 0, insetRect.height > 0 else { continue }

                    let isHovered = item.id == hoveredId
                    let color = item.color
                    let brightness = isHovered ? 0.15 : 0.0

                    let fillColor = Color(
                        red: min(color.r + brightness, 1.0),
                        green: min(color.g + brightness, 1.0),
                        blue: min(color.b + brightness, 1.0)
                    )

                    let path = RoundedRectangle(cornerRadius: 2)
                        .path(in: insetRect)

                    context.fill(path, with: .color(fillColor))
                    context.stroke(path, with: .color(.black.opacity(0.3)), lineWidth: 0.5)

                    // Label if rect is large enough
                    if insetRect.width > 50 && insetRect.height > 20 {
                        let label = item.node.name
                        let sizeLabel = SizeFormatter.format(item.node.size)
                        let text = context.resolve(Text("\(label)\n\(sizeLabel)")
                            .font(.system(size: min(11, insetRect.height / 3)))
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
                        hoveredId = hit.id
                        tooltipNode = hit.node
                        tooltipPosition = CGPoint(x: location.x + 15, y: location.y - 10)
                    } else {
                        hoveredId = nil
                        tooltipNode = nil
                    }
                case .ended:
                    hoveredId = nil
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

// MARK: - Shared Tooltip

struct VisualizationTooltip: View {
    let node: FileNode

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(node.name)
                .font(.caption.bold())
                .foregroundColor(.white)
            Text(node.path)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(SizeFormatter.format(node.size))
                .font(.caption.monospacedDigit())
                .foregroundColor(.white)
            if let modified = node.modifiedAt {
                Text("Modified: \(Date(timeIntervalSince1970: modified).relativeString)")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
            }
            HStack(spacing: 8) {
                if node.isDirectory {
                    Text("Click to explore")
                        .foregroundColor(.cyan)
                }
                Text("Right-click for options")
                    .foregroundColor(.white.opacity(0.5))
            }
            .font(.caption2)
        }
        .padding(10)
        .frame(maxWidth: 280)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }
}

// MARK: - Shared Context Menu

struct VisualizationContextMenu: View {
    let node: FileNode

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }

        Button {
            NSWorkspace.shared.selectFile(node.path, inFileViewerRootedAtPath: "")
        } label: {
            Label("Show in Finder", systemImage: "folder")
        }
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
