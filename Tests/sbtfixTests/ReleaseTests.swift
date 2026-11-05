import XCTest
@testable import sbtfix

final class ReleaseTests: XCTestCase {
    func testDecodesGitHubResponse() throws {
        // Trimmed from api.github.com/repos/NiedielnitsevIvan/sbtfix/releases/latest
        let json = """
        {"tag_name": "v1.1.0", "draft": false, "assets": [{"name": "sbtfix.zip", "size": 370784,
        "browser_download_url": "https://github.com/NiedielnitsevIvan/sbtfix/releases/download/v1.1.0/sbtfix.zip"}]}
        """
        let release = try Release.decode(Data(json.utf8))
        XCTAssertEqual(release.version, "1.1.0")
        XCTAssertEqual(release.assets.map(\.name), ["sbtfix.zip"])
        XCTAssertEqual(release.assets.first?.browserDownloadUrl.lastPathComponent, "sbtfix.zip")
    }

    func testVersionComparison() {
        func isNewer(_ tag: String, than current: String) -> Bool {
            Release(tagName: tag, assets: []).isNewer(than: current)
        }
        XCTAssertTrue(isNewer("v1.2.0", than: "1.1.0"))
        XCTAssertTrue(isNewer("v1.10.0", than: "1.9.0"))
        XCTAssertTrue(isNewer("1.2.0", than: "1.1.0"))
        XCTAssertFalse(isNewer("v1.1.0", than: "1.1.0"))
        XCTAssertFalse(isNewer("v1.0.9", than: "1.1.0"))
    }
}
