import SwiftUI

@main
struct DiskSightApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
    }
}

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            switch appState.selectedSection {
            case .overview:
                OverviewView()
            case .visualization:
                VisualizationContainer()
            case .duplicates:
                Text("Duplicates")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .staleFiles:
                Text("Stale Files")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .cache:
                Text("Cache")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
