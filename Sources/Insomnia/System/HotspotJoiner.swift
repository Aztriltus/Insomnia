import CoreWLAN
import Foundation

/// What a failover join did.
enum HotspotJoinOutcome: Equatable, Sendable {
    /// Associated; carries the hardware address joined, to remember.
    case joined(bssid: String?)
    /// No network in the scan matched the saved hotspot.
    case notFound
    /// The network refused the saved password.
    case rejected
}

protocol HotspotJoining: Sendable {
    func join(saved: SavedHotspot, password: String, interfaceName: String) async throws -> HotspotJoinOutcome
}

enum HotspotJoinError: Error, LocalizedError {
    case missingInterface(String)

    var errorDescription: String? {
        switch self {
        case let .missingInterface(name):
            return "CoreWLAN could not open Wi-Fi interface \(name)"
        }
    }
}

struct CoreWLANHotspotJoiner: HotspotJoining {
    func join(saved: SavedHotspot, password: String, interfaceName: String) async throws -> HotspotJoinOutcome {
        guard let interface = CWWiFiClient.shared().interface(withName: interfaceName) else {
            throw HotspotJoinError.missingInterface(interfaceName)
        }
        // Unfiltered: a hardware-address match needs every result. macOS
        // needs Location Services to show names and addresses.
        let networks = Array(try interface.scanForNetworks(withName: nil))
        let scanned = networks.map(WiFiScanner.scanned)
        guard let pick = HotspotMatcher.pick(saved: saved, scan: scanned),
              let index = scanned.firstIndex(of: pick)
        else { return .notFound }
        do {
            try interface.associate(to: networks[index], password: pick.security == HotspotSecurity.open ? nil : password)
        } catch let error as NSError where WiFiScanner.isAuthenticationFailure(error) {
            return .rejected
        }
        return .joined(bssid: pick.bssid)
    }
}

/// Reads nearby networks for the hotspot sheet, and what macOS already
/// knows about them.
enum WiFiScanner {
    static func scanned(_ n: CWNetwork) -> ScannedNetwork {
        ScannedNetwork(ssid: n.ssid ?? "", bssid: n.bssid?.lowercased(), security: security(of: n), rssi: n.rssiValue)
    }

    /// A stable name for the network's security mode. The same function is
    /// used when saving and when matching, so the two always agree.
    static func security(of n: CWNetwork) -> String {
        if n.supportsSecurity(.none) || n.supportsSecurity(.OWE) { return HotspotSecurity.open }
        if n.supportsSecurity(.wpa2Personal) || n.supportsSecurity(.wpaPersonal) || n.supportsSecurity(.wpaPersonalMixed) {
            return HotspotSecurity.wpaPersonal
        }
        if n.supportsSecurity(.wpa3Personal) || n.supportsSecurity(.wpa3Transition) { return HotspotSecurity.wpa3Personal }
        if n.supportsSecurity(.wpa2Enterprise) || n.supportsSecurity(.wpaEnterprise) || n.supportsSecurity(.wpa3Enterprise) {
            return HotspotSecurity.enterprise
        }
        return HotspotSecurity.other
    }

    /// CoreWLAN's errors for a password the network refused: a challenge
    /// failure (-3912), an invalid PMK (-3924, a wrong WPA passphrase) and
    /// a supplicant timeout (-3925, the 4-way handshake never completed).
    /// A plain timeout (-3905) is not one: the network may have gone out of
    /// range.
    static let authenticationFailureCodes: Set<Int> = [-3912, -3924, -3925]

    static func isAuthenticationFailure(_ error: NSError) -> Bool {
        error.domain == CWErrorDomain && authenticationFailureCodes.contains(error.code)
    }

    /// A scan of every network in range, off the main actor.
    static func scan() async throws -> [ScannedNetwork] {
        try await Task.detached {
            guard let interface = CWWiFiClient.shared().interface() else { return [] }
            return try interface.scanForNetworks(withName: nil).map(scanned)
        }.value
    }

    /// The network the Mac is on now, if any.
    static func currentSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    /// The networks macOS has saved, with their security, whether or not
    /// they're in range.
    static func savedNetworks() -> [(ssid: String, security: String)] {
        guard let profiles = CWWiFiClient.shared().interface()?.configuration()?.networkProfiles else { return [] }
        return profiles.compactMap { item in
            guard let profile = item as? CWNetworkProfile, let ssid = profile.ssid, !ssid.isEmpty else { return nil }
            return (ssid, security(of: profile.security))
        }
    }

    /// The same names as `security(of: CWNetwork)` gives a network that
    /// supports this mode, so a saved profile and a scan agree.
    static func security(of mode: CWSecurity) -> String {
        switch mode {
        case .none, .OWE, .oweTransition: HotspotSecurity.open
        case .wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .personal, .wpa3Transition: HotspotSecurity.wpaPersonal
        case .wpa3Personal: HotspotSecurity.wpa3Personal
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise, .wpa3Enterprise: HotspotSecurity.enterprise
        default: HotspotSecurity.other
        }
    }

    /// The password macOS saved for `ssid`. Your own keychain is tried
    /// first, which an iCloud-synced hotspot is usually in; only if it isn't
    /// there does macOS show its own administrator dialog for the System
    /// keychain. Insomnia never sees what is typed there. nil when cancelled
    /// or when macOS has none.
    static func savedPassword(for ssid: String) async -> String? {
        await Task.detached {
            for domain in [CWKeychainDomain.user, .system] {
                var password: NSString?
                let status = CWKeychainFindWiFiPassword(domain, Data(ssid.utf8), &password)
                if status == errSecSuccess, let found = password as String?, !found.isEmpty {
                    return found
                }
                Log.info("saved Wi-Fi password not in the \(domain == .user ? "login" : "System") keychain (OSStatus \(status))")
            }
            return nil
        }.value
    }
}
