import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(SessionStore.self) private var session
    @Environment(StoreService.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Product?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "cube.transparent.fill").font(.system(size: 48)).foregroundStyle(.tint)
                        Text("RoomScan Pro").font(.title.bold())
                        Text("You've used \(session.entitlement.scansUsed) of \(Config.freeScans) free scans.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top)

                    VStack(alignment: .leading, spacing: 10) {
                        feature("infinity", "Unlimited LiDAR room scans")
                        feature("person.3", "Unlimited team members per branch")
                        feature("icloud.and.arrow.up", "Cloud storage for models and photos")
                        feature("globe", "Send scans to the online kitchen designer")
                    }
                    .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                    if store.isLoading {
                        ProgressView()
                    } else if store.products.isEmpty {
                        Text("Products are not available right now.").foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(store.subscriptions, id: \.id) { p in planRow(p) }
                            if !store.consumables.isEmpty {
                                Divider().padding(.vertical, 4)
                                ForEach(store.consumables, id: \.id) { p in planRow(p, isPack: true) }
                            }
                        }
                    }

                    if let e = store.lastError { Text(e).foregroundStyle(.red).font(.footnote) }

                    Button {
                        Task { await buy() }
                    } label: {
                        HStack {
                            if store.purchaseInProgress { ProgressView().tint(.white) }
                            Text(selected.map { "Continue — \($0.displayPrice)" } ?? "Choose a plan").bold()
                        }
                        .frame(maxWidth: .infinity).padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected == nil || store.purchaseInProgress)

                    HStack {
                        Button("Restore purchases") { Task { await store.restore(); await session.refreshEntitlement(); if session.entitlement.subscribed { dismiss() } } }
                        Spacer()
                        Link("Terms", destination: URL(string: "https://lixisoft.com/roomscan/terms")!)
                        Link("Privacy", destination: URL(string: "https://lixisoft.com/roomscan/privacy")!)
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } } }
            .onAppear { if selected == nil { selected = store.subscriptions.last ?? store.products.first } }
        }
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.subheadline)
    }

    private func planRow(_ p: Product, isPack: Bool = false) -> some View {
        Button { selected = p } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.displayName).font(.headline)
                    Text(isPack ? p.description : (p.subscription?.subscriptionPeriod.unit == .year ? "Billed yearly" : "Billed monthly"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Text(p.displayPrice).font(.headline)
                Image(systemName: selected?.id == p.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected?.id == p.id ? Color.accentColor : .secondary)
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected?.id == p.id ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func buy() async {
        guard let selected else { return }
        if await store.purchase(selected) {
            await session.refreshEntitlement()
            dismiss()
        }
    }
}
