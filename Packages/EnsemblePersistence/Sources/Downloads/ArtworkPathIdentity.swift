import Foundation

/// The part of an artwork path that names the image. A pre-signed URL (AWS SigV4 authentication query items) is
/// re-signed on every read, so two reads of the same image never compare equal as strings; compare their
/// identities instead. Only the SigV4 authentication parameters are dropped; every other query item, including
/// other `x-amz-` ones, stays part of the identity. Anything that is not an http(s) URL with such items, and
/// `musicKit://` URLs (already reduced to their asset when stored), are returned byte for byte.
public enum ArtworkPathIdentity {
    private static let signatureParameters: Set<String> = [
        "x-amz-algorithm", "x-amz-credential", "x-amz-date", "x-amz-expires",
        "x-amz-signedheaders", "x-amz-signature", "x-amz-security-token",
    ]

    public static func of(_ path: String?) -> String? {
        guard let path,
              var components = URLComponents(string: path),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let items = components.percentEncodedQueryItems
        else { return path }
        let kept = items.filter { !signatureParameters.contains($0.name.lowercased()) }
        guard kept.count != items.count else { return path }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.string
    }
}
