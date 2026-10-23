import XCTest
@testable import InputPilot

final class WireGuardConfigurationTests: XCTestCase {
    private let valid = """
    [Interface]
    PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    Address = 10.7.0.23/32
    DNS = 10.7.0.1

    [Peer]
    PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
    PresharedKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=
    AllowedIPs = 10.7.0.0/24
    Endpoint = vpn.example.test:51820
    PersistentKeepalive = 25
    """

    func testParsesSupportedSinglePeerConfiguration() throws {
        let configuration = try WireGuardConfiguration.parse(valid)
        XCTAssertEqual(configuration.address, "10.7.0.23")
        XCTAssertEqual(configuration.endpoint, "vpn.example.test:51820")
        XCTAssertEqual(configuration.allowedIPs, "10.7.0.0/24")
    }

    func testAcceptsRepeatedDNSLines() throws {
        let configuration = valid.replacingOccurrences(
            of: "DNS = 10.7.0.1",
            with: "DNS = 10.7.0.1\nDNS = 1.1.1.1"
        )
        XCTAssertNoThrow(try WireGuardConfiguration.parse(configuration))
    }

    func testRejectsMultiplePeers() {
        XCTAssertThrowsError(try WireGuardConfiguration.parse(valid + "\n[Peer]\n")) {
            XCTAssertEqual($0 as? WireGuardConfigurationError, .multiplePeers)
        }
    }

    func testRejectsIPv6() {
        let configuration = valid.replacingOccurrences(of: "10.7.0.23/32", with: "fd00::23/128")
        XCTAssertThrowsError(try WireGuardConfiguration.parse(configuration)) {
            XCTAssertEqual($0 as? WireGuardConfigurationError, .ipv6Unsupported)
        }
    }

    func testRejectsHooksAndMultipleAllowedRanges() {
        let hook = valid.replacingOccurrences(of: "Address =", with: "PostUp = reboot\nAddress =")
        XCTAssertThrowsError(try WireGuardConfiguration.parse(hook))

        let ranges = valid.replacingOccurrences(
            of: "AllowedIPs = 10.7.0.0/24",
            with: "AllowedIPs = 10.7.0.0/24, 192.168.1.0/24"
        )
        XCTAssertThrowsError(try WireGuardConfiguration.parse(ranges)) {
            XCTAssertEqual($0 as? WireGuardConfigurationError, .multipleAllowedIPs)
        }
    }

    func testRejectsAllowedRangeThatCannotRouteTheInterface() {
        let configuration = valid.replacingOccurrences(
            of: "AllowedIPs = 10.7.0.0/24",
            with: "AllowedIPs = 192.168.50.0/24"
        )
        XCTAssertThrowsError(try WireGuardConfiguration.parse(configuration)) {
            XCTAssertEqual($0 as? WireGuardConfigurationError, .allowedIPsRouteMismatch)
        }
    }

    func testDecodesCompactDeviceStatusWithoutSecrets() throws {
        let json = #"{"c":true,"e":true,"s":"connected","ip":"10.7.0.23","r":true,"n":1,"x":""}"#
        let status = try JSONDecoder().decode(WireGuardDeviceStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.state, .connected)
        XCTAssertEqual(status.ip, "10.7.0.23")
        XCTAssertEqual(status.ssidCount, 1)
        XCTAssertEqual(status.ssids, [])
        XCTAssertFalse(json.lowercased().contains("privatekey"))
    }
}
