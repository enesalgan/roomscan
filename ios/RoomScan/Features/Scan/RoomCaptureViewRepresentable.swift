import SwiftUI
import RoomPlan
import ARKit
import CoreImage

/// Wraps Apple's RoomCaptureView (RoomPlan) for SwiftUI.
/// The capture session is started only once the view has a real, non-zero size —
/// starting earlier makes RealityKit's render thread abort (zero-size Metal drawable).
struct RoomCaptureViewRepresentable: UIViewRepresentable {
    let controller: ScanController

    func makeUIView(context: Context) -> RoomCaptureContainerView {
        let container = RoomCaptureContainerView(frame: UIScreen.main.bounds)
        container.captureView.delegate = context.coordinator
        container.captureView.captureSession.delegate = context.coordinator
        controller.captureView = container.captureView
        container.onReady = { [controller] in controller.start() }
        return container
    }

    func updateUIView(_ uiView: RoomCaptureContainerView, context: Context) {}

    func makeCoordinator() -> RoomCaptureCoordinator { RoomCaptureCoordinator(controller: controller) }
}

/// Hosts the RoomCaptureView and reports the first layout with a non-zero size.
final class RoomCaptureContainerView: UIView {
    let captureView: RoomCaptureView
    var onReady: (() -> Void)?
    private var readyFired = false

    override init(frame: CGRect) {
        captureView = RoomCaptureView(frame: frame)
        super.init(frame: frame)
        backgroundColor = .black
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captureView.frame = bounds
        addSubview(captureView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        captureView.frame = bounds
        if !readyFired, bounds.width > 10, bounds.height > 10, window != nil {
            readyFired = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.onReady?() }
        }
    }
}

@objc(RoomCaptureCoordinator)
final class RoomCaptureCoordinator: NSObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    let controller: ScanController
    init(controller: ScanController) {
        self.controller = controller
        super.init()
    }

    func encode(with coder: NSCoder) {}
    required init?(coder: NSCoder) { return nil }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        if let error { Task { @MainActor in controller.error = error.localizedDescription } }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor in
            if let error { controller.error = error.localizedDescription }
            controller.finished(room: processedResult)
        }
    }

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        Task { @MainActor in controller.liveRoom = room }
    }

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        Task { @MainActor in controller.instruction = instruction }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        if let error { Task { @MainActor in controller.error = error.localizedDescription } }
    }
}

@Observable
@MainActor
final class ScanController {
    enum Phase { case idle, scanning, processing, done }

    var phase: Phase = .idle
    var liveRoom: CapturedRoom?
    var finalRoom: CapturedRoom?
    var instruction: RoomCaptureSession.Instruction?
    var error: String?
    weak var captureView: RoomCaptureView?

    func start() {
        guard phase == .idle, let captureView else { return }
        var config = RoomCaptureSession.Configuration()
        config.isCoachingEnabled = true
        captureView.captureSession.run(configuration: config)
        phase = .scanning
    }

    func stop() {
        guard phase == .scanning else { return }
        phase = .processing
        captureView?.captureSession.stop()
    }

    func cancel() {
        captureView?.captureSession.stop(pauseARSession: true)
        phase = .idle
    }

    func finished(room: CapturedRoom) {
        finalRoom = room
        phase = .done
    }

    func capturePhoto() -> UIImage? {
        guard let frame = captureView?.captureSession.arSession.currentFrame else { return nil }
        let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    func snapshot() -> UIImage? {
        guard let v = captureView else { return nil }
        let r = UIGraphicsImageRenderer(bounds: v.bounds)
        return r.image { _ in v.drawHierarchy(in: v.bounds, afterScreenUpdates: true) }.resized(maxDimension: 600)
    }

    var instructionText: String? {
        switch instruction {
        case .moveCloseToWall: "Move closer to the wall"
        case .moveAwayFromWall: "Move away from the wall"
        case .slowDown: "Slow down"
        case .turnOnLight: "Turn on more light"
        case .lowTexture: "Point at textured surfaces"
        case .normal, .none: nil
        @unknown default: nil
        }
    }
}
