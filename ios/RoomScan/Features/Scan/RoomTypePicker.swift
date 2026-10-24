import SwiftUI

/// Room types offered when a scan starts. Names are localization keys.
struct RoomType: Identifiable, Hashable {
    let id: String          // english name, used as the scan name base
    let symbol: String
    static let all: [RoomType] = [
        .init(id: "Kitchen",      symbol: "refrigerator"),
        .init(id: "Bathroom",     symbol: "shower"),
        .init(id: "Bedroom",      symbol: "bed.double"),
        .init(id: "Living Room",  symbol: "sofa"),
        .init(id: "Dining Room",  symbol: "fork.knife"),
        .init(id: "Office",       symbol: "desktopcomputer"),
        .init(id: "Laundry",      symbol: "washer"),
        .init(id: "Closet",       symbol: "hanger"),
        .init(id: "Hallway",      symbol: "door.left.hand.open"),
        .init(id: "Garage",       symbol: "car"),
        .init(id: "Basement",     symbol: "stairs"),
        .init(id: "Other",        symbol: "square.dashed"),
    ]

    /// "Kitchen" → "Kitchen 2" when a room with that name already exists
    static func uniqueName(_ base: String, existing: [String]) -> String {
        let localized = String(localized: String.LocalizationValue(base))
        guard existing.contains(where: { $0.caseInsensitiveCompare(localized) == .orderedSame }) else { return localized }
        var n = 2
        while existing.contains(where: { $0.caseInsensitiveCompare("\(localized) \(n)") == .orderedSame }) { n += 1 }
        return "\(localized) \(n)"
    }
}

/// Grid of room types + optional custom name. `selection` holds the final scan name.
struct RoomTypeGrid: View {
    @Binding var selection: String
    let existing: [String]
    @State private var picked: String = "Kitchen"
    @State private var custom = ""
    @FocusState private var customFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(RoomType.all) { t in
                    let sel = picked == t.id
                    Button {
                        picked = t.id; customFocused = false
                        selection = RoomType.uniqueName(t.id, existing: existing)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: t.symbol).font(.system(size: 20, weight: .medium))
                            Text(LocalizedStringKey(t.id)).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity).frame(height: 68)
                        .foregroundStyle(sel ? Color.accentColor : .primary)
                        .background(sel ? Color.accentColor.opacity(0.14) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(sel ? Color.accentColor : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "pencil").foregroundStyle(.secondary)
                TextField(String(localized: "Custom name (optional)"), text: $custom)
                    .focused($customFocused)
                    .onChange(of: custom) { _, v in
                        selection = v.nilIfEmpty.map { RoomType.uniqueName($0, existing: existing) } ?? RoomType.uniqueName(picked, existing: existing)
                    }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if !selection.isEmpty {
                Text("Will be saved as **\(selection)**").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { if selection.isEmpty { selection = RoomType.uniqueName(picked, existing: existing) } }
    }
}

/// Sheet: pick a room type → start scanning (used for every room after the first)
struct RoomTypeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existing: [String]
    var onStart: (String) -> Void
    @State private var name = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Which room are you scanning?").font(.title3.weight(.semibold))
                    RoomTypeGrid(selection: $name, existing: existing)
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                Button {
                    onStart(name); dismiss()
                } label: {
                    Label("Start scanning", systemImage: "cube.transparent").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
                .padding(.horizontal, 20).padding(.bottom, 8)
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("New room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
