import EnsembleCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct AddPlexAccountView: View {
    @StateObject private var viewModel: AddPlexAccountViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.dependencies) private var deps

    /// When true, the view is pushed inside an existing NavigationStack
    /// and should not wrap itself in another NavigationView.
    private let isEmbedded: Bool

    public init(embedded: Bool = false) {
        self._viewModel = StateObject(wrappedValue: DependencyContainer.shared.makeAddPlexAccountViewModel())
        self.isEmbedded = embedded
    }

    public var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    #if os(macOS)
    private var macOSBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                contentStack
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, EnsembleScaffold.AccountSetup.horizontalPadding)
            .padding(.vertical, EnsembleScaffold.AccountSetup.footerVerticalPadding)
        }
        .frame(
            minWidth: EnsembleScaffold.AccountSetup.macMinimumWidth,
            minHeight: EnsembleScaffold.AccountSetup.macMinimumHeight
        )
        .onChange(of: viewModel.state) { newState in
            if newState == .complete {
                dismiss()
            }
        }
    }
    #endif

    private var iOSBody: some View {
        Group {
            if isEmbedded {
                // Pushed inside an existing NavigationStack (e.g. profile sheet).
                // Skip wrapping in NavigationView; use Cancel as a simple dismiss button.
                ScrollView {
                    contentStack
                }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden(true)
                #endif
                .toolbar {
                    #if os(iOS)
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    #else
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    #endif
                }
                .onChange(of: viewModel.state) { newState in
                    if newState == .complete {
                        dismiss()
                    }
                }
            } else {
                // Presented as a standalone sheet — wrap in its own NavigationView.
                NavigationView {
                    ScrollView {
                        contentStack
                    }
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        #if os(iOS)
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Cancel") {
                                dismiss()
                            }
                        }
                        #else
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                dismiss()
                            }
                        }
                        #endif
                    }
                    .onChange(of: viewModel.state) { newState in
                        if newState == .complete {
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private var contentStack: some View {
        VStack(spacing: EnsembleScaffold.AccountSetup.contentSpacing) {
            // App icon
            VStack(spacing: EnsembleScaffold.AccountSetup.sectionSpacing) {
                Image(systemName: EnsembleDesign.Icon.library)
                    .font(.system(size: EnsembleScaffold.AccountSetup.iconSize))
                    .foregroundColor(EnsembleDesign.Color.accent)

                Text("Add Plex Account")
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            // Auth content
            authContent

            // Error message
            if let error = viewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: EnsembleScaffold.AccountSetup.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, EnsembleScaffold.AccountSetup.horizontalPadding)
        .padding(.vertical, EnsembleScaffold.AccountSetup.contentSpacing)
    }

    @ViewBuilder
    private var authContent: some View {
        switch viewModel.state {
        case .ready:
            signInButton

        case .authenticating(let code, let linkURL):
            pinView(code: code, linkURL: linkURL)

        case .selectingServer:
            serverLibrarySelectionView

        case .selectingLibraries:
            serverLibrarySelectionView

        case .complete:
            ProgressView()
        }
    }

    private var signInButton: some View {
        VStack(spacing: EnsembleScaffold.AccountSetup.sectionSpacing) {
            Button {
                Task {
                    await viewModel.startAuth()
                }
            } label: {
                HStack {
                    Image(systemName: "person.circle.fill")
                    Text("Sign in with Plex")
                }
            }
            .buttonStyle(EnsemblePrimaryActionButtonStyle())
            .disabled(viewModel.isLoading)

            if viewModel.isLoading {
                ProgressView()
            }
        }
        .padding(.horizontal, EnsembleScaffold.AccountSetup.prominentHorizontalPadding)
    }

    private func pinView(code: String, linkURL: URL) -> some View {
        VStack(spacing: EnsembleScaffold.AccountSetup.contentSpacing) {
            Text("Enter this code at plex.tv/link")
                .font(.headline)

            Button {
                copyToClipboard(code)
                deps.toastCenter.show(
                    ToastPayload(
                        style: .success,
                        iconSystemName: "checkmark.circle.fill",
                        title: "Code copied",
                        message: "Paste it at plex.tv/link",
                        dedupeKey: "add-account-pin-copied"
                    )
                )
            } label: {
                VStack(spacing: EnsembleScaffold.AccountSetup.cardSpacing) {
                    Text(code)
                        .font(.system(
                            size: EnsembleScaffold.AccountSetup.pinCodeFontSize,
                            weight: .bold,
                            design: .monospaced
                        ))
                        .tracking(EnsembleScaffold.AccountSetup.pinCodeTracking)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    HStack(spacing: EnsembleScaffold.AccountSetup.inlineIconSpacing) {
                        Image(systemName: "doc.on.doc")
                        Text("Tap to copy")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding()
                .background(EnsembleScaffold.AccountSetup.cardBackground)
                .cornerRadius(EnsembleScaffold.AccountSetup.cardCornerRadius)
                .frame(maxWidth: EnsembleScaffold.AccountSetup.pinCodeMaxWidth)
            }
            .buttonStyle(.plain)

            // Use Button + openURL instead of Link to prevent the sheet
            // from dismissing on iOS 15/16 (known SwiftUI Link-in-sheet bug)
            Button {
                openURL(linkURL)
            } label: {
                HStack {
                    Text("Open plex.tv/link")
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.headline)
                .lineLimit(1)
            }

            Text("Waiting for authorization...")
                .font(.caption)
                .foregroundColor(.secondary)

            ProgressView()

            Button("Cancel") {
                viewModel.cancelAuth()
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
    }

    private var serverLibrarySelectionView: some View {
        VStack(spacing: EnsembleScaffold.AccountSetup.sectionSpacing) {
            Text("Select Servers and Libraries")
                .font(.headline)

            if viewModel.isLoading {
                ProgressView()
            } else if viewModel.servers.isEmpty {
                Text("No servers found")
                    .foregroundColor(.secondary)

                Button("Refresh") {
                    Task {
                        await viewModel.loadServers()
                    }
                }
            } else {
                LazyVStack(spacing: EnsembleScaffold.AccountSetup.sectionSpacing) {
                    ForEach(viewModel.servers) { server in
                        VStack(alignment: .leading, spacing: EnsembleScaffold.AccountSetup.cardSpacing) {
                            HStack(spacing: EnsembleScaffold.AccountSetup.cardSpacing) {
                                Image(systemName: "server.rack")
                                    .font(.subheadline)
                                    .foregroundColor(.accentColor)

                                Text(server.name)
                                    .font(.headline)

                                if let platform = server.platform {
                                    Text("(\(platform))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            if let serverError = viewModel.serverLibraryErrors[server.id] {
                                Text(serverError)
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .padding(.bottom, 4)
                            } else {
                                let serverLibraries = viewModel.libraries(for: server.id)
                                if serverLibraries.isEmpty {
                                    Text("No music libraries found")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    ServerLibrariesSelection(
                                        libraries: serverLibraries
                                    ) { library in
                                        viewModel.isLibrarySelected(serverId: server.id, libraryKey: library.key)
                                    } onToggle: { library in
                                        viewModel.toggleLibrary(for: server.id, library: library)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(EnsembleScaffold.AccountSetup.cardPadding)
                        .background(EnsembleScaffold.AccountSetup.cardBackground)
                        .cornerRadius(EnsembleScaffold.AccountSetup.cardCornerRadius)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                Button {
                    viewModel.confirmLibraries()
                } label: {
                    Text("Add Account")
                }
                .buttonStyle(EnsemblePrimaryActionButtonStyle())
                .padding(.horizontal, EnsembleScaffold.AccountSetup.prominentHorizontalPadding)
                .disabled(viewModel.selectedLibraryCompositeKeys.isEmpty)
            }
        }
    }

    private func copyToClipboard(_ value: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = value
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}

// MARK: - Library Selection Row

struct LibrarySelectionRow: View {
    let library: Library
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                Image(systemName: isSelected ? EnsembleDesign.Icon.checkmark : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? EnsembleDesign.Color.accent : .gray)
                    .frame(width: EnsembleScaffold.AccountSetup.rowIconWidth)

                Text(library.title)
                    .font(.headline)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EnsembleScaffold.AccountSetup.cardPadding)
            .background(EnsembleScaffold.AccountSetup.cardBackground)
            .cornerRadius(EnsembleScaffold.AccountSetup.cardCornerRadius)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Server Row

struct ServerRow: View {
    let server: Server
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: TrackListLayoutMetrics.rowInterItemSpacing) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundColor(EnsembleDesign.Color.accent)
                    .frame(width: EnsembleScaffold.AccountSetup.rowIconWidth)
                
                VStack(alignment: .leading, spacing: EnsembleDesign.Spacing.xs) {
                    Text(server.name)
                        .font(.headline)
                    
                    if let platform = server.platform {
                        Text(platform)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Image(systemName: EnsembleDesign.Icon.chevronRight)
                    .foregroundColor(EnsembleDesign.Color.secondaryText)
            }
            .padding(EnsembleScaffold.AccountSetup.cardPadding)
            .background(EnsembleScaffold.AccountSetup.cardBackground)
            .cornerRadius(EnsembleScaffold.AccountSetup.cardCornerRadius)
        }
        .buttonStyle(.plain)
    }
}

private struct ServerLibrariesSelection: View {
    let libraries: [Library]
    let isSelected: (Library) -> Bool
    let onToggle: (Library) -> Void

    var body: some View {
        VStack(spacing: EnsembleScaffold.AccountSetup.cardSpacing) {
            ForEach(libraries) { library in
                LibrarySelectionRow(
                    library: library,
                    isSelected: isSelected(library)
                ) {
                    onToggle(library)
                }
            }
        }
    }
}
