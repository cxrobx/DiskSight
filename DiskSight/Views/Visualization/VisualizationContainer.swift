import SwiftUI

enum VisualizationMode: String, CaseIterable, Identifiable {
    case treemap = "Treemap"
    case sunburst = "Sunburst"
    case icicle = "Icicle"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .treemap: return "square.grid.3x3.fill"
        case .sunburst: return "circle.circle"
        case .icicle: return "chart.bar.fill"
        }
    }
}

struct BreadcrumbItem: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
}

struct VisualizationContainer: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("visualizationMode") private var selectedMode: VisualizationMode = .treemap
    @State private var isLoading = false
    @State private var rootTreeNode: FolderTreeNode?

    private var childNodes: [FileNode] { appState.vizChildNodes }
    private var breadcrumbs: [BreadcrumbItem] { appState.vizBreadcrumbs }

    var body: some View {
        HSplitView {
            // Folder tree sidebar
            if let rootNode = rootTreeNode {
                FolderTreeSidebar(
                    rootNode: rootNode,
                    selectedPath: appState.vizCurrentPath,
                    onSelect: { node in
                        navigateToPath(node.fileNode.path)
                    },
                    repository: appState.fileRepository
                )
            }

            // Main chart area
            VStack(spacing: 0) {
                // Toolbar with mode switcher and breadcrumbs
                toolbarBar
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.bar)

                Divider()

                // Visualization content
                if isLoading {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if childNodes.isEmpty {
                    emptyState
                } else {
                    visualizationContent
                }
            }
        }
        .task {
            if childNodes.isEmpty, case .completed = appState.scanState {
                isLoading = true
                await appState.loadVisualizationRoot()
                await initTreeRoot()
                isLoading = false
            }
        }
        .onChange(of: appState.scanState) { _, newState in
            if case .completed = newState {
                Task {
                    isLoading = true
                    appState.vizChildNodes = []
                    await appState.loadVisualizationRoot()
                    await initTreeRoot()
                    isLoading = false
                }
            }
        }
    }

    @ViewBuilder
    private var visualizationContent: some View {
        switch selectedMode {
        case .treemap:
            TreemapView(nodes: childNodes) { node in
                drillDown(to: node)
            }
        case .sunburst:
            SunburstView(nodes: childNodes) { node in
                drillDown(to: node)
            }
        case .icicle:
            IcicleView(nodes: childNodes) { node in
                drillDown(to: node)
            }
        }
    }

    private var toolbarBar: some View {
        HStack(spacing: 8) {
            // Mode switcher
            Picker("Mode", selection: $selectedMode) {
                ForEach(VisualizationMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.icon)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            Divider()
                .frame(height: 16)

            // Breadcrumbs
            breadcrumbBar

            Spacer()

            Text("\(childNodes.count) items")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            Button {
                Task {
                    isLoading = true
                    await appState.vizNavigateToRoot()
                    // Sync tree: collapse to root
                    if let rootTreeNode {
                        rootTreeNode.isExpanded = true
                    }
                    isLoading = false
                }
            } label: {
                Image(systemName: "house.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(breadcrumbs.isEmpty)

            if !breadcrumbs.isEmpty {
                ForEach(breadcrumbs) { crumb in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Button(crumb.name) {
                        Task {
                            isLoading = true
                            await appState.vizNavigateTo(crumb)
                            // Sync tree to breadcrumb target
                            await syncTreeToCurrentPath()
                            isLoading = false
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .lineLimit(1)
                }
            } else {
                Text("Root")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.3x3.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Data to Visualize")
                .font(.title3)
            Text("Run a scan first to see disk usage visualization")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Navigation

    private func navigateToPath(_ targetPath: String) {
        Task {
            isLoading = true
            await appState.vizNavigateToPath(targetPath)
            // Tree is already at the right place since user clicked in it
            // But expand the node to show its children in the tree too
            await syncTreeToCurrentPath()
            isLoading = false
        }
    }

    private func drillDown(to node: FileNode) {
        guard node.isDirectory else { return }

        Task {
            isLoading = true
            await appState.vizDrillDown(to: node)
            // Chart→tree sync: expand tree to the drilled-down path
            await syncTreeToCurrentPath()
            isLoading = false
        }
    }

    // MARK: - Tree Management

    private func initTreeRoot() async {
        do {
            if let root = try await appState.fileRepository.rootNode() {
                let node = FolderTreeNode(fileNode: root, depth: 0)
                await node.loadChildren(using: appState.fileRepository)
                node.isExpanded = true
                rootTreeNode = node
            }
        } catch {
            rootTreeNode = nil
        }
    }

    private func syncTreeToCurrentPath() async {
        guard let rootTreeNode, let currentPath = appState.vizCurrentPath else { return }
        await rootTreeNode.expandTo(targetPath: currentPath, using: appState.fileRepository)
    }
}

extension VisualizationMode: RawRepresentable {
    // Already conforms via String rawValue
}
