//
//  File.swift
//  The Quark Resonator
//
//  Created by David Nishimoto on 9/30/26.
//

import Foundation
import SwiftUI
import SceneKit

struct QuarkResonatorSceneView:
    UIViewRepresentable {

    @ObservedObject
    var controller:
        QuarkResonatorSceneController

    let state:
        QuarkResonatorState

    func makeUIView(
        context: Context
    ) -> SCNView {

        let view =
            SCNView()

        view.scene =
            controller.scene

        view.backgroundColor =
            UIColor.black

        view.allowsCameraControl =
            true

        view.autoenablesDefaultLighting =
            false

        view.antialiasingMode =
            .multisampling4X

        view.preferredFramesPerSecond =
            60

        view.pointOfView =
            controller.scene.rootNode
                .childNodes
                .first {
                    $0.camera != nil
                }

        controller.update(
            state: state
        )

        return view
    }

    func updateUIView(
        _ uiView: SCNView,
        context: Context
    ) {

        controller.update(
            state: state
        )

        if uiView.pointOfView == nil {

            uiView.pointOfView =
                controller.scene.rootNode
                    .childNodes
                    .first {
                        $0.camera != nil
                    }
        }
    }
}

