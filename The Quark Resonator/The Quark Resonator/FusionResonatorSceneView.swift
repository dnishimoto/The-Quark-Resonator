// SceneKit -> SwiftUI bridge for FusionResonatorSimulator
import SwiftUI
import SceneKit

struct FusionResonatorSceneView: UIViewRepresentable {
    @ObservedObject var simulator: FusionResonatorSimulator
    @Binding var isZoomedIn: Bool

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = simulator.scene
        view.backgroundColor = UIColor.black
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.pointOfView = simulator.scene.rootNode.childNodes.first { $0.camera != nil }
        return view
    }
    func updateUIView(_ uiView: SCNView, context: Context) {
        // Nothing needed for now; simulator is @ObservedObject.
        if uiView.pointOfView == nil {
            uiView.pointOfView = simulator.scene.rootNode.childNodes.first { $0.camera != nil }
        }
        simulator.setZoomedIn(isZoomedIn)
    }
}
