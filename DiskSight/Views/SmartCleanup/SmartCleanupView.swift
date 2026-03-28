import SwiftUI

struct SmartCleanupView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedCategory: FileCategoryType?
    @State private var showConfirmTrash = false
    @State private var fileToTrash: CleanupRecommendation?
    @State private var showConfirmBatchTrash = false
    @AppStorage("llmEnabled") private var llmEnabled = false

    private var recommendations: [CleanupRecommendation] {
        guard let recs = appState.cleanupRecommendations else { return [] }
        if let cat = selectedCategory {
            return recs.filter { $0.category == cat }
        }
        return recs
    }

    private var summary: CleanupSummary {
        appState.cleanupSummary ?? .empty
    }

    private var selectedProviderStatusColor: Color {
        appState.isSelectedLLMAvailable ? .green : .orange
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)

            Divider()

            if appState.isAnalyzingCleanup {
                analysisProgress
            } else if appState.cleanupRecommendations == nil {
                emptyState
            } else if recommendations.isEmpty {
                noResultsState
            } else {
                recommendationsList
            }
        }
        .task {
            if appState.cleanupRecommendations == nil && !appState.isAnalyzingCleanup {
                await appState.loadSmartCleanup()
            }
            await appState.checkLLMStatus()
        }
        .onChange(of: appState.cleanupLLMProvider) { _, _ in
            Task { await appState.checkLLMStatus() }
        }
        .alert("Move to Trash?", isPresented: $showConfirmTrash) {
            Button("Move to Trash", role: .destructive) {
                if let file = fileToTrash {
                    Task { await appState.trashCleanupFile(at: file.filePath) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let file = fileToTrash {
                Text("Move \(file.fileName) (\(SizeFormatter.format(file.fileSize))) to Trash?")
            }
        }
        .alert("Clean All Safe Files?", isPresented: $showConfirmBatchTrash) {
            Button("Move to Trash", role: .destructive) {
                Task { await appState.trashAllSafeCleanup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Move \(summary.safeReclaimable > 0 ? SizeFormatter.format(summary.safeReclaimable) : "0 bytes") of safe-to-delete files to Trash?")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Smart Cleanup")
                        .font(.headline)
                    Circle()
                        .fill(selectedProviderStatusColor)
                        .frame(width: 8, height: 8)
                        .help(appState.selectedLLMStatusDescription)
                    Text(appState.cleanupLLMProvider.shortLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let recs = appState.cleanupRecommendations, !recs.isEmpty {
                    Text("\(recs.count) recommendations | \(SizeFormatter.format(summary.totalReclaimable)) reclaimable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("LLM", isOn: $llmEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(appState.cleanupLLMProvider.detail)

            if llmEnabled {
                Picker("", selection: $appState.cleanupLLMProvider) {
                    ForEach(CleanupLLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .frame(width: 130)
                .controlSize(.small)

                if appState.cleanupLLMProvider == .ollama, !appState.ollamaModels.isEmpty {
                    Picker("", selection: $appState.selectedOllamaModel) {
                        ForEach(appState.ollamaModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .frame(width: 140)
                    .controlSize(.small)
                } else if appState.cleanupLLMProvider == .claudeHeadless {
                    Text(appState.selectedClaudeModel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                        .help("Claude model: \(appState.selectedClaudeModel)")
                }
            }

            if summary.safeReclaimable > 0 {
                Button {
                    showConfirmBatchTrash = true
                } label: {
                    Label("Clean All Safe (\(SizeFormatter.format(summary.safeReclaimable)))", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
            }

            Button {
                Task { await appState.runSmartCleanup(useLLM: llmEnabled) }
            } label: {
                Label("Analyze", systemImage: "wand.and.stars")
            }
            .controlSize(.small)
            .disabled(appState.isAnalyzingCleanup || appState.lastScanSession == nil)
        }
    }

    // MARK: - Progress

    private var analysisProgress: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            if let progress = appState.cleanupProgress {
                if progress.total == 0 {
                    Text(progress.currentFile)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Analyzing files... \(progress.processed)/\(progress.total)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(progress.processed), total: Double(max(progress.total, 1)))
                        .frame(width: 300)
                    Text(progress.currentFile)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("Preparing analysis...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Smart Cleanup")
                .font(.title3)
            Text("Analyze your files to get intelligent cleanup recommendations.\nRun a scan first, then click Analyze.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if appState.lastScanSession != nil {
                Button {
                    Task { await appState.runSmartCleanup(useLLM: llmEnabled) }
                } label: {
                    Label("Analyze Now", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("No Recommendations")
                .font(.title3)
            if selectedCategory != nil {
                Text("No files found in this category")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Clear Filter") {
                    selectedCategory = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text("Your files look well-organized!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Recommendations List

    private var recommendationsList: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryBanner
                categoryFilterBar
                confidenceGroups
            }
            .padding(16)
        }
    }

    // MARK: - Summary Banner

    private var summaryBanner: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Reclaimable Space")
                        .font(.subheadline.bold())
                    Spacer()
                    Text(SizeFormatter.format(summary.totalReclaimable))
                        .font(.title3.bold().monospacedDigit())
                }

                // Three-segment bar
                GeometryReader { geo in
                    let total = max(summary.totalReclaimable, 1)
                    let safeW = CGFloat(summary.safeReclaimable) / CGFloat(total) * geo.size.width
                    let cautionW = CGFloat(summary.cautionReclaimable) / CGFloat(total) * geo.size.width
                    let riskyW = CGFloat(summary.riskyReclaimable) / CGFloat(total) * geo.size.width

                    HStack(spacing: 2) {
                        if safeW > 0 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.green)
                                .frame(width: max(safeW, 4))
                        }
                        if cautionW > 0 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.orange)
                                .frame(width: max(cautionW, 4))
                        }
                        if riskyW > 0 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.red)
                                .frame(width: max(riskyW, 4))
                        }
                    }
                }
                .frame(height: 12)

                // Legend
                HStack(spacing: 16) {
                    confidenceLegendItem(color: .green, label: "Safe", size: summary.safeReclaimable)
                    confidenceLegendItem(color: .orange, label: "Caution", size: summary.cautionReclaimable)
                    confidenceLegendItem(color: .red, label: "Risky", size: summary.riskyReclaimable)
                }
            }
            .padding(4)
        }
    }

    private func confidenceLegendItem(color: Color, label: String, size: Int64) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(label): \(SizeFormatter.format(size))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Category Filter

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryPill(nil, label: "All", count: appState.cleanupRecommendations?.count ?? 0)
                ForEach(summary.categoryBreakdown, id: \.0) { cat, size, count in
                    categoryPill(cat, label: cat.rawValue, count: count)
                }
            }
        }
    }

    private func categoryPill(_ category: FileCategoryType?, label: String, count: Int) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 4) {
                if let cat = category {
                    Image(systemName: cat.icon)
                        .font(.caption2)
                }
                Text("\(label) (\(count))")
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Confidence Groups

    private var confidenceGroups: some View {
        let grouped = Dictionary(grouping: recommendations) { $0.confidence }
        return ForEach([DeletionConfidence.safe, .caution, .risky, .keep], id: \.self) { confidence in
            if let group = grouped[confidence], !group.isEmpty {
                confidenceSection(confidence: confidence, items: group)
            }
        }
    }

    private func confidenceSection(confidence: DeletionConfidence, items: [CleanupRecommendation]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(colorForConfidence(confidence))
                    .frame(width: 10, height: 10)
                Text(confidence.label)
                    .font(.subheadline.bold())
                Text("(\(items.count) files, \(SizeFormatter.format(items.reduce(0) { $0 + $1.fileSize })))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(items, id: \.id) { rec in
                RecommendationCard(recommendation: rec, safetyColor: colorForConfidence(rec.confidence)) {
                    fileToTrash = rec
                    showConfirmTrash = true
                }
            }
        }
    }

    private func colorForConfidence(_ confidence: DeletionConfidence) -> Color {
        switch confidence {
        case .safe: return .green
        case .caution: return .orange
        case .risky: return .red
        case .keep: return .blue
        }
    }
}

// MARK: - Recommendation Card

struct RecommendationCard: View {
    let recommendation: CleanupRecommendation
    let safetyColor: Color
    let onTrash: () -> Void

    @State private var isExpanded = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(safetyColor)
                        .frame(width: 10, height: 10)

                    Image(systemName: recommendation.category.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(recommendation.fileName)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Text(truncatedPath(recommendation.filePath))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    if let accessed = recommendation.accessedAt {
                        Text(Date(timeIntervalSince1970: accessed).relativeString)
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                    }

                    Text(SizeFormatter.format(recommendation.fileSize))
                        .font(.subheadline.bold().monospacedDigit())

                    if recommendation.confidence != .keep {
                        Button {
                            onTrash()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Move to Trash")
                    }

                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                }

                // Signal badges
                if !recommendation.signals.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(recommendation.signals, id: \.rawValue) { signal in
                            Text(signal.rawValue)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        if recommendation.llmEnhanced {
                            Text("AI")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                }

                if isExpanded {
                    Divider()
                    Text(recommendation.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(recommendation.filePath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(4)
        }
    }

    private func truncatedPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count > 4 {
            return "/.../" + components.suffix(3).joined(separator: "/")
        }
        return path
    }
}
