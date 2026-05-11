import SwiftUI

struct WatchRootView: View {
    @StateObject private var session = WatchSessionModel()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 10) {
                    header
                    progress
                    controls
                    playbackOptions
                    status
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            .navigationTitle("Ensemble")
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Image(systemName: session.isPlaying ? "music.note.house.fill" : "music.note.house")
                .font(.title2)
                .foregroundColor(.accentColor)

            Text(session.currentTrackTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.75)

            Text(session.currentTrackSubtitle)
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
    }

    private var progress: some View {
        VStack(spacing: 4) {
            ProgressView(value: session.progress)
                .progressViewStyle(.linear)

            HStack {
                Text(session.elapsedText)
                Spacer()
                Text(session.remainingText)
            }
            .font(.caption2.monospacedDigit())
            .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback Progress")
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                session.send(.previous)
            } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Previous")

            Button {
                session.send(.togglePlayPause)
            } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(session.isPlaying ? "Pause" : "Play")

            Button {
                session.send(.next)
            } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Next")
        }
        .disabled(session.isSendingCommand)
    }

    private var playbackOptions: some View {
        HStack(spacing: 12) {
            Button {
                session.send(.toggleShuffle)
            } label: {
                Image(systemName: "shuffle")
                    .foregroundColor(session.snapshot?.isShuffleEnabled == true ? .accentColor : .primary)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(session.snapshot?.isShuffleEnabled == true ? "Shuffle On" : "Shuffle Off")

            Button {
                session.send(.cycleRepeatMode)
            } label: {
                Image(systemName: session.snapshot?.repeatMode.systemImage ?? "repeat")
                    .foregroundColor(session.snapshot?.repeatMode == .off ? .primary : .accentColor)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(session.snapshot?.repeatMode.accessibilityLabel ?? "Repeat")
        }
        .disabled(session.isSendingCommand)
    }

    private var status: some View {
        VStack(spacing: 4) {
            if let snapshot = session.snapshot,
               snapshot.queueCount > 0,
               snapshot.currentQueueIndex >= 0 {
                Text("Track \(snapshot.currentQueueIndex + 1) of \(snapshot.queueCount)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let error = session.snapshot?.playbackError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            } else {
                Text(session.statusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
