
//
//  File.swift
//  The Quark Resonator
//
//  Created by David Nishimoto on 9/30/26.
//

import Foundation
import SwiftUI
import SceneKit
import Combine

@MainActor
final class QuarkResonatorSceneController: ObservableObject {

    let scene = SCNScene()

    // ========================================================
    // MARK: Root Nodes
    // ========================================================

    private let equipmentRoot = SCNNode()
    private let chamberNode = SCNNode()
    private let frameNode = SCNNode()
    private let driverNode = SCNNode()
    private let actuatorNode = SCNNode()
    private let resonatorAssemblyNode = SCNNode()
    private let resonatorNode = SCNNode()
    private let sensorNode = SCNNode()
    private let couplingNode = SCNNode()
    private let outputNode = SCNNode()
    private let fieldNode = SCNNode()
    private let carrierNode = SCNNode()

    private let bboStage = BBOCrystalStageNode()
    private let fusionChamber = FusionChamberStageNode()

    private let cameraNode = SCNNode()
    private let cameraTargetNode = SCNNode()

    // ========================================================
    // MARK: Equipment Components
    // ========================================================

    private var driverCoils: [SCNNode] = []
    private var actuatorPlates: [SCNNode] = []
    private var supportNodes: [SCNNode] = []
    private var carrierParticles: [SCNNode] = []
    private var outputParticles: [SCNNode] = []

    private var frequencyReadoutNode: SCNNode?
    private var statusReadoutNode: SCNNode?

    // ========================================================
    // MARK: Current State
    // ========================================================

    private var currentFrequencyHz: Double = 0
    private var targetFrequencyHz: Double = 1.0e15
    private var resonanceResponse: Double = 0
    private var phase: Double = 0
    private var phaseError: Double = 0
    private var qrtlEnergyJ: Double = 0
    private var running = false

    // ========================================================
    // MARK: BBO → Fusion Geometry
    // ========================================================

    /*
     BBO stage origin:
         X = 7.6

     BBO UV output:
         local center X = 2.6
         port half-length = 0.2

     UV output end:
         2.6 + 0.2 = 2.8

     Fusion chamber:
         7.6 + 2.8 = 10.4
    */

    private let bboStageOriginX: Float = 7.6

    private let bboUVPortEndLocalX: Float =
        2.6 + 0.2

    // ========================================================
    // MARK: Initialization
    // ========================================================

    init() {

        configureScene()

        buildEquipmentFrame()
        buildVacuumChamber()

        buildDriver()
        buildActuator()
        buildMicroResonator()
        buildSensor()
        buildCouplingStage()
        buildQRTLOutput()

        buildEnergyPath()
        buildFrequencyReadout()

        buildBBOStage()
        buildFusionChamberStage()

        configureCamera()
        configureLighting()
    }

    // ========================================================
    // MARK: Scene Configuration
    // ========================================================

    private func configureScene() {

        scene.background.contents =
            UIColor.black

        scene.rootNode.addChildNode(
            equipmentRoot
        )

        equipmentRoot.position =
            SCNVector3(
                0,
                0,
                0
            )
    }

    // ========================================================
    // MARK: Vacuum Chamber
    // ========================================================

    private func buildVacuumChamber() {

        let chamberGeometry =
            SCNBox(
                width: 12.0,
                height: 5.8,
                length: 5.0,
                chamferRadius: 0.22
            )

        let material =
            SCNMaterial()

        material.diffuse.contents =
            UIColor(
                white: 0.08,
                alpha: 0.18
            )

        material.emission.contents =
            UIColor(
                white: 0.05,
                alpha: 0.15
            )

        material.transparency =
            0.82

        material.lightingModel =
            .physicallyBased

        chamberGeometry.materials =
            [material]

        chamberNode.geometry =
            chamberGeometry

        chamberNode.position =
            SCNVector3(
                0,
                0,
                0
            )

        equipmentRoot.addChildNode(
            chamberNode
        )

        // ----------------------------------------------------
        // Chamber end rings
        // ----------------------------------------------------

        for x in [-5.7, 5.7] {

            let ringGeometry =
                SCNTorus(
                    ringRadius: 2.55,
                    pipeRadius: 0.08
                )

            ringGeometry.firstMaterial?.diffuse.contents =
                UIColor.systemGray

            let ring =
                SCNNode(
                    geometry: ringGeometry
                )

            ring.position =
                SCNVector3(
                    Float(x),
                    0,
                    0
                )

            ring.eulerAngles.z =
                .pi / 2

            chamberNode.addChildNode(
                ring
            )
        }
    }

    // ========================================================
    // MARK: Mechanical Frame
    // ========================================================

    private func buildEquipmentFrame() {

        let frameMaterial =
            makeMaterial(
                color: UIColor(
                    white: 0.28,
                    alpha: 1
                )
            )

        // ----------------------------------------------------
        // Bottom rail
        // ----------------------------------------------------

        let bottom =
            SCNBox(
                width: 12.5,
                height: 0.25,
                length: 4.8,
                chamferRadius: 0.04
            )

        bottom.materials =
            [frameMaterial]

        let bottomNode =
            SCNNode(
                geometry: bottom
            )

        bottomNode.position =
            SCNVector3(
                0,
                -3.0,
                0
            )

        frameNode.addChildNode(
            bottomNode
        )

        // ----------------------------------------------------
        // Vertical supports
        // ----------------------------------------------------

        let supportPositions: [SCNVector3] = [

            SCNVector3(
                -5.5,
                0,
                -2.1
            ),

            SCNVector3(
                -5.5,
                0,
                2.1
            ),

            SCNVector3(
                5.5,
                0,
                -2.1
            ),

            SCNVector3(
                5.5,
                0,
                2.1
            )
        ]

        for position in supportPositions {

            let support =
                SCNBox(
                    width: 0.25,
                    height: 6.0,
                    length: 0.25,
                    chamferRadius: 0.04
                )

            support.materials =
                [frameMaterial]

            let node =
                SCNNode(
                    geometry: support
                )

            node.position =
                position

            frameNode.addChildNode(
                node
            )

            supportNodes.append(
                node
            )
        }

        equipmentRoot.addChildNode(
            frameNode
        )
    }

    // ========================================================
    // MARK: Driver
    // ========================================================

    private func buildDriver() {

        let housing =
            SCNBox(
                width: 1.5,
                height: 2.2,
                length: 2.2,
                chamferRadius: 0.12
            )

        housing.firstMaterial?.diffuse.contents =
            UIColor(
                white: 0.18,
                alpha: 1
            )

        housing.firstMaterial?.metalness.contents =
            0.75

        housing.firstMaterial?.roughness.contents =
            0.28

        driverNode.geometry =
            housing

        driverNode.position =
            SCNVector3(
                -4.45,
                0,
                0
            )

        equipmentRoot.addChildNode(
            driverNode
        )

        // ----------------------------------------------------
        // Driver coils
        // ----------------------------------------------------

        for index in 0..<6 {

            let torus =
                SCNTorus(
                    ringRadius: 0.75,
                    pipeRadius: 0.055
                )

            torus.firstMaterial?.diffuse.contents =
                UIColor.systemBlue

            torus.firstMaterial?.emission.contents =
                UIColor.systemBlue

            torus.firstMaterial?.emission.intensity =
                0.4

            let coil =
                SCNNode(
                    geometry: torus
                )

            coil.position =
                SCNVector3(
                    Float(
                        -0.6 +
                        Double(index) * 0.24
                    ),
                    0,
                    0
                )

            coil.eulerAngles.x =
                .pi / 2

            driverNode.addChildNode(
                coil
            )

            driverCoils.append(
                coil
            )
        }

        // ----------------------------------------------------
        // Driver label
        // ----------------------------------------------------

        addLabel(
            text: "DRIVER",
            position:
                SCNVector3(
                    -4.45,
                    1.45,
                    0
                ),
            color: .systemBlue,
            parent: equipmentRoot
        )
    }

    // ========================================================
    // MARK: Actuator / Transducer
    // ========================================================

    private func buildActuator() {

        actuatorNode.position =
            SCNVector3(
                -2.65,
                0,
                0
            )

        equipmentRoot.addChildNode(
            actuatorNode
        )

        for z in [-0.85, 0.85] {

            let plate =
                SCNBox(
                    width: 0.30,
                    height: 2.4,
                    length: 0.65,
                    chamferRadius: 0.05
                )

            plate.firstMaterial?.diffuse.contents =
                UIColor.systemCyan

            plate.firstMaterial?.emission.contents =
                UIColor.systemCyan

            plate.firstMaterial?.emission.intensity =
                0.35

            let node =
                SCNNode(
                    geometry: plate
                )

            node.position =
                SCNVector3(
                    0,
                    0,
                    Float(z)
                )

            actuatorNode.addChildNode(
                node
            )

            actuatorPlates.append(
                node
            )
        }

        addLabel(
            text: "ACTUATOR / TRANSDUCER",
            position:
                SCNVector3(
                    -2.65,
                    1.55,
                    0
                ),
            color: .systemCyan,
            parent: equipmentRoot
        )
    }

    // ========================================================
    // MARK: Central Micro Resonator
    // ========================================================

    private func buildMicroResonator() {

        resonatorAssemblyNode.position =
            SCNVector3(
                0,
                0,
                0
            )

        equipmentRoot.addChildNode(
            resonatorAssemblyNode
        )

        // ----------------------------------------------------
        // Suspension beams
        // ----------------------------------------------------

        let beamMaterial =
            makeMaterial(
                color: UIColor.systemGray
            )

        let topBeam =
            SCNBox(
                width: 3.4,
                height: 0.12,
                length: 0.12,
                chamferRadius: 0.02
            )

        topBeam.materials =
            [beamMaterial]

        let topNode =
            SCNNode(
                geometry: topBeam
            )

        topNode.position =
            SCNVector3(
                0,
                1.45,
                0
            )

        resonatorAssemblyNode.addChildNode(
            topNode
        )

        let bottomBeam =
            SCNBox(
                width: 3.4,
                height: 0.12,
                length: 0.12,
                chamferRadius: 0.02
            )

        bottomBeam.materials =
            [beamMaterial]

        let bottomNode =
            SCNNode(
                geometry: bottomBeam
            )

        bottomNode.position =
            SCNVector3(
                0,
                -1.45,
                0
            )

        resonatorAssemblyNode.addChildNode(
            bottomNode
        )

        // ----------------------------------------------------
        // Resonant element
        // ----------------------------------------------------

        let resonatorGeometry =
            SCNBox(
                width: 1.55,
                height: 0.95,
                length: 1.15,
                chamferRadius: 0.18
            )

        resonatorGeometry.firstMaterial?.diffuse.contents =
            UIColor.systemPurple

        resonatorGeometry.firstMaterial?.emission.contents =
            UIColor.systemPurple

        resonatorGeometry.firstMaterial?.emission.intensity =
            0.55

        resonatorGeometry.firstMaterial?.metalness.contents =
            0.65

        resonatorGeometry.firstMaterial?.roughness.contents =
            0.22

        resonatorNode.geometry =
            resonatorGeometry

        resonatorNode.position =
            SCNVector3(
                0,
                0,
                0
            )

        resonatorAssemblyNode.addChildNode(
            resonatorNode
        )

        // ----------------------------------------------------
        // Suspension rods
        // ----------------------------------------------------

        for x in [-0.72, 0.72] {

            let rod =
                SCNCylinder(
                    radius: 0.035,
                    height: 1.3
                )

            rod.firstMaterial?.diffuse.contents =
                UIColor.systemGray

            let node =
                SCNNode(
                    geometry: rod
                )

            node.position =
                SCNVector3(
                    Float(x),
                    0,
                    0
                )

            resonatorAssemblyNode.addChildNode(
                node
            )
        }

        addLabel(
            text: "MICRO-RESONATOR",
            position:
                SCNVector3(
                    0,
                    1.85,
                    0
                ),
            color: .systemPurple,
            parent: equipmentRoot
        )
    }

    // ========================================================
    // MARK: Phase / Frequency Sensor
    // ========================================================

    private func buildSensor() {

        sensorNode.position =
            SCNVector3(
                0,
                2.05,
                0
            )

        equipmentRoot.addChildNode(
            sensorNode
        )

        let sensorHousing =
            SCNBox(
                width: 1.6,
                height: 0.28,
                length: 0.75,
                chamferRadius: 0.06
            )

        sensorHousing.firstMaterial?.diffuse.contents =
            UIColor.systemGreen

        sensorHousing.firstMaterial?.emission.contents =
            UIColor.systemGreen

        sensorHousing.firstMaterial?.emission.intensity =
            0.4

        let housing =
            SCNNode(
                geometry: sensorHousing
            )

        sensorNode.addChildNode(
            housing
        )

        let probe =
            SCNCylinder(
                radius: 0.045,
                height: 0.8
            )

        probe.firstMaterial?.diffuse.contents =
            UIColor.systemGreen

        let probeNode =
            SCNNode(
                geometry: probe
            )

        probeNode.position =
            SCNVector3(
                0,
                -0.5,
                0
            )

        sensorNode.addChildNode(
            probeNode
        )

        addLabel(
            text: "PHASE / FREQUENCY SENSOR",
            position:
                SCNVector3(
                    0,
                    2.75,
                    0
                ),
            color: .systemGreen,
            parent: equipmentRoot
        )
    }

    // ========================================================
    // MARK: Coupling Stage
    // ========================================================

    private func buildCouplingStage() {

        couplingNode.position =
            SCNVector3(
                2.35,
                0,
                0
            )

        equipmentRoot.addChildNode(
            couplingNode
        )

        let housing =
            SCNBox(
                width: 0.85,
                height: 2.1,
                length: 1.65,
                chamferRadius: 0.10
            )

        housing.firstMaterial?.diffuse.contents =
            UIColor(
                red: 0.25,
                green: 0.16,
                blue: 0.32,
                alpha: 1
            )

        housing.firstMaterial?.metalness.contents =
            0.65

        let housingNode =
            SCNNode(
                geometry: housing
            )

        couplingNode.addChildNode(
            housingNode
        )

        // ----------------------------------------------------
        // Coupling rings
        // ----------------------------------------------------

        for index in 0..<4 {

            let ring =
                SCNTorus(
                    ringRadius: 0.62,
                    pipeRadius: 0.045
                )

            ring.firstMaterial?.diffuse.contents =
                UIColor.systemPurple

            ring.firstMaterial?.emission.contents =
                UIColor.systemPurple

            ring.firstMaterial?.emission.intensity =
                0.35

            let node =
                SCNNode(
                    geometry: ring
                )

            node.position =
                SCNVector3(
                    0,
                    Float(
                        -0.65 +
                        Double(index) * 0.43
                    ),
                    0
                )

            node.eulerAngles.x =
                .pi / 2

            couplingNode.addChildNode(
                node
            )
        }

        addLabel(
            text: "QRTL COUPLING STAGE",
            position:
                SCNVector3(
                    2.35,
                    1.45,
                    0
                ),
            color: .systemPurple,
            parent: equipmentRoot
        )
    }

    // ========================================================
    // MARK: QRTL Output
    // ========================================================

    private func buildQRTLOutput() {

        outputNode.position =
            SCNVector3(
                4.25,
                0,
                0
            )

        equipmentRoot.addChildNode(
            outputNode
        )

        let outputHousing =
            SCNCylinder(
                radius: 0.85,
                height: 1.1
            )

        outputHousing.firstMaterial?.diffuse.contents =
            UIColor.systemOrange

        outputHousing.firstMaterial?.emission.contents =
            UIColor.systemOrange

        outputHousing.firstMaterial?.emission.intensity =
            0.35

        let housing =
            SCNNode(
                geometry: outputHousing
            )

        housing.eulerAngles.z =
            .pi / 2

        outputNode.addChildNode(
            housing
        )

        let outputPort =
            SCNCylinder(
                radius: 0.28,
                height: 0.9
            )

        outputPort.firstMaterial?.diffuse.contents =
            UIColor.systemYellow

        let portNode =
            SCNNode(
                geometry: outputPort
            )

        portNode.position =
            SCNVector3(
                0.8,
                0,
                0
            )

        portNode.eulerAngles.z =
            .pi / 2

        outputNode.addChildNode(
            portNode
        )

        addLabel(
            text: "QRTL OUTPUT",
            position:
                SCNVector3(
                    4.25,
                    1.45,
                    0
                ),
            color: .systemOrange,
            parent: equipmentRoot
        )
    }

    // ========================================================
    // MARK: Energy Transfer Path
    // ========================================================

    private func buildEnergyPath() {

        let positions: [Float] = [
            -3.7,
            -1.9,
            1.2,
            3.3
        ]

        for index in 0..<positions.count {

            let sphere =
                SCNSphere(
                    radius: 0.08
                )

            sphere.firstMaterial?.diffuse.contents =
                UIColor.systemCyan

            sphere.firstMaterial?.emission.contents =
                UIColor.systemCyan

            sphere.firstMaterial?.emission.intensity =
                0.8

            let node =
                SCNNode(
                    geometry: sphere
                )

            node.position =
                SCNVector3(
                    positions[index],
                    0,
                    0
                )

            carrierNode.addChildNode(
                node
            )

            carrierParticles.append(
                node
            )
        }

        equipmentRoot.addChildNode(
            carrierNode
        )
    }

    // ========================================================
    // MARK: Frequency Readout
    // ========================================================

    private func buildFrequencyReadout() {

        let targetText =
            makeTextNode(
                text: "TARGET  1.000e15 Hz",
                color: UIColor.systemCyan,
                fontSize: 0.18
            )

        targetText.position =
            SCNVector3(
                -5.2,
                3.15,
                0
            )

        equipmentRoot.addChildNode(
            targetText
        )

        frequencyReadoutNode =
            targetText

        let status =
            makeTextNode(
                text: "FREQUENCY SEARCH",
                color: UIColor.systemYellow,
                fontSize: 0.16
            )

        status.position =
            SCNVector3(
                -5.2,
                2.75,
                0
            )

        equipmentRoot.addChildNode(
            status
        )

        statusReadoutNode =
            status
    }

    // ========================================================
    // MARK: BBO Crystal Stage
    // ========================================================

    private func buildBBOStage() {

        bboStage.position =
            SCNVector3(
                bboStageOriginX,
                0,
                0
            )

        equipmentRoot.addChildNode(
            bboStage
        )
    }

    // ========================================================
    // MARK: Fusion Chamber Stage
    // ========================================================

    /*
     The fusion chamber is placed at the physical end of
     the BBO UV output.

     BBO origin:
         X = 7.6

     UV port:
         local center X = 2.6
         half-length = 0.2

     UV exit:
         X = 2.8 local to BBO

     Fusion chamber:
         X = 7.6 + 2.8
         X = 10.4
    */

    private func buildFusionChamberStage() {

        fusionChamber.position =
            SCNVector3(
                bboStageOriginX +
                    bboUVPortEndLocalX,
                0,
                0
            )

        equipmentRoot.addChildNode(
            fusionChamber
        )
    }

    // ========================================================
    // MARK: Camera
    // ========================================================

    private func configureCamera() {

        cameraNode.camera =
            SCNCamera()

        cameraNode.camera?.fieldOfView =
            48

        cameraNode.camera?.zNear =
            0.01

        cameraNode.camera?.zFar =
            1000

        /*
         Frames the complete equipment:

             chamber left end  ≈ -6
             fusion chamber    ≈ 10.4
             fusion stage end  ≈ 14
        */

        let sceneCenterX: Float = 4.0

        cameraNode.position =
            SCNVector3(
                sceneCenterX,
                4.5,
                31.0
            )

        cameraTargetNode.position =
            SCNVector3(
                sceneCenterX,
                0,
                0
            )

        scene.rootNode.addChildNode(
            cameraTargetNode
        )

        let lookAt =
            SCNLookAtConstraint(
                target: cameraTargetNode
            )

        lookAt.isGimbalLockEnabled =
            true

        cameraNode.constraints =
            [lookAt]

        scene.rootNode.addChildNode(
            cameraNode
        )
    }

    // ========================================================
    // MARK: Lighting
    // ========================================================

    private func configureLighting() {

        let keyLight =
            SCNNode()

        keyLight.light =
            SCNLight()

        keyLight.light?.type =
            .omni

        keyLight.light?.intensity =
            1100

        keyLight.position =
            SCNVector3(
                0,
                7,
                8
            )

        scene.rootNode.addChildNode(
            keyLight
        )

        let fillLight =
            SCNNode()

        fillLight.light =
            SCNLight()

        fillLight.light?.type =
            .omni

        fillLight.light?.intensity =
            450

        fillLight.position =
            SCNVector3(
                -8,
                2,
                4
            )

        scene.rootNode.addChildNode(
            fillLight
        )

        let rimLight =
            SCNNode()

        rimLight.light =
            SCNLight()

        rimLight.light?.type =
            .omni

        rimLight.light?.intensity =
            650

        rimLight.position =
            SCNVector3(
                7,
                3,
                -5
            )

        scene.rootNode.addChildNode(
            rimLight
        )
    }

    // ========================================================
    // MARK: State Update
    // ========================================================

    func update(
        state: QuarkResonatorState
    ) {

        currentFrequencyHz =
            finiteOrZero(
                state.outputFrequencyHz
            )

        targetFrequencyHz =
            max(
                finiteOrZero(
                    state.targetFrequencyHz
                ),
                1.0
            )

        resonanceResponse =
            clamp(
                finiteOrZero(
                    state.resonanceResponse
                ),
                minimum: 0,
                maximum: 1
            )

        phase =
            finiteOrZero(
                state.phase
            )

        phaseError =
            finiteOrZero(
                state.phaseError
            )

        qrtlEnergyJ =
            max(
                finiteOrZero(
                    state.qrtlEnergyJ
                ),
                0
            )

        running =
            state.running

        updateDriver(
            state: state
        )

        updateActuator(
            state: state
        )

        updateMicroResonator(
            state: state
        )

        updateSensor(
            state: state
        )

        updateCoupling(
            state: state
        )

        updateOutput(
            state: state
        )

        updateCarrierPath(
            state: state
        )

        updateFrequencyReadout(
            state: state
        )

        // ----------------------------------------------------
        // BBO
        // ----------------------------------------------------

        bboStage.update(
            result: state.bboResult,
            running: state.running
        )

        // ----------------------------------------------------
        // BBO UV → Fusion Chamber
        // ----------------------------------------------------

        let bbo =
            state.bboResult

        let uvActive =
            state.running &&
            bbo.isPhaseMatchable &&
            bbo.pumpTransmitted &&
            bbo.outputTransmitted

        let uvStrength =
            uvActive
            ? max(
                0.0,
                min(
                    1.0,
                    bbo.conversionEfficiency.squareRoot()
                )
            )
            : 0.0

        /*
         The controller establishes the physical position
         of the fusion chamber.

         The FusionChamberStageNode owns the proton geometry
         and fusion-event visualization.

         Therefore the fusion burst itself must be spawned
         at the actual reaction midpoint inside
         FusionChamberStageNode, rather than at (0, 0, 0).
        */

        fusionChamber.update(
            frequencyHz:
                state.outputFrequencyHz,

            lockErrorFraction:
                state.frequencyLockErrorFraction,

            targetLocked:
                state.targetFrequencyLocked,

            uvStrength:
                uvStrength,

            shellExcited:
                state.helium4ShellExcited,

            running:
                state.running
        )
    }

    // ========================================================
    // MARK: Driver Animation
    // ========================================================

    private func updateDriver(
        state: QuarkResonatorState
    ) {

        let frequencyRatio =
            targetFrequencyHz > 0
            ? currentFrequencyHz /
                targetFrequencyHz
            : 0

        let proximity =
            clamp(
                frequencyRatio,
                minimum: 0,
                maximum: 1
            )

        let intensity =
            CGFloat(
                0.2 +
                0.8 *
                resonanceResponse
            )

        for coil in driverCoils {

            coil.opacity =
                0.35 +
                CGFloat(
                    proximity * 0.65
                )

            coil.scale =
                SCNVector3(
                    1,
                    1,
                    1 +
                    Float(
                        resonanceResponse *
                        0.08
                    )
                )

            coil.geometry?
                .firstMaterial?
                .emission.intensity =
                intensity
        }
    }

    // ========================================================
    // MARK: Actuator Animation
    // ========================================================

    private func updateActuator(
        state: QuarkResonatorState
    ) {

        let amplitude =
            clamp(
                finiteOrZero(
                    state.targetModeAmplitude
                ),
                minimum: 0,
                maximum: 1e-8
            )

        let normalizedAmplitude =
            min(
                amplitude / 1e-10,
                1.0
            )

        let offset =
            Float(
                sin(phase) *
                normalizedAmplitude *
                0.18
            )

        for (index, plate)
            in actuatorPlates.enumerated() {

            let direction: Float =
                index == 0
                ? -1
                : 1

            plate.position.x =
                direction *
                abs(offset)
        }
    }

    // ========================================================
    // MARK: Micro Resonator
    // ========================================================

    private func updateMicroResonator(
        state: QuarkResonatorState
    ) {

        let response =
            resonanceResponse

        let visualAmplitude =
            Float(
                1.0 +
                response *
                0.12
            )

        let x =
            Float(
                sin(phase) *
                response *
                0.18
            )

        let y =
            Float(
                cos(phase) *
                response *
                0.06
            )

        resonatorNode.position =
            SCNVector3(
                x,
                y,
                0
            )

        resonatorNode.scale =
            SCNVector3(
                visualAmplitude,
                1,
                1
            )

        resonatorNode.opacity =
            0.65 +
            CGFloat(
                response *
                0.35
            )
    }

    // ========================================================
    // MARK: Sensor
    // ========================================================

    private func updateSensor(
        state: QuarkResonatorState
    ) {

        let errorFraction =
            targetFrequencyHz > 0
            ? abs(
                currentFrequencyHz -
                targetFrequencyHz
            ) /
            targetFrequencyHz
            : 1

        let lockProgress =
            clamp(
                1 -
                errorFraction /
                0.01,
                minimum: 0,
                maximum: 1
            )

        let sensorIntensity =
            CGFloat(
                0.25 +
                lockProgress *
                0.75
            )

        sensorNode.opacity =
            sensorIntensity
    }

    // ========================================================
    // MARK: QRTL Coupling
    // ========================================================

    private func updateCoupling(
        state: QuarkResonatorState
    ) {

        let energyScale =
            qrtlEnergyJ > 0
            ? min(
                1,
                max(
                    0,
                    (
                        log10(
                            max(
                                qrtlEnergyJ,
                                1e-60
                            )
                        ) + 60
                    ) / 30
                )
            )
            : 0

        couplingNode.opacity =
            0.35 +
            CGFloat(
                energyScale *
                0.65
            )

        couplingNode.scale =
            SCNVector3(
                1 +
                Float(
                    energyScale *
                    0.10
                ),

                1 +
                Float(
                    energyScale *
                    0.10
                ),

                1 +
                Float(
                    energyScale *
                    0.10
                )
            )
    }

    // ========================================================
    // MARK: QRTL Output
    // ========================================================

    private func updateOutput(
        state: QuarkResonatorState
    ) {

        let energyActive =
            qrtlEnergyJ > 0

        outputNode.opacity =
            energyActive
            ? 1.0
            : 0.35

        let scale =
            energyActive
            ? 1.15
            : 1.0

        outputNode.scale =
            SCNVector3(
                scale,
                scale,
                scale
            )
    }

    // ========================================================
    // MARK: Carrier Energy Path
    // ========================================================

    private func updateCarrierPath(
        state: QuarkResonatorState
    ) {

        guard !carrierParticles.isEmpty
        else {
            return
        }

        let active =
            running &&
            resonanceResponse > 0

        for (index, particle)
            in carrierParticles.enumerated() {

            if !active {

                particle.opacity =
                    0.15

                continue
            }

            let speed =
                0.6 +
                resonanceResponse *
                2.5

            let t =
                (
                    Double(index) * 0.23 +
                    phase
                )
                .truncatingRemainder(
                    dividingBy:
                        2.0 * Double.pi
                )

            let normalized =
                Float(
                    t /
                    (2.0 * Double.pi)
                )

            particle.position.x =
                -3.7 +
                normalized *
                4.9

            particle.position.y =
                Float(
                    sin(
                        Double(t)
                    ) *
                    resonanceResponse *
                    0.10
                )

            particle.opacity =
                0.35 +
                CGFloat(
                    resonanceResponse *
                    0.65
                )

            particle.scale =
                SCNVector3(
                    1 +
                    Float(
                        speed *
                        0.03
                    ),
                    1,
                    1
                )
        }
    }

    // ========================================================
    // MARK: Frequency Display
    // ========================================================

    private func updateFrequencyReadout(
        state: QuarkResonatorState
    ) {

        let actual =
            currentFrequencyHz

        let target =
            targetFrequencyHz

        let relativeError =
            target > 0
            ? abs(
                actual -
                target
            ) / target
            : 1

        let locked =
            relativeError <= 0.01

        let frequencyText =
            formatFrequency(
                actual
            )

        let targetText =
            formatFrequency(
                target
            )

        let readout =
            "OUTPUT \(frequencyText) Hz / TARGET \(targetText) Hz"

        frequencyReadoutNode?
            .geometry?
            .firstMaterial?
            .diffuse.contents =
            locked
            ? UIColor.systemGreen
            : UIColor.systemCyan

        frequencyReadoutNode?
            .geometry?
            .firstMaterial?
            .emission.contents =
            locked
            ? UIColor.systemGreen
            : UIColor.systemCyan

        replaceText(
            node: frequencyReadoutNode,
            text: readout,
            color:
                locked
                ? UIColor.systemGreen
                : UIColor.systemCyan
        )

        let statusText: String

        if !running {

            statusText =
                "READY — TARGET 1.000e15 Hz"

        } else if locked {

            statusText =
                "10¹⁵ Hz TARGET LOCKED"

        } else {

            statusText =
                "FREQUENCY SEARCH → 10¹⁵ Hz"
        }

        replaceText(
            node: statusReadoutNode,
            text: statusText,
            color:
                locked
                ? UIColor.systemGreen
                : UIColor.systemYellow
        )
    }

    // ========================================================
    // MARK: Helpers
    // ========================================================

    private func makeMaterial(
        color: UIColor
    ) -> SCNMaterial {

        let material =
            SCNMaterial()

        material.diffuse.contents =
            color

        material.lightingModel =
            .physicallyBased

        return material
    }

    private func makeTextNode(
        text: String,
        color: UIColor,
        fontSize: CGFloat
    ) -> SCNNode {

        let textGeometry =
            SCNText(
                string: text,
                extrusionDepth: 0.01
            )

        textGeometry.font =
            UIFont.monospacedSystemFont(
                ofSize: fontSize,
                weight: .medium
            )

        textGeometry.flatness =
            0.2

        textGeometry.firstMaterial?.diffuse.contents =
            color

        textGeometry.firstMaterial?.emission.contents =
            color

        let node =
            SCNNode(
                geometry: textGeometry
            )

        let (minVector, maxVector) =
            node.boundingBox

        let width =
            maxVector.x -
            minVector.x

        node.pivot =
            SCNMatrix4MakeTranslation(
                width / 2,
                0,
                0
            )

        return node
    }

    private func addLabel(
        text: String,
        position: SCNVector3,
        color: UIColor,
        parent: SCNNode
    ) {

        let node =
            makeTextNode(
                text: text,
                color: color,
                fontSize: 0.16
            )

        node.position =
            position

        parent.addChildNode(
            node
        )
    }

    private func replaceText(
        node: SCNNode?,
        text: String,
        color: UIColor
    ) {

        guard let node,
              let textGeometry =
                node.geometry as? SCNText
        else {
            return
        }

        textGeometry.string =
            text

        textGeometry.firstMaterial?.diffuse.contents =
            color

        textGeometry.firstMaterial?.emission.contents =
            color
    }

    private func finiteOrZero(
        _ value: Double
    ) -> Double {

        value.isFinite
        ? value
        : 0
    }

    private func clamp(
        _ value: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {

        min(
            maximum,
            max(
                minimum,
                value
            )
        )
    }

    private func formatFrequency(
        _ frequency: Double
    ) -> String {

        guard frequency.isFinite,
              frequency > 0
        else {
            return "0.000e0"
        }

        return String(
            format: "%.3e",
            frequency
        )
    }
}

