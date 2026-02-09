import SwiftUI

@main
struct DiskSightApp: App {
    @StateObject private var appState = AppState()
    @State private var showOnboarding = false
    @State private var showSearch = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding) { url in
                        hasCompletedOnboarding = true
                        appState.scanRootPath = url
                        appState.startScan(at: url)
                    }
                }
                .sheet(isPresented: $showSearch) {
                    SearchView()
                        .environmentObject(appState)
                        .frame(width: 600, height: 500)
                }
                .onAppear {
                    if !hasCompletedOnboarding && appState.lastScanSession == nil {
                        showOnboarding = true
                    }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Overview") {
                    appState.selectedSection = .overview
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Visualization") {
                    appState.selectedSection = .visualization
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("Duplicates") {
                    appState.selectedSection = .duplicates
                }
                .keyboardShortcut("3", modifiers: .command)

                Button("Stale Files") {
                    appState.selectedSection = .staleFiles
                }
                .keyboardShortcut("4", modifiers: .command)

                Button("Cache") {
                    appState.selectedSection = .cache
                }
                .keyboardShortcut("5", modifiers: .command)
            }

            CommandGroup(replacing: .textEditing) {
                Button("Find...") {
                    showSearch.toggle()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
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
                DuplicatesView()
            case .staleFiles:
                StaleFilesView()
            case .cache:
                CacheView()
            }
        }
    }
}
