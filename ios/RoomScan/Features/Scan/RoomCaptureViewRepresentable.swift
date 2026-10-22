import SwiftUI
import RoomPlan
import ARKit

/// Wraps Apple's RoomCaptureView (RoomPlan) for SwiftUI.
/// Controller drives start / stop and receives the processed CapturedRoom.
struct RoomCaptureViewRepresentable: UIViewRepresentable {
    let controller: ScanController

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        view.delegate = context.coordinator
        view.captureSession.delegate = context.coordinator
        controller.captureView = view
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    // RoomCaptureViewDelegate inherits NSCoding, hence the encode/init(coder:) boilerplate.
    final class Coordinator: NSObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
        let controller: ScanController
        init(controller: ScanController) { self.controller = controller }

        func encode(with coder: NSCoder) {}
        required init?(coder: NSCoder) { return nil }

        // Ask RoomPlan to post-process and show the final model when the session ends.
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

        // Live session feedback
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
        captureView?.captureSession.stop()   // → shouldPresent → didPresent
    }

    func cancel() {
        captureView?.captureSession.stop(pauseARSession: true)
        phase = .idle
    }

    func finished(room: CapturedRoom) {
        finalRoom = room
        phase = .done
    }

    /// Snapshot of the rendered model view (used as a thumbnail)
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
        case .normal, .none: nil
        case .lowTexture: "Point at textured surfaces"
        @unknown default: nil
        }
    }
}
