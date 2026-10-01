//
//  File.swift
//  The Quark Resonator
//
//  Created by David Nishimoto on 10/1/26.
//

import Foundation

//
//  FusionResonatorSimulator.swift
//  QRTL Fusion Resonator — Hydrogen → Helium-4
//
//  Conceptual simulation:
//  Hydrogen protons
//      ↓
//  QRTL resonance lock
//      ↓
//  Quark coherence
//      ↓
//  QRTL lattice order
//      ↓
//  Proton lattice coupling
//      ↓
//  Four-proton fusion event
//      ↓
//  Helium-4 + 23.8 MeV effective model energy
//      ↓
//  Energy extraction
//
//  NOTE:
//  This is a conceptual QRTL simulation model. The QRTL resonance,
//  coherence, lattice-order, and fusion-probability relationships are
//  model assumptions and are not established experimental fusion physics.
//

import Foundation
import SwiftUI
import SceneKit
import Combine

// MARK: - Constants


// MARK: - Simulator

@MainActor
final class FusionResonatorSimulator: ObservableObject {

    let scene = SCNScene()

    private var superCoils: [SCNNode] = []
    private var particles: [FusionParticle] = []
    private var heliumNodes: [SCNNode] = []

    private var fieldLinesNode: SCNNode!
    private var fusionEventsNode: SCNNode!
    private var haloLight: SCNNode!

    // MARK: Controls

    @Published var detuningPPM: Double = 30.0

    @Published var magneticField: Double = 8.5

    /// Number of simulated hydrogen nuclei.
    @Published var particleCount: Int = 40 {
        didSet {
            particleCount = max(
                FusionConstants.protonsPerFusion,
                particleCount
            )

            if particleCount != oldValue {
                adjustHydrogenInventory()
            }
        }
    }

    @Published var extractionVoltageKV: Double = 10.0

    @Published var reactionYieldScale: Double = 1.0

    @Published var autoLockEnabled: Bool = true

    // MARK: Stage 1 — Resonance

    @Published private(set) var coherence: Double = 0.0

    @Published private(set) var phaseErrorRad: Double = 0.0

    @Published private(set) var latticeProbability: Double = 0.0

    @Published private(set) var latticeOrder: Double = 0.0

    // MARK: Stage 2 — QRTL coupling

    @Published private(set) var coupledCount: Int = 0

    @Published private(set) var hydrogenCount: Int = 0

    // MARK: Stage 3 — H → He-4 fusion

    @Published private(set) var heliumCount: Int = 0

    @Published private(set) var totalReactions: Int = 0

    @Published private(set) var reactionRateHz: Double = 0.0

    @Published private(set) var fusionProbability: Double = 0.0

    @Published private(set) var energyPerReactionMeV: Double =
        FusionConstants.effectiveFusionEnergyMeV

    // MARK: Stage 4 — Energy

    @Published private(set) var inputPowerMW: Double = 0.0

    @Published private(set) var fusionPowerMW: Double = 0.0

    @Published private(set) var electricalOutputMW: Double = 0.0

    @Published private(set) var netPowerMW: Double = 0.0

    @Published private(set) var cumulativeNetMWh: Double = 0.0

    @Published private(set) var qFactor: Double = 0.0

    @Published private(set) var outputCurrentA: Double = 0.0

    // MARK: Simulation

    @Published private(set) var isRunning: Bool = false

    private let macroParticleWeight: Double = 1e18

    private let directConversionEfficiency: Double = 0.80

    private let thermalConversionEfficiency: Double = 0.35

    private let pairingRadius: Float = 2.0

    private let maxEventsPerFrame: Int = 2

    private var frameFusionEnergyMeV: Double = 0.0
    private var frameEvents: Int = 0

    private var fusionPowerFilteredMW: Double = 0.0
    private var timer: Timer?

    private var phase: Double = 0.0

    // MARK: Derived

    var targetFrequencyHz: Double {
        FusionConstants.resonatorFrequencyHz
    }

    var appliedFrequencyHz: Double {
        targetFrequencyHz *
        (1.0 + detuningPPM * 1e-6)
    }

    var isLocked: Bool {
        coherence > 0.85
    }

    var isLatticeFormed: Bool {
        latticeOrder > 0.60 &&
        latticeProbability > 0.90
    }

    var isFusing: Bool {
        reactionRateHz > 0.1
    }

    var isExtracting: Bool {
        electricalOutputMW > 0.05
    }

    init() {
        setupScene()
        resetHydrogen()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: Scene Setup

    private func setupScene() {
        scene.background.contents = UIColor.black

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = 200
        camera.position = SCNVector3(0, 12, 28)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(
            white: 0.25,
            alpha: 1.0
        )
        scene.rootNode.addChildNode(ambient)

        haloLight = SCNNode()
        haloLight.light = SCNLight()
        haloLight.light?.type = .omni
        haloLight.light?.color = UIColor.orange
        haloLight.light?.intensity = 0
        scene.rootNode.addChildNode(haloLight)

        let chamber = SCNNode(
            geometry: SCNSphere(radius: 8)
        )

        chamber.geometry?
            .firstMaterial?
            .diffuse.contents =
            UIColor.systemBlue.withAlphaComponent(0.06)

        chamber.geometry?
            .firstMaterial?
            .isDoubleSided = true

        chamber.geometry?
            .firstMaterial?
            .lightingModel = .constant

        scene.rootNode.addChildNode(chamber)

        setupSuperCoils()

        fieldLinesNode = SCNNode()
        fusionEventsNode = SCNNode()

        scene.rootNode.addChildNode(fieldLinesNode)
        scene.rootNode.addChildNode(fusionEventsNode)

        buildFieldLines()
    }

    private func setupSuperCoils() {
        for i in 0..<12 {
            let torus = SCNTorus(
                ringRadius: 9.2,
                pipeRadius: 0.75
            )

            let coil = SCNNode(geometry: torus)

            coil.rotation = SCNVector4(
                0,
                1,
                0,
                2.0 *
                Double.pi *
                Double(i) /
                12.0
            )

            if let material = torus.firstMaterial {
                material.emission.contents =
                    i % 2 == 0
                    ? UIColor.cyan
                    : UIColor.purple

                material.diffuse.contents = UIColor.white
                material.metalness.contents = 0.8
                material.roughness.contents = 0.3
            }

            scene.rootNode.addChildNode(coil)
            superCoils.append(coil)
        }
    }

    private func buildFieldLines() {
        let axes: [SCNVector4] = [
            SCNVector4(
                1,
                0,
                0,
                Double.pi / 2
            ),
            SCNVector4(
                0,
                0,
                1,
                Double.pi / 2
            )
        ]

        for rotation in axes {
            let line = SCNNode(
                geometry: SCNCylinder(
                    radius: 0.045,
                    height: 18
                )
            )

            line.geometry?
                .firstMaterial?
                .emission.contents =
                UIColor.cyan

            line.rotation = rotation
            fieldLinesNode.addChildNode(line)
        }

        fieldLinesNode.isHidden = true
    }

    // MARK: Fuel Inventory

    private func randomPosition() -> SCNVector3 {
        let radius: Float = 6.0

        return SCNVector3(
            Float.random(in: -radius...radius),
            Float.random(in: -radius...radius),
            Float.random(in: -radius...radius)
        )
    }

    @discardableResult
    private func spawnHydrogen(
        at position: SCNVector3
    ) -> FusionParticle {

        let node = SCNNode(
            geometry: SCNSphere(
                radius: Species.proton.radius
            )
        )

        node.geometry?
            .firstMaterial?
            .diffuse.contents =
            Species.proton.color

        node.geometry?
            .firstMaterial?
            .emission.contents =
            Species.proton.color.withAlphaComponent(0.5)

        node.position = position

        // QRTL visual twister.
        let twister = SCNNode(
            geometry: SCNCylinder(
                radius: 0.05,
                height: Species.proton.radius * 3.6
            )
        )

        twister.geometry?
            .firstMaterial?
            .emission.contents =
            UIColor.cyan

        twister.rotation =
            SCNVector4(
                1,
                1,
                0,
                Double.pi / 2
            )

        node.addChildNode(twister)

        scene.rootNode.addChildNode(node)

        let particle = FusionParticle(
            node: node,
            species: .proton
        )

        particles.append(particle)

        return particle
    }

    private func spawnHelium4(
        at position: SCNVector3
    ) {
        let node = SCNNode(
            geometry: SCNSphere(
                radius: Species.helium4.radius
            )
        )

        node.position = position

        node.geometry?
            .firstMaterial?
            .diffuse.contents =
            Species.helium4.color

        node.geometry?
            .firstMaterial?
            .emission.contents =
            Species.helium4.color

        scene.rootNode.addChildNode(node)
        heliumNodes.append(node)

        // Product remains visible briefly as the He-4 product.
        let pulse = SCNAction.sequence([
            SCNAction.scale(
                to: 1.35,
                duration: 0.25
            ),
            SCNAction.scale(
                to: 1.0,
                duration: 0.25
            )
        ])

        node.runAction(pulse)
    }

    private func resetHydrogen() {
        particles.forEach {
            $0.node.removeFromParentNode()
        }

        particles.removeAll()

        heliumNodes.forEach {
            $0.removeFromParentNode()
        }

        heliumNodes.removeAll()

        fusionEventsNode?.childNodes.forEach {
            $0.removeFromParentNode()
        }

        for _ in 0..<particleCount {
            spawnHydrogen(at: randomPosition())
        }

        hydrogenCount = particles.count
        coupledCount = 0
        heliumCount = 0
        totalReactions = 0
        reactionRateHz = 0
        fusionProbability = 0
        frameFusionEnergyMeV = 0
        frameEvents = 0
    }

    private func adjustHydrogenInventory() {
        let desired = max(
            FusionConstants.protonsPerFusion,
            particleCount
        )

        let currentHydrogen = particles.count

        if desired > currentHydrogen {
            for _ in 0..<(desired - currentHydrogen) {
                spawnHydrogen(at: randomPosition())
            }
        } else if desired < currentHydrogen {
            var removeCount =
                currentHydrogen - desired

            var index =
                particles.count - 1

            while removeCount > 0 && index >= 0 {
                if !particles[index].coupled {
                    particles[index]
                        .node
                        .removeFromParentNode()

                    particles.remove(at: index)
                    removeCount -= 1
                }

                index -= 1
            }
        }

        hydrogenCount = particles.count
    }

    private func replenishHydrogen() {
        let deficit =
            particleCount - particles.count

        guard deficit > 0 else {
            return
        }

        for _ in 0..<min(deficit, 2) {
            spawnHydrogen(at: randomPosition())
        }

        hydrogenCount = particles.count
    }

    // MARK: Simulation Control

    func startSimulation() {
        guard !isRunning else {
            return
        }

        isRunning = true

        timer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.update()
            }
        }
    }

    func stopSimulation() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func reset() {
        stopSimulation()

        detuningPPM = 30.0
        magneticField = 8.5
        particleCount = max(
            FusionConstants.protonsPerFusion,
            particleCount
        )

        coherence = 0
        phaseErrorRad = 0
        latticeOrder = 0
        latticeProbability = 0

        coupledCount = 0
        hydrogenCount = 0

        heliumCount = 0
        totalReactions = 0
        reactionRateHz = 0
        fusionProbability = 0

        inputPowerMW = 0
        fusionPowerMW = 0
        electricalOutputMW = 0
        netPowerMW = 0
        cumulativeNetMWh = 0
        qFactor = 0
        outputCurrentA = 0

        fusionPowerFilteredMW = 0
        frameFusionEnergyMeV = 0
        frameEvents = 0
        phase = 0

        haloLight.light?.intensity = 0
        fieldLinesNode.isHidden = true

        resetHydrogen()
    }

    func seekLock() {
        detuningPPM = 0
    }

    // MARK: Main Update

    private func update() {
        let dt = 1.0 / 60.0

        // Visual representation only.
        // It does not attempt to render the actual 1e15 Hz oscillation.
        phase += 0.05

        for (index, coil) in superCoils.enumerated() {
            coil.eulerAngles.y =
                Float(
                    phase +
                    Double(index) * 0.3
                )
        }

        // ---------------------------------------------------------
        // QRTL PIPELINE
        // ---------------------------------------------------------
        //
        // 1. Resonance
        // 2. Coherence
        // 3. Lattice probability/order
        // 4. Proton coupling
        // 5. Four-proton fusion
        // 6. H -> He-4 product
        // 7. Energy extraction
        //
        // No alternate reaction catalog exists.
        // ---------------------------------------------------------

        updateQRTLResonance()

        stepHydrogenLattice()

        runHydrogenToHeliumFusion()

        replenishHydrogen()

        updatePower(dt: dt)

        updateVisualFeedback()
    }

    // MARK: Stage 1 — QRTL Resonance

    private func updateQRTLResonance() {
        if autoLockEnabled {
            detuningPPM *= 0.97

            if abs(detuningPPM) < 0.01 {
                detuningPPM = 0
            }
        }

        phaseErrorRad =
            QRTLModel.phaseError(
                detuningPPM: detuningPPM
            )

        coherence =
            QRTLModel.coherence(
                detuningPPM: detuningPPM,
                magneticField: magneticField
            )

        latticeProbability =
            QRTLModel.latticeProbability(
                coherence: coherence
            )

        latticeOrder =
            QRTLModel.latticeOrder(
                coherence: coherence,
                magneticField: magneticField
            )

        fusionProbability =
            QRTLModel.fusionProbability(
                coherence: coherence,
                latticeOrder: latticeOrder,
                latticeProbability: latticeProbability,
                yieldScale: reactionYieldScale
            )
    }

    // MARK: Stage 2 — Proton QRTL Lattice Coupling

    private func vlen(_ v: SCNVector3) -> Float {
        sqrtf(
            v.x * v.x +
            v.y * v.y +
            v.z * v.z
        )
    }

    private func stepHydrogenLattice() {
        let jitter =
            Float(
                max(
                    0.0,
                    1.0 - coherence
                )
            ) * 0.04

        let cosA = cosf(0.03)
        let sinA = sinf(0.03)

        var coupled = 0

        for particle in particles {
            var position =
                particle.node.position

            if particle.coupled {
                // Coherent QRTL lattice contraction.
                position.x -= position.x * 0.03
                position.y -= position.y * 0.03
                position.z -= position.z * 0.03

                let x =
                    position.x * cosA -
                    position.z * sinA

                let z =
                    position.x * sinA +
                    position.z * cosA

                position.x = x
                position.z = z

                let localJitter =
                    jitter * 0.25

                position.x +=
                    Float.random(
                        in: -localJitter...localJitter
                    )

                position.y +=
                    Float.random(
                        in: -localJitter...localJitter
                    )

                position.z +=
                    Float.random(
                        in: -localJitter...localJitter
                    )

                particle.node.position =
                    position

                if coherence < 0.60 {
                    particle.coupled = false

                    particle.node.scale =
                        SCNVector3(1, 1, 1)

                    particle.node.geometry?
                        .firstMaterial?
                        .emission.contents =
                        Species.proton.color
                        .withAlphaComponent(0.5)
                } else {
                    coupled += 1
                }

            } else {
                // Incoherent hydrogen drifts toward the resonator core.
                let pull: Float = 0.0018

                position.x +=
                    -position.x * pull +
                    Float.random(
                        in: -jitter...jitter
                    )

                position.y +=
                    -position.y * pull +
                    Float.random(
                        in: -jitter...jitter
                    )

                position.z +=
                    -position.z * pull +
                    Float.random(
                        in: -jitter...jitter
                    )

                particle.node.position =
                    position

                // Coupling requires both proximity and QRTL coherence.
                if vlen(position) < 2.8 &&
                    coherence > 0.75 {

                    particle.coupled = true

                    particle.node.scale =
                        SCNVector3(
                            0.7,
                            0.7,
                            0.7
                        )

                    particle.node.geometry?
                        .firstMaterial?
                        .emission.contents =
                        Species.proton.color

                    coupled += 1
                }
            }
        }

        coupledCount = coupled
        hydrogenCount = particles.count
    }

    // MARK: Stage 3 — H → He-4 Fusion

    private func runHydrogenToHeliumFusion() {

        guard coherence > 0.85,
              latticeOrder > 0.60,
              latticeProbability > 0.90
        else {
            return
        }

        let coupled =
            particles.filter {
                $0.coupled
            }

        guard coupled.count >=
                FusionConstants.protonsPerFusion
        else {
            return
        }

        var consumed =
            Set<ObjectIdentifier>()

        var eventsThisFrame = 0

        // One modeled fusion event consumes exactly four protons.
        while eventsThisFrame <
                maxEventsPerFrame {

            let available =
                coupled.filter {
                    !consumed.contains(
                        ObjectIdentifier($0)
                    )
                }

            guard available.count >=
                    FusionConstants.protonsPerFusion
            else {
                break
            }

            guard
                let group =
                    findProtonFusionGroup(
                        in: available
                    )
            else {
                break
            }

            let roll =
                Double.random(in: 0..<1)

            guard roll < fusionProbability
            else {
                break
            }

            fuseFourProtons(group)

            for proton in group {
                consumed.insert(
                    ObjectIdentifier(proton)
                )
            }

            eventsThisFrame += 1
        }
    }

    private func findProtonFusionGroup(
        in protons: [FusionParticle]
    ) -> [FusionParticle]? {

        guard protons.count >= 4 else {
            return nil
        }

        // Find a compact group of four synchronized protons.
        for i in 0..<(protons.count - 3) {
            let a = protons[i]

            var group = [a]

            for j in (i + 1)..<protons.count {
                let candidate = protons[j]

                let dx =
                    a.node.position.x -
                    candidate.node.position.x

                let dy =
                    a.node.position.y -
                    candidate.node.position.y

                let dz =
                    a.node.position.z -
                    candidate.node.position.z

                let distance =
                    sqrtf(
                        dx * dx +
                        dy * dy +
                        dz * dz
                    )

                if distance <= pairingRadius {
                    group.append(candidate)
                }

                if group.count == 4 {
                    return group
                }
            }
        }

        return nil
    }

    private func fuseFourProtons(
        _ protons: [FusionParticle]
    ) {

        guard protons.count == 4 else {
            return
        }

        let midpoint = SCNVector3(
            protons.reduce(0.0) {
                $0 + Double($1.node.position.x)
            } / 4.0,

            protons.reduce(0.0) {
                $0 + Double($1.node.position.y)
            } / 4.0,

            protons.reduce(0.0) {
                $0 + Double($1.node.position.z)
            } / 4.0
        )

        let event =
            FusionEvent.hydrogenToHelium4

        for proton in protons {
            proton.node.removeFromParentNode()
        }

        particles.removeAll { particle in
            protons.contains {
                $0 === particle
            }
        }

        // The only nuclear product in this simulation is He-4.
        spawnHelium4(at: midpoint)

        heliumCount += event.heliumProduced

        totalReactions += 1

        frameEvents += 1
        frameFusionEnergyMeV +=
            event.energyMeV

        spawnFusionFlash(
            energyMeV: event.energyMeV
        )
    }

    // MARK: Fusion Flash

    private func spawnFusionFlash(
        energyMeV: Double
    ) {
        let radius =
            CGFloat(
                0.25 +
                0.02 * energyMeV
            )

        let flash = SCNNode(
            geometry: SCNSphere(
                radius: radius
            )
        )

        flash.geometry?
            .firstMaterial?
            .emission.contents =
            UIColor.yellow

        flash.geometry?
            .firstMaterial?
            .diffuse.contents =
            UIColor.yellow

        flash.position =
            SCNVector3(0, 0, 0)

        fusionEventsNode.addChildNode(flash)

        let grow =
            SCNAction.scale(
                to: 4.0,
                duration: 0.4
            )

        let fade =
            SCNAction.fadeOut(
                duration: 0.4
            )

        flash.runAction(
            SCNAction.sequence([
                SCNAction.group([
                    grow,
                    fade
                ]),
                SCNAction.removeFromParentNode()
            ])
        )
    }

    // MARK: Stage 4 — Energy Accounting

    private func updatePower(dt: Double) {

        // Conceptual resonator input.
        let cryoPowerMW =
            0.6 +
            magneticField * 0.12

        let rfPowerMW =
            1.2 *
            (
                1.0 +
                0.01 *
                min(
                    abs(detuningPPM),
                    50.0
                )
            )

        let controlPowerMW = 0.3

        inputPowerMW =
            cryoPowerMW +
            rfPowerMW +
            controlPowerMW

        // Energy comes only from modeled fusion events.
        let fusionMW =
            frameFusionEnergyMeV *
            FusionConstants.mevToJoule *
            macroParticleWeight /
            dt /
            1e6

        let alpha = 0.03

        fusionPowerFilteredMW +=
            alpha *
            (
                fusionMW -
                fusionPowerFilteredMW
            )

        reactionRateHz +=
            alpha *
            (
                Double(frameEvents) /
                dt -
                reactionRateHz
            )

        fusionPowerMW =
            fusionPowerFilteredMW

        electricalOutputMW =
            fusionPowerMW *
            directConversionEfficiency

        netPowerMW =
            electricalOutputMW -
            inputPowerMW

        cumulativeNetMWh +=
            max(0.0, netPowerMW) *
            dt /
            3600.0

        qFactor =
            inputPowerMW > 0
            ? fusionPowerMW / inputPowerMW
            : 0.0

        energyPerReactionMeV =
            FusionConstants.effectiveFusionEnergyMeV

        frameFusionEnergyMeV = 0
        frameEvents = 0

        updateOutputCurrent()
    }

    private func updateOutputCurrent() {
        let voltageV =
            max(
                1.0,
                extractionVoltageKV * 1000.0
            )

        outputCurrentA =
            electricalOutputMW *
            1_000_000.0 /
            voltageV
    }

    // MARK: Visual Feedback

    private func updateVisualFeedback() {

        fieldLinesNode.isHidden =
            coherence <= 0.65

        let glow =
            CGFloat(
                min(
                    0.9,
                    max(
                        0.0,
                        qFactor / 5.0
                    )
                )
            )

        for coil in superCoils {
            coil.geometry?
                .firstMaterial?
                .emission.contents =
                coherence > 0.85
                ? UIColor.green.withAlphaComponent(0.8)
                : UIColor.cyan.withAlphaComponent(0.6)
        }

        haloLight.light?.intensity =
            CGFloat(
                coherence * 1200
            )

        haloLight.light?.color =
            isFusing
            ? UIColor.yellow
            : (
                isLocked
                ? UIColor.green
                : UIColor.orange
            )

        for helium in heliumNodes {
            helium.opacity =
                max(
                    0.45,
                    Double(glow) + 0.45
                )
        }
    }
}
