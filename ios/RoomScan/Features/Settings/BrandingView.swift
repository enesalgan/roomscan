import SwiftUI
import PhotosUI

/// Company details + logo + watermark used on PDF reports
struct BrandingView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    private var store: BrandingStore { BrandingStore.shared }

    @State private var b = Branding()
    @State private var logo: UIImage?
    @State private var logoChanged = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.tertiarySystemFill))
                        if let logo { Image(uiImage: logo).resizable().scaledToFit().padding(8) }
                        else { Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(.secondary) }
                    }
                    .frame(width: 92, height: 92)
                    VStack(alignment: .leading, spacing: 8) {
                        PhotosPicker(selection: $pickerItem, matching: .images) { Label("Choose logo", systemImage: "photo") }
                            .buttonStyle(.bordered)
                        if logo != nil {
                            Button(role: .destructive) { logo = nil; logoChanged = true } label: { Label("Remove", systemImage: "trash") }.font(.footnote)
                        }
                        Text("PNG with transparent background looks best.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: { Text("Logo") }

            Section("Company") {
                TextField("Company name", text: $b.companyName).textContentType(.organizationName)
                TextField("Tagline (e.g. Custom kitchens since 2010)", text: $b.tagline)
                TextField("Phone", text: $b.phone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                TextField("Email", text: $b.email).keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never)
                TextField("Website", text: $b.website).keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never)
                TextField("Address", text: $b.address).textContentType(.fullStreetAddress)
                TextField("License / registration no.", text: $b.license)
            }

            Section {
                Toggle(isOn: $b.watermark) { Label("Watermark on every page", systemImage: "drop.halffull") }
            } footer: {
                Text("Faint logo (or company name) behind the content of each PDF page.")
            }

            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .navigationTitle("Company & branding")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await save() } } label: { if saving { ProgressView() } else { Text("Save").bold() } }
                    .disabled(saving || (session.profile?.isAdmin == false))
            }
        }
        .onAppear { b = store.branding; logo = store.logo }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { logo = img; logoChanged = true }
                pickerItem = nil
            }
        }
    }

    private func save() async {
        saving = true; defer { saving = false }
        do {
            try await store.update(b, logo: logoChanged ? .some(logo) : nil, demo: session.isDemo)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
