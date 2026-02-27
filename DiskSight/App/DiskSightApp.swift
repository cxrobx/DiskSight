import SwiftUI
import Sparkle

@main
struct DiskSightApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showOnboarding = false
    @State private var showSearch = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.system.rawValue

    private let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private var selectedColorScheme: ColorScheme? {
        (AppearanceMode(rawValue: appearanceMode) ?? .system).colorScheme
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1100, minHeight: 600)
                .preferredColorScheme(selectedColorScheme)
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
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        appState.saveEventIdSync()
                    case .active:
                        appState.handleBecameActive()
                    default:
                        break
                    }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }

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

                Button("Smart Cleanup") {
                    appState.selectedSection = .smartCleanup
                }
                .keyboardShortcut("6", modifiers: .command)

                Button("Recent Growth") {
                    appState.selectedSection = .growth
                }
                .keyboardShortcut("7", modifiers: .command)
            }

            CommandGroup(after: .saveItem) {
                Button("Export as CSV...") {
                    appState.exportCSV()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(appState.lastScanSession == nil || appState.isExportingCSV)
            }

            CommandGroup(replacing: .textEditing) {
                Button("Find...") {
                    showSearch.toggle()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            SettingsView(updater: updaterController.updater)
                .environmentObject(appState)
        }
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates...", action: checkForUpdatesViewModel.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
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
            case .growth:
                GrowthView()
            case .duplicates:
                DuplicatesView()
            case .staleFiles:
                StaleFilesView()
            case .cache:
                CacheView()
            case .smartCleanup:
                SmartCleanupView()
            }
        }
    }
}
