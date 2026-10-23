import SwiftUI
import PhotosUI

/// Photo grid inside the job detail list: camera capture, library picker, full-screen view, delete.
struct PhotosSection: View {
    @Environment(SessionStore.self) private var session
    let job: Job
    @Binding var photos: [Photo]

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var uploading = 0
    @State private var error: String?
    @State private var selected: Photo?

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 8)]

    var body: some View {
        Section {
            toolbar
            if !photos.isEmpty {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(photos) { photo in
                        PhotoCell(photo: photo)
                            .onTapGesture { selected = photo }
                            .contextMenu {
                                Button(role: .destructive) { Task { await delete(photo) } } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        } header: {
            Text("Photos (\(photos.count))")
        }
    }

    /// Camera/library buttons; presentation modifiers live here (not on Section, which List flattens).
    private var toolbar: some View {
        HStack {
            Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                .buttonStyle(.bordered)
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .images) {
                Label("Library", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.bordered)
            if uploading > 0 { Spacer(); ProgressView(); Text("\(uploading)").font(.caption) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView { image in Task { await upload([image]) } }
                .ignoresSafeArea()
        }
        .sheet(item: $selected) { p in
            PhotoViewer(photo: p) { Task { await delete(p) } }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var images: [UIImage] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { images.append(img) }
                }
                pickerItems = []
                await upload(images)
            }
        }
    }

    private func upload(_ images: [UIImage]) async {
        guard let userId = session.userId else { return }
        uploading += images.count
        for img in images {
            do {
                let p = try await Repository.addPhoto(jobId: job.id, orgId: job.orgId, userId: userId, image: img)
                photos.append(p)
            } catch { self.error = error.localizedDescription }
            uploading -= 1
        }
    }

    private func delete(_ photo: Photo) async {
        do { try await Repository.deletePhoto(photo); photos.removeAll { $0.id == photo.id } }
        catch { self.error = error.localizedDescription }
    }
}

struct PhotoCell: View {
    let photo: Photo
    @State private var url: URL?
    var body: some View {
        AsyncImage(url: url) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            ZStack { Color.secondary.opacity(0.1); ProgressView() }
        }
        .frame(width: 90, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task { url = try? await Repository.signedURL(bucket: "photos", path: photo.storagePath) }
    }
}

struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let photo: Photo
    var onDelete: () -> Void = {}
    @State private var url: URL?
    @State private var confirm = false
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFit()
                } placeholder: { ProgressView().tint(.white) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirm = true } label: { Image(systemName: "trash") }
                }
            }
            .confirmationDialog("Delete this photo?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { onDelete(); dismiss() }
            }
            .task { url = try? await Repository.signedURL(bucket: "photos", path: photo.storagePath) }
        }
    }
}

/// UIImagePickerController camera wrapper
struct CameraView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onCapture(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
