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
                // Source info banner
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
                .background(Color(.systemGray6))
                
                // Hub list with reordering
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
            .navigationTitle("Edit Sections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Reset order") {
                        handleReset()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        Task {
                            await viewModel.exitEditMode(save: true)
                        }
                    }
                }
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
    
    // MARK: - Actions
    
    private func moveHub(from source: IndexSet, to destination: Int) {
        reorderedHubs.move(fromOffsets: source, toOffset: destination)
    }
    
    private func handleReset() {
        viewModel.resetOrder()
        viewModel.isEditingOrder = false
    }
}

#Preview {
    VStack {
        Text("HubOrderingSheet Preview")
    }
}
