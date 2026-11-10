import XCTest
@testable import Phi

final class TemporaryDNSPolicyTests: XCTestCase {
    func testAutomaticDNSRestoresAbsenceOfManualConfiguration() {
        let applied: [String: Any] = ["ServerAddresses": ["127.0.0.1"], "ServerPort": 15353]
        XCTAssertNil(TemporaryDNSPolicy.restoredSystemDNS(current: applied, original: nil))
    }

    func testRestorationPreservesConcurrentSearchDomainChange() {
        let applied: [String: Any] = ["ServerAddresses": ["127.0.0.1"], "ServerPort": 15353, "SearchDomains": ["new.example"]]
        let original: [String: Any] = ["ServerAddresses": ["192.0.2.53"], "SearchDomains": ["old.example"]]
        let restored = TemporaryDNSPolicy.restoredSystemDNS(current: applied, original: original)
        XCTAssertEqual(restored?["ServerAddresses"] as? [String], ["192.0.2.53"])
        XCTAssertEqual(restored?["SearchDomains"] as? [String], ["new.example"])
        XCTAssertNil(restored?["ServerPort"])
    }

    func testUserReplacementOfDNSIsNotOverwritten() {
        let current: [String: Any] = ["ServerAddresses": ["192.0.2.54"], "ServerPort": 53]
        XCTAssertTrue(NSDictionary(dictionary: current).isEqual(to: TemporaryDNSPolicy.restoredSystemDNS(current: current, original: nil)!))
    }

    func testChromiumIdentityUsesMacDesktopUA() {
        XCTAssertFalse(SupportedBrowserUserAgent.chromiumUserAgent.contains("X11; Linux x86_64"))
        XCTAssertTrue(SupportedBrowserUserAgent.chromiumUserAgent.contains("Macintosh"))
        XCTAssertTrue(SupportedBrowserUserAgent.safariCompatibleUserAgent.contains("Macintosh"))
    }
}
