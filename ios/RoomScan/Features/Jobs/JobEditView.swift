import SwiftUI
import MapKit
import CoreLocation

/// Create / edit a job: title, customer, address (with search + current location), schedule, estimate, notes.
struct JobEditView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    let original: Job?
    let scheduledDefault: Date?
    let onSave: (Job) -> Void

    @State private var title = ""
    @State private var customerName = ""
    @State private var customerPhone = ""
    @State private var customerEmail = ""
    @State private var address = AddressFields()
    @State private var hasSchedule = false
    @State private var scheduledAt = Date()
    @State private var estimate = ""
    @State private var notes = ""
    @State private var status: JobStatus = .new
    @State private var showAddressSearch = false
    @State private var locating = false
    @State private var saving = false
    @State private var error: String?

    init(job: Job?, scheduledDefault: Date? = nil, onSave: @escaping (Job) -> Void) {
        self.original = job
        self.scheduledDefault = scheduledDefault
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Job") {
                    TextField("Title (e.g. Kitchen remodel — Smith)", text: $title)
                    if original != nil {
                        Picker("Status", selection: $status) {
                            ForEach(JobStatus.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }

                Section("Customer") {
                    TextField("Name", text: $customerName).textContentType(.name)
                    TextField("Phone", text: $customerPhone).keyboardType(.phonePad).textContentType(.telephoneNumber)
                    TextField("Email", text: $customerEmail).keyboardType(.emailAddress).textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }

                Section("Address") {
                    Button { showAddressSearch = true } label: {
                        Label("Search address", systemImage: "magnifyingglass")
                    }
                    Button { Task { await useCurrentLocation() } } label: {
                        HStack {
                            Label("Use current location", systemImage: "location.fill")
                            if locating { Spacer(); ProgressView() }
                        }
                    }
                    TextField("Street", text: $address.line1).textContentType(.streetAddressLine1)
                    TextField("Apt / Suite", text: $address.line2).textContentType(.streetAddressLine2)
                    TextField("City", text: $address.city).textContentType(.addressCity)
                    HStack {
                        TextField("State", text: $address.state).textContentType(.addressState)
                        TextField("ZIP", text: $address.postalCode).textContentType(.postalCode).keyboardType(.numbersAndPunctuation)
                    }
                    if let lat = address.latitude, let lng = address.longitude {
                        Map(initialPosition: .region(MKCoordinateRegion(
                            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)))) {
                            Marker(title.isEmpty ? "Job" : title, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng))
                        }
                        .frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 8))
                        .listRowInsets(EdgeInsets())
                    }
                }

                Section("Schedule & estimate") {
                    Toggle("Scheduled appointment", isOn: $hasSchedule)
                    if hasSchedule {
                        DatePicker("When", selection: $scheduledAt)
                    }
                    HStack {
                        Text("$")
                        TextField("Estimate", text: $estimate).keyboardType(.decimalPad)
                    }
                }

                Section("Notes") {
                    TextEditor(text: $notes).frame(minHeight: 90)
                }

                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle(original == nil ? "New Job" : "Edit Job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text("Save").bold() }
                    }
                    .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showAddressSearch) {
                AddressSearchView { picked in
                    address = picked
                    if title.isEmpty, !customerName.isEmpty { title = customerName }
                }
            }
            .onAppear(perform: populate)
        }
    }

    private func populate() {
        guard let j = original else {
            if let d = scheduledDefault { hasSchedule = true; scheduledAt = d }
            return
        }
        title = j.title; status = j.status
        customerName = j.customerName ?? ""; customerPhone = j.customerPhone ?? ""; customerEmail = j.customerEmail ?? ""
        address = AddressFields(line1: j.addressLine1 ?? "", line2: j.addressLine2 ?? "", city: j.city ?? "",
                                state: j.state ?? "", postalCode: j.postalCode ?? "", country: j.country ?? "US",
                                latitude: j.latitude, longitude: j.longitude)
        if let s = j.scheduledAt { hasSchedule = true; scheduledAt = s }
        if let e = j.estimateAmount { estimate = String(format: "%.2f", e) }
        notes = j.notes ?? ""
    }

    private func save() async {
        guard let userId = session.userId, let orgId = session.profile?.orgId else { error = "Not signed in"; return }
        saving = true; defer { saving = false }
        var job = original ?? Job(orgId: orgId, createdBy: userId, title: "")
        job.title = title.trimmingCharacters(in: .whitespaces)
        job.status = status
        job.customerName = customerName.nilIfEmpty
        job.customerPhone = customerPhone.nilIfEmpty
        job.customerEmail = customerEmail.nilIfEmpty
        job.addressLine1 = address.line1.nilIfEmpty
        job.addressLine2 = address.line2.nilIfEmpty
        job.city = address.city.nilIfEmpty
        job.state = address.state.nilIfEmpty
        job.postalCode = address.postalCode.nilIfEmpty
        job.country = address.country.nilIfEmpty ?? "US"
        job.latitude = address.latitude
        job.longitude = address.longitude
        job.scheduledAt = hasSchedule ? scheduledAt : nil
        if hasSchedule && job.status == .new { job.status = .scheduled }
        job.estimateAmount = Double(estimate.replacingOccurrences(of: ",", with: ""))
        job.notes = notes.nilIfEmpty
        job.updatedAt = Date()
        do {
            let saved = try await Repository.upsert(job)
            onSave(saved)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func useCurrentLocation() async {
        locating = true; defer { locating = false }
        do {
            address = try await LocationService.shared.currentAddress()
        } catch { self.error = error.localizedDescription }
    }
}

struct AddressFields: Equatable {
    var line1 = "", line2 = "", city = "", state = "", postalCode = "", country = "US"
    var latitude: Double?, longitude: Double?
}

extension String {
    var nilIfEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
