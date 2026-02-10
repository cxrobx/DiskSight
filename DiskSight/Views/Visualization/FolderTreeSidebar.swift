import SwiftUI

struct FolderTreeSidebar: View {
    @ObservedObject var rootNode: FolderTreeNode
    var selectedPath: String?
    var onSelect: (FolderTreeNode) -> Void
    let repository: FileRepository

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Folders")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollViewReader { proxy in
                List {
                    FolderTreeRow(
                        node: rootNode,
                        selectedPath: selectedPath,
                        onSelect: onSelect,
                        repository: repository
                    )
                }
                .listStyle(.sidebar)
                .onChange(of: selectedPath) { newPath in
                    if let path = newPath {
                        withAnimation {
                            proxy.scrollTo(path, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 350)
    }
}

struct FolderTreeRow: View {
    @ObservedObject var node: FolderTreeNode
    var selectedPath: String?
    var onSelect: (FolderTreeNode) -> Void
    let repository: FileRepository

    var body: some View {
        DisclosureGroup(
            isExpanded: $node.isExpanded
        ) {
            if let children = node.children {
                if children.isEmpty {
                    Text("No subfolders")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                } else {
                    ForEach(children) { child in
                        FolderTreeRow(
                            node: child,
                            selectedPath: selectedPath,
                            onSelect: onSelect,
                            repository: repository
                        )
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 4)
            }
        } label: {
            FolderTreeLabel(
                node: node,
                isSelected: selectedPath == node.fileNode.path
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect(node)
            }
            .contextMenu {
                VisualizationContextMenu(node: node.fileNode)
            }
        }
        .id(node.fileNode.path)
        .onChange(of: node.isExpanded) { expanded in
            if expanded {
                Task {
                    await node.loadChildren(using: repository)
                }
            }
        }
    }
}

struct FolderTreeLabel: View {
    let node: FolderTreeNode
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.caption)
                .foregroundStyle(isSelected ? Color(hex: 0x0a84ff) : .secondary)

            Text(node.fileNode.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(SizeFormatter.format(node.fileNode.size))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color(hex: 0x0a84ff).opacity(0.15) : Color.clear)
        )
    }
}

// Color hex initializer (if not already available)
private extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
