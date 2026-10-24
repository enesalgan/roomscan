import SwiftUI

/// Window / door styles the user can swap in ("Replace with…").
struct OpeningStyle: Identifiable, Hashable {
    let id: String
    let kind: OpeningKind
    let name: String          // localization key
    let symbol: String        // SF Symbol
}

enum OpeningCatalog {
    static let windows: [OpeningStyle] = [
        .init(id: "hung",     kind: .window, name: "Hung Window",     symbol: "window.vertical.closed"),
        .init(id: "casement", kind: .window, name: "Casement Window", symbol: "window.casement"),
        .init(id: "sliding",  kind: .window, name: "Sliding Window",  symbol: "window.horizontal"),
        .init(id: "fixed",    kind: .window, name: "Fixed Window",    symbol: "rectangle"),
        .init(id: "awning",   kind: .window, name: "Awning Window",   symbol: "window.awning"),
        .init(id: "picture",  kind: .window, name: "Picture Window",  symbol: "rectangle.inset.filled"),
        .init(id: "bay",      kind: .window, name: "Bay Window",      symbol: "window.shade.open"),
        .init(id: "bow",      kind: .window, name: "Bow Window",      symbol: "window.shade.closed"),
    ]
    static let doors: [OpeningStyle] = [
        .init(id: "hinged",  kind: .door, name: "Hinged Door",   symbol: "door.left.hand.closed"),
        .init(id: "sliding", kind: .door, name: "Sliding Door",  symbol: "door.sliding.left.hand.closed"),
        .init(id: "french",  kind: .door, name: "French Door",   symbol: "door.french.closed"),
        .init(id: "pocket",  kind: .door, name: "Pocket Door",   symbol: "door.sliding.right.hand.closed"),
        .init(id: "bifold",  kind: .door, name: "Bifold Door",   symbol: "door.left.hand.open"),
        .init(id: "garage",  kind: .door, name: "Garage Door",   symbol: "door.garage.closed"),
        .init(id: "opening", kind: .opening, name: "Opening",    symbol: "rectangle.portrait"),
    ]
    static var all: [OpeningStyle] { windows + doors }

    static func style(for o: PlanOpening) -> OpeningStyle {
        if let id = o.style, let s = all.first(where: { $0.id == id }) { return s }
        switch o.kind {
        case .window: return windows[0]
        case .door: return doors[0]
        case .opening: return doors.last!
        }
    }
}

/// Grid picker for a replacement style
struct OpeningStylePicker: View {
    @Environment(\.dismiss) private var dismiss
    let current: PlanOpening
    let onPick: (OpeningStyle) -> Void
    @State private var search = ""

    private var items: [OpeningStyle] {
        let base = current.kind == .window ? OpeningCatalog.windows : OpeningCatalog.doors
        return search.isEmpty ? base : base.filter { String(localized: String.LocalizationValue($0.name)).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(items) { st in
                        Button { onPick(st); dismiss() } label: {
                            VStack(spacing: 10) {
                                Image(systemName: st.symbol).font(.system(size: 40, weight: .light))
                                    .frame(height: 70).foregroundStyle(Color.accentColor)
                                Text(LocalizedStringKey(st.name)).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(OpeningCatalog.style(for: current).id == st.id ? Color.accentColor : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(current.kind == .window ? "Windows" : "Doors")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
        }
    }
}
