import SwiftUI
import SceneKit
import UIKit

/// 3D model generated from the editable FloorPlan (walls with door/window cut-outs, floor, objects).
/// Rebuilds whenever the plan changes, so edits in 2D show up here immediately.
struct Plan3DView: UIViewRepresentable {
    let plan: FloorPlan

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.antialiasingMode = .multisampling4X
        v.backgroundColor = UIColor.systemGroupedBackground
        v.scene = Self.makeScene(plan)
        context.coordinator.hash = plan.hashValue
        return v
    }

    func updateUIView(_ v: SCNView, context: Context) {
        guard context.coordinator.hash != plan.hashValue else { return }
        context.coordinator.hash = plan.hashValue
        let oldTransform = v.pointOfView?.transform
        v.scene = Self.makeScene(plan)
        if let oldTransform, let cam = v.scene?.rootNode.childNode(withName: "camera", recursively: false) {
            cam.transform = oldTransform          // keep the user's camera angle
            v.pointOfView = cam
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var hash = 0 }

    // MARK: Scene building

    static func makeScene(_ plan: FloorPlan) -> SCNScene {
        let scene = SCNScene()
        guard plan.wallCount >= 3 else { return scene }

        let wallMat = SCNMaterial()
        wallMat.diffuse.contents = UIColor(white: 0.93, alpha: 1)
        wallMat.isDoubleSided = true
        let edgeMat = SCNMaterial()
        edgeMat.diffuse.contents = UIColor(white: 0.25, alpha: 1)
        edgeMat.isDoubleSided = true

        // Floor
        let floorPath = UIBezierPath()
        floorPath.move(to: CGPoint(x: plan.corners[0].x, y: plan.corners[0].y))
        for c in plan.corners.dropFirst() { floorPath.addLine(to: CGPoint(x: c.x, y: c.y)) }
        floorPath.close()
        let floorShape = SCNShape(path: floorPath, extrusionDepth: 0.02)
        let floorMat = SCNMaterial()
        floorMat.diffuse.contents = UIColor(red: 0.78, green: 0.70, blue: 0.60, alpha: 1)
        floorMat.isDoubleSided = true
        floorShape.materials = [floorMat]
        let floorNode = SCNNode(geometry: floorShape)
        floorNode.eulerAngles.x = .pi / 2          // path (x, y) → world (x, 0, y)
        floorNode.position.y = -0.01
        scene.rootNode.addChildNode(floorNode)

        // Walls
        for i in 0..<plan.wallCount {
            let L = plan.wallLength(i), H = plan.wallHeight
            guard L > 0.01 else { continue }
            let path = UIBezierPath(rect: CGRect(x: 0, y: 0, width: L, height: H))
            for o in plan.openings(on: i) {
                let hole = UIBezierPath(rect: CGRect(x: o.left, y: o.sill, width: o.width, height: min(o.height, H - o.sill)))
                path.append(hole.reversing())
            }
            path.usesEvenOddFillRule = true
            let shape = SCNShape(path: path, extrusionDepth: plan.wallThickness)
            shape.materials = [wallMat, edgeMat, wallMat]   // front, back, side (SCNShape: front/back/extruded sides)
            let node = SCNNode(geometry: shape)
            let s = plan.wallStart(i), d = plan.wallDirection(i)
            node.position = SCNVector3(Float(s.x), 0, Float(s.y))
            node.eulerAngles.y = Float(-atan2(d.y, d.x))   // local +x → plan direction in the XZ plane
            scene.rootNode.addChildNode(node)
        }

        // Objects (appliances / furniture detected by RoomPlan)
        let objMat = SCNMaterial()
        objMat.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.35)
        for o in plan.objects {
            let box = SCNBox(width: o.width, height: o.height, length: o.depth, chamferRadius: 0.01)
            box.materials = [objMat]
            let n = SCNNode(geometry: box)
            n.position = SCNVector3(Float(o.center.x), Float(o.height / 2), Float(o.center.y))
            n.eulerAngles.y = Float(-o.rotation)
            scene.rootNode.addChildNode(n)
        }

        // Camera: isometric-ish from the front-left, looking at the room center
        let b = plan.bounds
        let center = SCNVector3(Float((b.min.x + b.max.x) / 2), Float(plan.wallHeight / 2), Float((b.min.y + b.max.y) / 2))
        let radius = Float(max(plan.width, plan.depth, plan.wallHeight)) * 1.25
        let cam = SCNNode()
        cam.name = "camera"
        cam.camera = SCNCamera()
        cam.camera?.zFar = 500
        cam.position = SCNVector3(center.x - radius, center.y + radius * 0.9, center.z + radius)
        cam.look(at: center)
        scene.rootNode.addChildNode(cam)

        let light = SCNNode()
        light.light = SCNLight(); light.light?.type = .directional; light.light?.intensity = 600
        light.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(light)
        return scene
    }
}
