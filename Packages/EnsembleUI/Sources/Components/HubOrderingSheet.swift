import EnsembleCore
import SwiftUI

/// Sheet view for reordering hub sections
/// Allows users to drag hubs to reorder them, with a reset button to restore default order
public struct HubOrderingSheet: View {
    @ObservedObject var viewModel: HomeViewModel
    @State private var reorderedHubs: [Hub] = []
    
    public init(viewModel: HomeViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                headerBanner
                hubList
            }
            .navigationTitle("Edit Sections")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                toolbarContent
            }
        }
        .onAppear {
            reorderedHubs = viewModel.editableHubs
        }
        .onChange(of: reorderedHubs) { newValue in
            viewModel.editableHubs = newValue
        }
        .onChange(of: viewModel.editableHubs) { newValue in
            reorderedHubs = newValue
        }
    }
    
    private var headerBanner: some View {
        VStack(spacing: 8) {
            Text(viewModel.currentSourceName)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("Changes made here are unique for each source")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(headerBackgroundColor)
    }
    
    private var headerBackgroundColor: Color {
        #if os(iOS)
        return Color(UIColor.systemGray6)
        #else
        return Color.secondary.opacity(0.1)
        #endif
    }
    
    private var hubList: some View {
        List {
            ForEach(reorderedHubs.indices, id: \.self) { index in
                HStack(spacing: 12) {
                    // Drag handle
                    Image(systemName: "line.3.horizontal")
                        .foregroundColor(.secondary)
                        .font(.system(size: 16))
                    
                    // Hub title
                    Text(reorderedHubs[index].title)
                        .lineLimit(1)
                }
            }
            .onMove(perform: moveHub)
        }
        .listStyle(.inset)
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Reset") {
                handleReset()
            }
            .foregroundColor(.red)
        }
        
        ToolbarItem(placement: .navigationBarTrailing) {
            Button("Done") {
                viewModel.exitEditMode(save: true)
            }
        }
        #else
        ToolbarItem(placement: .cancellationAction) {
            Button("Reset") {
                handleReset()
            }
        }
        
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
                viewModel.exitEditMode(save: true)
            }
        }
        #endif
    }
    
    // MARK: - Actions
    
    private func moveHub(from source: IndexSet, to destination: Int) {
        reorderedHubs.move(fromOffsets: source, toOffset: destination)
    }
    
    private func handleReset() {
        viewModel.resetOrder()
    }
}