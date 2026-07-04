import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct LocalProfileImage<Placeholder: View>: View {
    let url: URL
    let reloadToken: Date
    let placeholder: Placeholder
    @State private var image: Image?

    init(
        url: URL,
        reloadToken: Date,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.url = url
        self.reloadToken = reloadToken
        self.placeholder = placeholder()
    }

    var body: some View {
        Group {
            if let image = image {
                image
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .onAppear { loadImage() }
        .onChange(of: url) { _ in loadImage() }
        .onChange(of: reloadToken) { _ in loadImage() }
    }

    private func loadImage() {
        #if canImport(UIKit)
        if let uiImage = UIImage(contentsOfFile: url.path) {
            image = Image(uiImage: uiImage)
        } else {
            image = nil
        }
        #elseif canImport(AppKit)
        if let nsImage = NSImage(contentsOf: url) {
            image = Image(nsImage: nsImage)
        } else {
            image = nil
        }
        #endif
    }
}
