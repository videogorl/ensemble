import EnsembleCore
import SwiftUI

public struct DownloadManagerSettingsView: View {
    @AppStorage("downloadQuality") private var downloadQuality = "original"

    public init() {}

    public var body: some View {
        List {
            Section {
                Picker("Download Quality", selection: $downloadQuality) {
                    Text("Original").tag("original")
                    Text("High (320 kbps)").tag("high")
                    Text("Medium (192 kbps)").tag("medium")
                    Text("Low (128 kbps)").tag("low")
                }
                .pickerStyle(.menu)
            } header: {
                Text("Downloads")
                    .foregroundColor(.accentColor)
                    .textCase(nil)
            } footer: {
                Text("This matches Settings > Audio Quality > Download Quality.")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Manage Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
