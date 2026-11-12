import XCTest
@testable import EnsemblePersistence

final class ArtworkPathIdentityTests: XCTestCase {
    func testIdentityDropsOnlyTheSigV4QueryItems() {
        let signed = "https://b.s3.amazonaws.com/a%20b/c.jpg?X-Amz-Algorithm=A&size=1200&x-amz-date=D&X-Amz-Signature=S&token=a%2Fb"
        let cases: [(input: String?, identity: String?)] = [
            (signed, "https://b.s3.amazonaws.com/a%20b/c.jpg?size=1200&token=a%2Fb"),
            ("https://b.s3.amazonaws.com/c.jpg?X-Amz-Date=D&X-Amz-Signature=S", "https://b.s3.amazonaws.com/c.jpg"),
            // Only the SigV4 authentication parameters go; any other x-amz item names the image.
            ("https://b.s3.amazonaws.com/c.jpg?x-amz-size=1&X-Amz-Security-Token=T&X-Amz-SignedHeaders=host&X-Amz-Credential=C&X-Amz-Expires=60",
             "https://b.s3.amazonaws.com/c.jpg?x-amz-size=1"),
            ("https://b.s3.amazonaws.com/c.jpg?X-Amz-Date=D&x-amz-meta-v=2", "https://b.s3.amazonaws.com/c.jpg?x-amz-meta-v=2"),
            // Nothing to strip: returned byte for byte.
            ("https://example.com/{w}x{h}.jpg?size=1", "https://example.com/{w}x{h}.jpg?size=1"),
            ("https://example.com/a%20b.jpg?q=a%2Bb+c&q=2#frag", "https://example.com/a%20b.jpg?q=a%2Bb+c&q=2#frag"),
            ("https://example.com/c.jpg?", "https://example.com/c.jpg?"),
            ("https://example.com/c.jpg?x-amz-size=1", "https://example.com/c.jpg?x-amz-size=1"),
            ("file:///var/mobile/art.jpg", "file:///var/mobile/art.jpg"),
            ("not a url %%", "not a url %%"),
            ("https://example.com/c.jpg", "https://example.com/c.jpg"),
            ("musicKit://artwork/x?aat=Music%2Fcover.png", "musicKit://artwork/x?aat=Music%2Fcover.png"),
            ("/library/metadata/1/thumb/1000", "/library/metadata/1/thumb/1000"),
            ("", ""),
            (nil, nil),
        ]
        for testCase in cases {
            XCTAssertEqual(ArtworkPathIdentity.of(testCase.input), testCase.identity, testCase.input ?? "nil")
        }
        XCTAssertEqual(
            ArtworkPathIdentity.of(signed),
            ArtworkPathIdentity.of(signed.replacingOccurrences(of: "X-Amz-Signature=S", with: "X-Amz-Signature=T"))
        )
    }
}
