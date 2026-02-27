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
            // Sidebar — always present for stable HSplitView layout.
            // Dynamically adding/removing HSplitView children after initial
            // render causes the sidebar to never appear.
            Group {
                if let rootNode = rootTreeNode {
                    FolderTreeSidebar(
                        rootNode: rootNode,
                        selectedPath: appState.vizCurrentPath,
                        onSelect: { node in
                            navigateToPath(node.fileNode.path)
                        },
                        repository: appState.fileRepository,
                        pathFilter: { appState.shouldIncludePath($0) }
                    )
                } else if case .completed = appState.scanState {
                    VStack {
                        Spacer()
                        ProgressView()
                        Text("Loading folders…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        Spacer()
                    }
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 350)
                }
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
            guard case .completed = appState.scanState else { return }
            if childNodes.isEmpty {
                isLoading = true
                await appState.loadVisualizationRoot()
                isLoading = false
            }
            if rootTreeNode == nil {
                await initTreeRoot()
            }
        }
        .onChange(of: appState.scanState) { _, newState in
            if case .completed = newState {
                Task {
                    // Use refresh (not load) — vizChildNodes may have stale data from previous scan
                    appState.vizCurrentPath = nil
                    appState.vizBreadcrumbs = []
                    await appState.refreshVisualizationData()
                    await initTreeRoot()
                }
            }
        }
        .onChange(of: childNodes.count) { _, count in
            // Safety net: if chart data loaded but tree is missing, init it
            if count > 0, rootTreeNode == nil {
                Task { await initTreeRoot() }
            }
        }
        .onChange(of: appState.dataVersion) { _, _ in
            // FSEvents batch processed — rebuild tree with fresh sizes from DB
            Task {
                await initTreeRoot()
                await syncTreeToCurrentPath()
            }
        }
        .onChange(of: appState.hideExternalDrives) { _, _ in
            Task {
                await appState.refreshVisualizationData()
                await initTreeRoot()
                await syncTreeToCurrentPath()
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
                    await appState.vizNavigateToRoot()
                    // Sync tree: collapse to root
                    if let rootTreeNode {
                        rootTreeNode.isExpanded = true
                    }
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
                            await appState.vizNavigateTo(crumb)
                            await syncTreeToCurrentPath()
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
            await appState.vizNavigateToPath(targetPath)
            await syncTreeToCurrentPath()
        }
    }

    private func drillDown(to node: FileNode) {
        guard node.isDirectory else { return }

        Task {
            await appState.vizDrillDown(to: node)
            await syncTreeToCurrentPath()
        }
    }

    // MARK: - Tree Management

    private func initTreeRoot() async {
        do {
            if let root = try appState.fileRepository.rootNodeConcurrent() {
                let node = FolderTreeNode(fileNode: root, depth: 0)
                await node.loadChildren(
                    using: appState.fileRepository,
                    pathFilter: { appState.shouldIncludePath($0) }
                )
                node.isExpanded = true
                rootTreeNode = node
            }
        } catch {
            rootTreeNode = nil
        }
    }

    private func syncTreeToCurrentPath() async {
        guard let rootTreeNode, let currentPath = appState.vizCurrentPath else { return }
        await rootTreeNode.expandTo(
            targetPath: currentPath,
            using: appState.fileRepository,
            pathFilter: { appState.shouldIncludePath($0) }
        )
    }
}

extension VisualizationMode: RawRepresentable {
    // Already conforms via String rawValue
}
