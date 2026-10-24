import SwiftUI

/// First step of a measurement: confirm the auto-detected address, pick the room, start scanning.
struct NewMeasurementSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onStart: (AddressFields?, String) -> Void

    @State private var address: AddressFields?
    @State private var locating = true
    @State private var locationError: String?
    @State private var showSearch = false
    @State private var roomName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    addressCard
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Room").font(.headline)
                        RoomTypeGrid(selection: $roomName, existing: [])
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                Button {
                    onStart(address, roomName); dismiss()
                } label: {
                    Label("Start scanning", systemImage: "cube.transparent").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(roomName.isEmpty || locating)
                .padding(.horizontal, 20).padding(.bottom, 8)
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("New Measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
            .sheet(isPresented: $showSearch) { AddressSearchView { address = $0; locationError = nil } }
            .task { await locate() }
        }
    }

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Address").font(.headline)
                Spacer()
                if !locating {
                    Button { showSearch = true } label: { Label("Change", systemImage: "magnifyingglass").font(.subheadline.weight(.semibold)) }
                }
            }
            HStack(spacing: 12) {
                Image(systemName: locating ? "location.circle" : (address == nil ? "location.slash" : "location.fill"))
                    .font(.title3).foregroundStyle(address == nil && !locating ? .orange : Color.accentColor)
                    .frame(width: 40, height: 40).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    if locating {
                        Text("Finding your location…").font(.subheadline.weight(.semibold))
                        Text("Usually takes a second").font(.caption).foregroundStyle(.secondary)
                    } else if let a = address {
                        Text(a.line1.isEmpty ? String(localized: "Current location") : a.line1).font(.subheadline.weight(.semibold))
                        Text([a.city, a.state, a.postalCode].filter { !$0.isEmpty }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No address yet").font(.subheadline.weight(.semibold))
                        Text(locationError ?? String(localized: "Search for it or try again")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if locating { ProgressView() }
                else if address == nil {
                    Button { Task { await locate() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func locate() async {
        locating = true; defer { locating = false }
        do { address = try await LocationService.shared.currentAddress(); locationError = nil }
        catch { locationError = error.localizedDescription }
    }
}
