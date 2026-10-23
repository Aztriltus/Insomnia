import AppKit
import SwiftUI

/// Lays children out left to right, wrapping to a new row when the width
/// runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows.removeLast()
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows.append(row)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// An app in one of the lists: its icon and name, and a button to remove it.
struct AppChip: View {
    let app: InstalledApp
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: InstalledApps.icon(for: app))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(app.name)
                .font(.caption)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(app.name)")
        }
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// A duration chip, for the Durations section.
struct TextChip: View {
    let text: String
    let removeLabel: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(text).font(.caption).monospacedDigit()
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(removeLabel)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// The "+" at the end of a row of chips.
struct AddChipButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(.quaternary.opacity(0.6), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// Typing a new duration for the Durations section.
struct AddDurationPopover: View {
    let templates: [TimeInterval]
    let add: (TimeInterval) -> Void
    @State private var text = ""

    private var status: SessionMenu.FieldStatus { SessionMenu.fieldStatus(text, mode: .start) }

    private var problem: String? {
        guard case let .valid(d, _) = status else { return status == .invalid ? SessionMenu.customHint : nil }
        switch TemplateList.adding(d, to: templates) {
        case .duplicate: return "That one's already there."
        case .full: return "Templates full. Remove one first."
        case .added, .outOfRange: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("45m, 2h or 1d", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit(submit)
            HStack {
                Text(problem ?? " ").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add", action: submit).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func submit() {
        guard case let .valid(d, _) = status, problem == nil else { return }
        add(d)
    }
}

extension Config.AppList: Identifiable {
    var id: String {
        switch self {
        case .pause: "pause"
        case .fullSpeed: "fullSpeed"
        }
    }

    var title: String {
        switch self {
        case .pause: "Pause when the lid closes"
        case .fullSpeed: "Keep at full speed"
        }
    }

    var other: Config.AppList { self == .pause ? .fullSpeed : .pause }
}

/// The installed apps, searchable, as a grid of icons. Clicking one toggles
/// it in `list`; one in the other list is moved.
struct AppPickerSheet: View {
    let list: Config.AppList
    let apps: [InstalledApp]
    let config: Config
    let toggle: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var shown: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(list.title).font(.headline)
            TextField("Search apps", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 10) {
                    ForEach(shown) { app in
                        tile(app)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 320)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func tile(_ app: InstalledApp) -> some View {
        let selected = config.contains(app.bundleID, in: list)
        let elsewhere = config.contains(app.bundleID, in: list.other)
        return Button { toggle(app.bundleID) } label: {
            VStack(spacing: 4) {
                Image(nsImage: InstalledApps.icon(for: app))
                    .resizable()
                    .frame(width: 32, height: 32)
                    .overlay(alignment: .bottomTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white, Color.accentColor)
                                .offset(x: 4, y: 4)
                        }
                    }
                Text(app.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if elsewhere {
                    Text("In \(list.other.title)")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(6)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? "\(app.name), in list" : app.name)
    }
}
