import Combine
import SwiftUI

/// Choosing the backup hotspot from the networks the Mac can see (redesign
/// spec, section 3). Never joins a network: the scan gives the name,
/// hardware addresses and security, and the password is typed or copied
/// from what macOS saved.
struct HotspotSetupSheet: View {
    let locationPermission: LocationPermission
    let onSave: (HotspotMatcher.Row, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [HotspotMatcher.Row] = []
    @State private var known: Set<String> = []
    @State private var current: String?
    @State private var chosen: HotspotMatcher.Row?
    @State private var password = ""
    @State private var scanning = false
    @State private var scanError: String?
    @State private var asking = false
    @State private var askFailed = false

    private let refresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hotspot backup").font(.headline)
            if !locationPermission.isAuthorized {
                locationGate
            } else {
                networkList
                if let chosen { passwordArea(chosen) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if let chosen {
                    Button("Save") { save(chosen) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(problem(chosen) != nil || asking)
                }
            }
        }
        .padding(16)
        .frame(width: 440)
        .task { await rescan() }
        .onReceive(refresh) { _ in Task { await rescan() } }
    }

    private var locationGate: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow Location Services to see Wi-Fi names. Your location isn\u{2019}t read.")
                .fixedSize(horizontal: false, vertical: true)
            if locationPermission.isDenied {
                Button("Open Location Services") { locationPermission.openLocationServicesSettings() }
            } else {
                Button("Allow") { locationPermission.requestWhenInUse() }
            }
        }
    }

    private var networkList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Nearby networks").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if scanning { ProgressView().controlSize(.small) }
                Button("Rescan") { Task { await rescan() } }.disabled(scanning)
            }
            List(rows, selection: Binding(get: { chosen?.id }, set: { id in choose(rows.first { $0.id == id }) })) { row in
                HStack {
                    if row.inRange {
                        Image(systemName: "wifi", variableValue: Double(HotspotMatcher.bars(rssi: row.rssi)) / 3)
                            .accessibilityLabel("Signal \(HotspotMatcher.bars(rssi: row.rssi)) of 3")
                    } else {
                        Image(systemName: "wifi.slash")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Not in range")
                    }
                    Text(row.ssid)
                    Spacer()
                    if row.ssid == current {
                        Text("Connected").font(.caption).foregroundStyle(.secondary)
                    } else if !row.inRange {
                        Text("Not in range").font(.caption).foregroundStyle(.secondary)
                    } else if known.contains(row.ssid) {
                        Text("Saved").font(.caption).foregroundStyle(.secondary)
                    }
                    if row.isSecured {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Has a password")
                    }
                }
                .tag(row.id)
            }
            .frame(height: 200)
            if let scanError {
                Text(scanError).font(.caption).foregroundStyle(.orange)
            }
            Text("Not listed? Open Personal Hotspot on your iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func passwordArea(_ row: HotspotMatcher.Row) -> some View {
        if row.isSecured {
            VStack(alignment: .leading, spacing: 6) {
                if known.contains(row.ssid), password.isEmpty, !askFailed {
                    Button(asking ? "Waiting for macOS\u{2026}" : "Use saved password") { useSaved(row) }
                        .disabled(asking)
                    Text("macOS may ask for your Mac password.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SecureField("Password for \(row.ssid)", text: $password)
                    .textFieldStyle(.roundedBorder)
                if let problem = problem(row), !password.isEmpty {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
            }
        } else {
            Text("No password needed").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func choose(_ row: HotspotMatcher.Row?) {
        guard row?.id != chosen?.id else { return }
        chosen = row
        password = ""
        askFailed = false
    }

    private func problem(_ row: HotspotMatcher.Row) -> String? {
        if row.isSecured, password.isEmpty { return "Enter the password." }
        if row.inRange, !rows.contains(where: { $0.ssid == row.ssid }) { return "This network is no longer in range. Rescan and choose it again." }
        return HotspotSecurity.passwordProblem(password, security: row.security)
    }

    private func useSaved(_ row: HotspotMatcher.Row) {
        asking = true
        Task {
            let saved = await WiFiScanner.savedPassword(for: row.ssid)
            asking = false
            if let saved, !saved.isEmpty {
                password = saved
            } else {
                askFailed = true
            }
        }
    }

    private func save(_ row: HotspotMatcher.Row) {
        guard problem(row) == nil else { return }
        // The row as last scanned, with every address seen.
        let latest = rows.first { $0.ssid == row.ssid } ?? row
        onSave(latest, row.isSecured ? password : "")
        dismiss()
    }

    private func rescan() async {
        guard locationPermission.isAuthorized, !scanning else { return }
        scanning = true
        defer { scanning = false }
        do {
            let scan = try await WiFiScanner.scan()
            let saved = WiFiScanner.savedNetworks()
            rows = HotspotMatcher.addingSaved(HotspotMatcher.rows(scan), saved: saved)
            known = Set(saved.map(\.ssid))
            current = WiFiScanner.currentSSID()
            scanError = rows.isEmpty ? "No networks found. Is Wi-Fi on?" : nil
        } catch {
            scanError = "Couldn\u{2019}t scan for networks: \(error.localizedDescription)"
        }
    }
}
