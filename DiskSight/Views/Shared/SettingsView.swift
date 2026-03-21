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
    @State private var ollamaTestResult: String?
    @State private var isTesting = false

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
                Text("Use a local Ollama model for enhanced file explanations")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if llmEnabled {
                    TextField("Ollama URL", text: $appState.ollamaBaseURL)
                        .textFieldStyle(.roundedBorder)

                    TextField("Model name", text: $appState.selectedOllamaModel)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button {
                            testConnection()
                        } label: {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .disabled(isTesting)

                        if let result = ollamaTestResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.contains("Connected") ? .green : .red)
                        }
                    }
                }
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
        .frame(width: 450, height: 500)
    }

    private func testConnection() {
        isTesting = true
        ollamaTestResult = nil
        Task {
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
                    ollamaTestResult = "Connected — \(models.count) model(s) available"
                case .unavailable:
                    appState.isOllamaAvailable = false
                    appState.ollamaModels = []
                    ollamaTestResult = "Connection failed — is Ollama running?"
                }
                isTesting = false
            }
        }
    }
}
