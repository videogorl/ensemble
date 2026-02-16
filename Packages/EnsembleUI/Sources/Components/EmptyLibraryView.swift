import SwiftUI

/// Empty state view shown when no music sources are configured
public struct EmptyLibraryView: View {
    let onAddSource: () -> Void

    public init(onAddSource: @escaping () -> Void) {
        self.onAddSource = onAddSource
    }

    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 80))
                .foregroundColor(.secondary)

            VStack(spacing: 8) {
                Text("No Music Sources")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Add a Plex server to start listening to your music")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button(action: onAddSource) {
                Label("Add Music Source", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 32)
        }
    }
}
