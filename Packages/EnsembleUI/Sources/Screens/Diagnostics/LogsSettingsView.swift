import EnsembleCore
import SwiftUI

/// Settings sub-view for managing persistent session logs.
/// Shows a toggle to enable/disable logging, a list of saved session files
/// with swipe-to-delete, and navigation to view individual log contents.
public struct LogsSettingsView: View {
    @ObservedObject private var logService = DependencyContainer.shared.persistentLogService
    @State private var isLoggingEnabled: Bool = DependencyContainer.shared.persistentLogService.isEnabled
    @State private var showingDeleteAllSessionsAlert = false

    public init() {}

    public var body: some View {
        EnsembleAdaptiveUtilityScaffold(title: "Logs") {
            compactList
        } regularContent: {
            regularSections
        }
        .onAppear {
            logService.loadSessions()
        }
        .alert("Delete All Sessions", isPresented: $showingDeleteAllSessionsAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All Sessions", role: .destructive) {
                logService.deleteAllSessions()
            }
        } message: {
            Text("This permanently deletes every saved diagnostic log session on this device.")
        }
    }

    private var compactList: some View {
        List {
            // Toggle section
            Section {
                persistentLoggingToggle
            }

            // Sessions list
            Section {
                if logService.sessions.isEmpty {
                    Text("No log sessions yet.")
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .font(EnsembleDesign.Typography.stateMessage)
                } else {
                    ForEach(logService.sessions) { session in
                        NavigationLink {
                            LogDetailView(session: session)
                        } label: {
                            LogSessionRow(session: session)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            guard logService.sessions.indices.contains(index) else { continue }
                            logService.deleteSession(logService.sessions[index])
                        }
                    }
                }
            } header: {
                EnsembleUtilitySectionHeader("Sessions")
            }

            // Delete All button (only when sessions exist)
            if !logService.sessions.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showingDeleteAllSessionsAlert = true
                    } label: {
                        HStack {
                            Image(systemName: EnsembleDesign.Icon.delete)
                                .frame(width: EnsembleScaffold.UtilityRow.iconLaneWidth)
                            Text("Delete All Sessions")
                                .foregroundColor(EnsembleDesign.Color.destructive)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }

    @ViewBuilder
    private var regularSections: some View {
        EnsembleUtilityCardSection {
            EnsembleUtilityCardRow {
                persistentLoggingToggle
            }
        }

        EnsembleUtilityCardSection("Sessions") {
            if logService.sessions.isEmpty {
                EnsembleUtilityCardRow {
                    Text("No log sessions yet.")
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                        .font(EnsembleDesign.Typography.stateMessage)
                }
            } else {
                ForEach(logService.sessions) { session in
                    EnsembleUtilityCardRow {
                        HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                            NavigationLink {
                                LogDetailView(session: session)
                            } label: {
                                LogSessionRow(session: session)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                logService.deleteSession(session)
                            } label: {
                                Image(systemName: EnsembleDesign.Icon.delete)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete Log Session")
                        }
                    }

                    if session.id != logService.sessions.last?.id {
                        EnsembleUtilityCardDivider()
                    }
                }
            }
        }

        if !logService.sessions.isEmpty {
            EnsembleUtilityCardSection {
                EnsembleUtilityCardRow {
                    deleteAllButton
                }
            }
        }
    }

    private var persistentLoggingToggle: some View {
        Toggle(isOn: $isLoggingEnabled) {
            HStack {
                Image(systemName: EnsembleDesign.Icon.logsVerified)
                    .frame(width: EnsembleScaffold.UtilityRow.iconLaneWidth)
                VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xxs) {
                    Text("Persistent Logging")
                    Text("When enabled, app logs are saved each session. Useful for diagnosing issues.")
                        .font(EnsembleDesign.Typography.rowSecondary)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            }
        }
        .onChange(of: isLoggingEnabled) { newValue in
            logService.isEnabled = newValue
        }
    }

    private var deleteAllButton: some View {
        Button(role: .destructive) {
            showingDeleteAllSessionsAlert = true
        } label: {
            HStack {
                Image(systemName: EnsembleDesign.Icon.delete)
                    .frame(width: EnsembleScaffold.UtilityRow.iconLaneWidth)
                Text("Delete All Sessions")
                    .foregroundColor(EnsembleDesign.Color.destructive)
            }
        }
    }
}

// MARK: - Session Row

/// A single row displaying a log session's date and file size.
private struct LogSessionRow: View {
    let session: LogSession

    var body: some View {
        VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xs) {
            Text(formattedDate)
                .font(EnsembleDesign.Typography.rowPrimary)
            Text(formattedSize)
                .font(EnsembleDesign.Typography.rowSecondary)
                .foregroundColor(EnsembleDesign.Color.secondaryText)
        }
        .padding(.vertical, EnsembleDesign.Spacing.xxs)
    }

    private var formattedDate: String {
        MediaFormatters.mediumDateTime(session.date)
    }

    private var formattedSize: String {
        MediaFormatters.logBytes(session.fileSize)
    }
}
