import SwiftUI

struct WatchRootView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "music.note.house.fill")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)

                Text("Ensemble")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("Use the iPhone app to connect Plex, manage libraries, and control playback.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                    .padding(.vertical, 4)

                Label("Watch companion is not enabled in this build", systemImage: "applewatch")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
