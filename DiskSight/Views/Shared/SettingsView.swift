import SwiftUI
import Sparkle

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    let updater: SPUUpdater

    @AppStorage("visualizationMode") private var defaultVizMode: VisualizationMode = .treemap
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.system.rawValue
    @AppStorage("llmEnabled") private var llmEnabled = false
    @State private var providerTestResult: String?
    @State private var providerTestSucceeded = false
    @State private var isTesting = false

    private var byteCountFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useAll]
        return f
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode.rawValue)
                    }
                }
            }

            Section("Visualization") {
                Picker("Default mode", selection: $defaultVizMode) {
                    ForEach(VisualizationMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                Toggle("Hide external drives", isOn: $appState.hideExternalDrives)
            }

            Section("Monitoring") {
                Toggle("Enable real-time monitoring", isOn: $appState.monitoringEnabled)
                Text("When enabled, DiskSight watches for file changes after a scan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Stale Files") {
                Picker("Default threshold", selection: $appState.staleThreshold) {
                    ForEach(StaleThreshold.allCases) { threshold in
                        Text(threshold.rawValue).tag(threshold)
                    }
                }
            }

            Section("Smart Cleanup") {
                Toggle("Enable LLM enhancement", isOn: $llmEnabled)
                Picker("Provider", selection: $appState.cleanupLLMProvider) {
                    ForEach(CleanupLLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                Text(appState.cleanupLLMProvider.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Status", value: appState.selectedLLMStatusDescription)

                if llmEnabled {
                    switch appState.cleanupLLMProvider {
                    case .ollama:
                        TextField("Ollama URL", text: $appState.ollamaBaseURL)
                            .textFieldStyle(.roundedBorder)

                        TextField("Model name", text: $appState.selectedOllamaModel)
                            .textFieldStyle(.roundedBorder)
                    case .claudeHeadless:
                        TextField("Claude model", text: $appState.selectedClaudeModel)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Button {
                            testProvider()
                        } label: {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Test Provider")
                            }
                        }
                        .disabled(isTesting)

                        if let result = providerTestResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(providerTestSucceeded ? .green : .red)
                        }
                    }
                }
            }

            Section("Storage") {
                LabeledContent("Database size", value: byteCountFormatter.string(fromByteCount: appState.databaseSizeBytes))
                LabeledContent("Reclaimable", value: byteCountFormatter.string(fromByteCount: appState.databaseFreeBytes))

                HStack {
                    Button {
                        Task { await appState.compactDatabase() }
                    } label: {
                        if appState.isCompactingDatabase {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Compact Now")
                        }
                    }
                    .disabled(appState.isCompactingDatabase || appState.databaseFreeBytes < 1_000_000)

                    Spacer()
                }

                Text("Compaction rewrites the index to release unused space. Runs automatically after large deletions; this button forces it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
            }

            Section("Updates") {
                HStack {
                    Button("Check for Updates...") {
                        updater.checkForUpdates()
                    }

                    Spacer()

                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    ))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 620)
        .task {
            await appState.checkLLMStatus()
            await appState.refreshDatabaseStats()
        }
        .onAppear {
            Task { await appState.refreshDatabaseStats() }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            Task { await appState.refreshDatabaseStats() }
        }
        .onChange(of: appState.cleanupLLMProvider) { _, _ in
            providerTestResult = nil
            Task { await appState.checkLLMStatus() }
        }
    }

    private func testProvider() {
        isTesting = true
        providerTestResult = nil
        providerTestSucceeded = false
        Task {
            await MainActor.run {
                providerTestResult = nil
            }

            switch appState.cleanupLLMProvider {
            case .ollama:
                let client = OllamaClient(baseURL: appState.ollamaBaseURL)
                let status = await client.checkAvailability()
                await MainActor.run {
                    switch status {
                    case .available(let models):
                        appState.isOllamaAvailable = true
                        appState.ollamaModels = models
                        if !models.contains(appState.selectedOllamaModel), let first = models.first {
                            appState.selectedOllamaModel = first
                        }
                        providerTestResult = "Connected - \(models.count) model(s) available"
                        providerTestSucceeded = true
                    case .unavailable:
                        appState.isOllamaAvailable = false
                        appState.ollamaModels = []
                        providerTestResult = "Connection failed - is Ollama running?"
                        providerTestSucceeded = false
                    }
                    isTesting = false
                }
            case .claudeHeadless:
                let client = ClaudeCLIClient()
                let status = await client.checkAvailability()
                await MainActor.run {
                    switch status {
                    case .available(let version):
                        appState.isClaudeAvailable = true
                        appState.claudeVersion = version
                        providerTestResult = version.map { "Claude CLI available - \($0)" } ?? "Claude CLI available"
                        providerTestSucceeded = true
                    case .unavailable(let message):
                        appState.isClaudeAvailable = false
                        appState.claudeVersion = nil
                        providerTestResult = message
                        providerTestSucceeded = false
                    }
                    isTesting = false
                }
            }
        }
    }
}
