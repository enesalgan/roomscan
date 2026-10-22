import SwiftUI
import QuickLook
import SceneKit

/// Shows a saved scan: 3D model (SceneKit) + measurements, with share and AR Quick Look.
struct ScanPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let scan: Scan

    @State private var modelURL: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if let modelURL {
                        USDZSceneView(url: modelURL)
                    } else if let error {
                        ContentUnavailableView("Couldn't load model", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else {
                        ProgressView("Downloading model…")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 320)
                .background(Color(.secondarySystemBackground))

                List {
                    Section("Measurements") {
                        LabeledContent("Size", value: "\(scan.summary.widthM.feetInches) × \(scan.summary.depthM.feetInches)")
                        LabeledContent("Ceiling", value: scan.summary.heightM.feetInches)
                        if let a = scan.floorAreaM2 { LabeledContent("Floor area", value: a.squareFeet) }
                        LabeledContent("Perimeter", value: scan.summary.perimeterM.feetInches)
                        LabeledContent("Walls / Doors / Windows", value: "\(scan.summary.walls) / \(scan.summary.doors) / \(scan.summary.windows)")
                        LabeledContent("Metric", value: "\(scan.summary.widthM.meters) × \(scan.summary.depthM.meters)")
                    }
                    if !scan.summary.objects.isEmpty {
                        Section("Detected objects") {
                            ForEach(scan.summary.objects.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                                LabeledContent(k.capitalized, value: "\(v)")
                            }
                        }
                    }
                }
            }
            .navigationTitle(scan.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let modelURL {
                        Button { previewItem = modelURL } label: { Image(systemName: "arkit") }
                        ShareLink(item: modelURL) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
            .quickLookPreview($previewItem)
            .task {
                do { modelURL = try await Repository.localUSDZ(for: scan) }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    @State private var previewItem: URL?
}

/// SceneKit viewer for a USDZ file with orbit camera
struct USDZSceneView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        if let scene = try? SCNScene(url: url) {
            v.scene = scene
            // Frame the model
            let (center, radius) = scene.rootNode.boundingSphere
            let cam = SCNNode()
            cam.camera = SCNCamera()
            cam.camera?.zFar = 1000
            cam.position = SCNVector3(center.x + radius * 1.2, center.y + radius * 1.4, center.z + radius * 1.6)
            cam.look(at: center)
            scene.rootNode.addChildNode(cam)
            v.pointOfView = cam
        }
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
