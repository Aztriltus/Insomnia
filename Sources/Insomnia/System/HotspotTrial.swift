import CoreWLAN
import Foundation

/// "Try now" in Settings: join the saved hotspot once to check its password,
/// then disconnect so macOS rejoins the network the Mac was on.
enum HotspotTrial {
    enum Result: Equatable, Sendable {
        case worked(bssid: String?, backOn: String?, returned: Bool)
        case rejected(backOn: String?, returned: Bool)
        case notFound
        case noPassword
        case failed

        /// What Settings says under the hotspot row. Pure.
        var message: String? {
            switch self {
            case let .worked(_, backOn, returned), let .rejected(backOn, returned):
                guard let backOn, !returned else { return nil }
                return "Couldn\u{2019}t get back on \(backOn). Choose it in the Wi-Fi menu."
            case .notFound:
                return "Not in range. Open Personal Hotspot on your iPhone and try again."
            case .noPassword:
                return "No saved password. Choose the network again."
            case .failed:
                return "Couldn\u{2019}t try the hotspot."
            }
        }

        /// The join result to record in config.json, if the join got as far
        /// as the password.
        var record: (HotspotJoinRecord.Result, String?)? {
            switch self {
            case let .worked(bssid, _, _): (.worked, bssid)
            case .rejected: (.rejected, nil)
            case .notFound, .noPassword, .failed: nil
            }
        }
    }

    static let returnTimeout: TimeInterval = 20

    /// Runs off the main actor: the scan, the join and the wait for macOS to
    /// rejoin all block.
    static func run(saved: SavedHotspot, password: String) async -> Result {
        await Task.detached {
            guard let interface = CWWiFiClient.shared().interface(), let name = interface.interfaceName else {
                return .failed
            }
            let previous = interface.ssid()
            let outcome: HotspotJoinOutcome
            do {
                outcome = try await CoreWLANHotspotJoiner().join(saved: saved, password: password, interfaceName: name)
            } catch {
                Log.error("hotspot trial failed: \(error.localizedDescription)")
                return .failed
            }
            switch outcome {
            case .notFound:
                return .notFound
            case let .joined(bssid):
                Log.info("hotspot trial: joined \(saved.ssid)")
                let returned = await returnTo(previous, on: interface)
                return .worked(bssid: bssid, backOn: previous, returned: returned)
            case .rejected:
                Log.info("hotspot trial: \(saved.ssid) refused the password")
                let returned = await returnTo(previous, on: interface)
                return .rejected(backOn: previous, returned: returned)
            }
        }.value
    }

    /// Disconnects so macOS's own auto-join picks the previous network, and
    /// waits for it. True when the Mac is back on `previous`, or had no
    /// network to go back to.
    private static func returnTo(_ previous: String?, on interface: CWInterface) async -> Bool {
        guard let previous, !previous.isEmpty else { return true }
        interface.disassociate()
        let deadline = Date().addingTimeInterval(returnTimeout)
        while Date() < deadline {
            if interface.ssid() == previous { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return interface.ssid() == previous
    }
}
