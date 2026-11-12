import Foundation

/// The part of an artwork path that names the image. A pre-signed URL (AWS SigV4 `X-Amz-*` query items) is
/// re-signed on every read, so two reads of the same image never compare equal as strings; compare their
/// identities instead. Anything that is not an http(s) URL, and `musicKit://` URLs (already reduced to their
/// asset when stored), are their own identity.
public enum ArtworkPathIdentity {
    public static func of(_ path: String?) -> String? {
        guard let path,
              var components = URLComponents(string: path),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let items = components.percentEncodedQueryItems
        else { return path }
        let kept = items.filter { !$0.name.lowercased().hasPrefix("x-amz-") }
        guard kept.count != items.count else { return path }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.string
    }
}
