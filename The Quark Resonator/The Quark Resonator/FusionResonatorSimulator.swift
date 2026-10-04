//
//  FusionResonatorSimulator.swift
//  The Quark Resonator
//
//  Conceptual QRTL Fusion Resonator — Hydrogen → Helium-4
//
//  This is a visualization/model only. QRTL resonance, coherence,
//  lattice ordering, and reaction probability are application-defined
//  assumptions, not established experimental fusion physics.
//

import Foundation
import SwiftUI
import SceneKit
import Combine
import UIKit

@MainActor
final class FusionResonatorSimulator: ObservableObject {

    // MARK: - Scene

    let scene = SCNScene()

    private var superCoils: [SCNNode] = []
    private var particles: [FusionParticle] = []
    private var heliumNodes: [SCNNode] = []
    private var fusionReactorNodes: [SCNNode] = []

    private var fieldLinesNode = SCNNode()
    private var fusionEventsNode = SCNNode()
    private var haloLight = SCNNode()

    private var waveParticleNode: SCNNode?
    private var waveParticlePhase: Double = 0.0
    private var cameraNode: SCNNode?

    // MARK: - Controls

    @Published var detuningPPM: Double = 30.0
    @Published var magneticField: Double = 8.5

    @Published var particleCount: Int = 40 {
        didSet {
            let minimum = FusionConstants.protonsPerFusion
            let clamped = max(minimum, particleCount)

            // Avoid repeatedly triggering didSet after assigning a clamp.
            if particleCount != clamped {
                particleCount = clamped
                return
            }

            guard particleCount != oldValue else { return }
            adjustHydrogenInventory()
        }
    }

    @Published var extractionVoltageKV: Double = 10.0
    @Published var reactionYieldScale: Double = 1.0
    @Published var autoLockEnabled: Bool = true
    @Published var isZoomedIn: Bool = false

    // MARK: - Stage 1: Resonance

    @Published private(set) var coherence: Double = 0.0
    @Published private(set) var phaseErrorRad: Double = 0.0
    @Published private(set) var latticeProbability: Double = 0.0
    @Published private(set) var latticeOrder: Double = 0.0

    // MARK: - QRTL Energy Shell

    @Published var shellStoredEnergyJ: Double = 0.0
    @Published var shellDisplacementM: Double = 0.0
    @Published var shellEnergyReleasedJ: Double = 0.0
    @Published var shellPhase: String = "idle"
    @Published var shellResonanceEnvelope: Double = 0.0
    @Published var latticeEnergyInputJ: Double = 0.0

    // MARK: - Stage 2: Coupling

    @Published private(set) var coupledCount: Int = 0
    @Published private(set) var hydrogenCount: Int = 0

    // MARK: - Stage 3: Modeled Reaction

    @Published private(set) var heliumCount: Int = 0
    @Published private(set) var totalReactions: Int = 0
    @Published private(set) var reactionRateHz: Double = 0.0
    @Published private(set) var fusionProbability: Double = 0.0

    @Published private(set) var energyPerReactionMeV: Double =
        FusionConstants.effectiveFusionEnergyMeV

    // MARK: - Stage 4: Energy Accounting

    @Published private(set) var inputPowerMW: Double = 0.0
    @Published private(set) var fusionPowerMW: Double = 0.0
    @Published private(set) var electricalOutputMW: Double = 0.0
    @Published private(set) var netPowerMW: Double = 0.0
    @Published private(set) var cumulativeNetMWh: Double = 0.0
    @Published private(set) var qFactor: Double = 0.0
    @Published private(set) var outputCurrentA: Double = 0.0

    // MARK: - Simulation State

    @Published private(set) var isRunning: Bool = false

    private let simulationTimeStep = 1.0 / 60.0
    private let macroParticleWeight: Double = 1.0e18
    private let directConversionEfficiency: Double = 0.80

    private let pairingRadius: Float = 2.0
    private let maxEventsPerFrame: Int = 2

    private var timer: Timer?
    private var phase: Double = 0.0
    private var frameFusionEnergyMeV: Double = 0.0
    private var frameEvents: Int = 0
    private var fusionPowerFilteredMW: Double = 0.0

    // MARK: - Shell Oscillator

    // f0 = sqrt(k / m) / (2π) = approximately 1e15 Hz.
    private let shellEffectiveMassKg: Double = 1.0e-30
    private let shellRestoringConstantNPerM: Double = 39.47841760435743

    private let shellReleaseFraction: Double = 0.80
    private let shellDriveFraction: Double = 0.10
    private let shellMaxStoredEnergyJ: Double = 1.0e-12
    private let shellFormationSeconds: Double = 1.0e-3

    private var shellFormationTime: Double = 0.0
    private var shellEnergyReleasedThisCycle = false

    // MARK: - Derived Values

    var targetFrequencyHz: Double {
        FusionConstants.resonatorFrequencyHz
    }

    var appliedFrequencyHz: Double {
        targetFrequencyHz * (1.0 + detuningPPM * 1.0e-6)
    }

    var isLocked: Bool {
        coherence > 0.85
    }

    var isLatticeFormed: Bool {
        latticeOrder > 0.60 && latticeProbability > 0.90
    }

    var isFusing: Bool {
        reactionRateHz > 0.1
    }

    var isExtracting: Bool {
        electricalOutputMW > 0.05
    }

    private var shellNaturalFrequencyHz: Double {
        sqrt(shellRestoringConstantNPerM / shellEffectiveMassKg)
            / (2.0 * Double.pi)
    }

    private var shellQualityFactor: Double {
        max(1.0, 20.0 + 80.0 * coherence)
    }

    // MARK: - Lifecycle

    init() {
        setupScene()
        resetHydrogen()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Public Controls

    func startSimulation() {
        guard !isRunning else { return }

        isRunning = true
        createFusionReactorNodes(count: 4)

        let newTimer = Timer(
            timeInterval: simulationTimeStep,
            repeats: true
        ) { [weak self] _ in
            self?.update()
        }

        newTimer.tolerance = simulationTimeStep * 0.15
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func stopSimulation() {
        timer?.invalidate()
        timer = nil

        isRunning = false
        removeFusionReactorNodes()
    }

    func reset() {
        stopSimulation()

        detuningPPM = 30.0
        magneticField = 8.5
        particleCount = max(FusionConstants.protonsPerFusion, particleCount)

        coherence = 0.0
        phaseErrorRad = 0.0
        latticeOrder = 0.0
        latticeProbability = 0.0

        shellStoredEnergyJ = 0.0
        shellDisplacementM = 0.0
        shellEnergyReleasedJ = 0.0
        shellPhase = "idle"
        shellResonanceEnvelope = 0.0
        latticeEnergyInputJ = 0.0
        shellFormationTime = 0.0
        shellEnergyReleasedThisCycle = false

        coupledCount = 0
        hydrogenCount = 0
        heliumCount = 0
        totalReactions = 0
        reactionRateHz = 0.0
        fusionProbability = 0.0

        inputPowerMW = 0.0
        fusionPowerMW = 0.0
        electricalOutputMW = 0.0
        netPowerMW = 0.0
        cumulativeNetMWh = 0.0
        qFactor = 0.0
        outputCurrentA = 0.0

        fusionPowerFilteredMW = 0.0
        frameFusionEnergyMeV = 0.0
        frameEvents = 0
        phase = 0.0
        waveParticlePhase = 0.0

        haloLight.light?.intensity = 0.0
        fieldLinesNode.isHidden = true

        removeFusionReactorNodes()
        resetHydrogen()
    }

    func seekLock() {
        detuningPPM = 0.0
    }

    // MARK: - Zoom

    func setZoomedIn(_ zoom: Bool) {
        guard let cameraNode else { return }

        isZoomedIn = zoom

        let position = zoom
            ? SCNVector3(0, 3, 8)
            : SCNVector3(0, 12, 28)

        let move = SCNAction.move(to: position, duration: 0.6)
        move.timingMode = .easeInEaseOut

        cameraNode.runAction(move)
        cameraNode.look(at: SCNVector3(0, 0, 0))
    }

    // MARK: - Scene Setup

    private func setupScene() {
        scene.background.contents = UIColor.black

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = 200.0
        camera.position = SCNVector3(0, 12, 28)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)
        cameraNode = camera

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(white: 0.25, alpha: 1.0)
        scene.rootNode.addChildNode(ambient)

        haloLight.light = SCNLight()
        haloLight.light?.type = .omni
        haloLight.light?.color = UIColor.orange
        haloLight.light?.intensity = 0.0
        haloLight.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(haloLight)

        let chamber = SCNNode(geometry: SCNSphere(radius: 8.0))
        chamber.geometry?.firstMaterial?.diffuse.contents =
            UIColor.systemBlue.withAlphaComponent(0.06)
        chamber.geometry?.firstMaterial?.isDoubleSided = true
        chamber.geometry?.firstMaterial?.lightingModel = .constant
        scene.rootNode.addChildNode(chamber)

        addChamberLabel()

        setupSuperCoils()

        scene.rootNode.addChildNode(fieldLinesNode)
        scene.rootNode.addChildNode(fusionEventsNode)

        buildFieldLines()
        createWaveParticle()
    }

    private func addChamberLabel() {
        let textGeometry = SCNText(
            string: "FUSION CHAMBER",
            extrusionDepth: 0.05
        )

        textGeometry.font = UIFont.systemFont(
            ofSize: 0.26,
            weight: .bold
        )

        textGeometry.firstMaterial?.diffuse.contents = UIColor.cyan
        textGeometry.firstMaterial?.isDoubleSided = true

        let textNode = SCNNode(geometry: textGeometry)

        let (minimum, maximum) = textGeometry.boundingBox
        let width = maximum.x - minimum.x

        textNode.pivot = SCNMatrix4MakeTranslation(
            minimum.x + width / 2.0,
            minimum.y,
            0.0
        )

        textNode.position = SCNVector3(0, 9.5, 0)

        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        textNode.constraints = [billboard]

        scene.rootNode.addChildNode(textNode)
    }

    private func createWaveParticle() {
        let sphere = SCNSphere(radius: 0.2)
        let material = SCNMaterial()

        material.diffuse.contents = UIColor.cyan
        material.emission.contents = UIColor.cyan
        material.lightingModel = .constant
        material.isDoubleSided = true

        sphere.firstMaterial = material

        let node = SCNNode(geometry: sphere)
        node.position = SCNVector3(0, 0, 18)

        scene.rootNode.addChildNode(node)

        waveParticleNode = node
        waveParticlePhase = 0.0
    }

    private func setupSuperCoils() {
        for index in 0..<12 {
            let torus = SCNTorus(ringRadius: 9.2, pipeRadius: 0.75)
            let coil = SCNNode(geometry: torus)

            coil.rotation = SCNVector4(
                0,
                1,
                0,
                2.0 * Double.pi * Double(index) / 12.0
            )

            if let material = torus.firstMaterial {
                material.emission.contents = index.isMultiple(of: 2)
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
            SCNVector4(1, 0, 0, Double.pi / 2.0),
            SCNVector4(0, 0, 1, Double.pi / 2.0)
        ]

        for rotation in axes {
            let cylinder = SCNCylinder(radius: 0.045, height: 18.0)
            cylinder.firstMaterial?.emission.contents = UIColor.cyan

            let line = SCNNode(geometry: cylinder)
            line.rotation = rotation

            fieldLinesNode.addChildNode(line)
        }

        fieldLinesNode.isHidden = true
    }

    // MARK: - Reactor Nodes

    func createFusionReactorNodes(count: Int) {
        removeFusionReactorNodes()

        let positions: [SCNVector3] = [
            SCNVector3(-4, 0, 0),
            SCNVector3(4, 0, 0),
            SCNVector3(0, 4, 0),
            SCNVector3(0, -4, 0),
            SCNVector3(-3, 3, 0),
            SCNVector3(3, 3, 0),
            SCNVector3(-3, -3, 0),
            SCNVector3(3, -3, 0)
        ]

        for index in 0..<min(count, positions.count) {
            let capsule = SCNCapsule(capRadius: 0.4, height: 1.5)
            let material = SCNMaterial()

            material.emission.contents = UIColor.systemOrange
            material.diffuse.contents =
                UIColor.orange.withAlphaComponent(0.7)
            material.lightingModel = .physicallyBased

            capsule.materials = [material]

            let node = SCNNode(geometry: capsule)
            node.position = positions[index]
            node.name = "FusionReactorNode"

            let pulse = SCNAction.customAction(duration: 1.0) {
                _, elapsedTime in

                let fraction = elapsedTime / 1.0
                let intensity = 0.6 + 0.4 * sin(fraction * .pi * 2.0)

                material.emission.contents =
                    UIColor.orange.withAlphaComponent(CGFloat(intensity))
            }

            node.runAction(.repeatForever(pulse))

            scene.rootNode.addChildNode(node)
            fusionReactorNodes.append(node)
        }
    }

    private func removeFusionReactorNodes() {
        fusionReactorNodes.forEach { $0.removeFromParentNode() }
        fusionReactorNodes.removeAll()
    }

    // MARK: - Fuel Inventory

    private func randomPosition() -> SCNVector3 {
        let radius: Float = 6.0

        return SCNVector3(
            Float.random(in: -radius...radius),
            Float.random(in: -radius...radius),
            Float.random(in: -radius...radius)
        )
    }

    @discardableResult
    private func spawnHydrogen(at position: SCNVector3) -> FusionParticle {
        let sphere = SCNSphere(radius: Species.proton.radius)
        let node = SCNNode(geometry: sphere)

        node.geometry?.firstMaterial?.diffuse.contents =
            Species.proton.color

        node.geometry?.firstMaterial?.emission.contents =
            Species.proton.color.withAlphaComponent(0.5)

        node.position = position

        let twister = SCNNode(
            geometry: SCNCylinder(
                radius: 0.05,
                height: Species.proton.radius * 3.6
            )
        )

        twister.geometry?.firstMaterial?.emission.contents = UIColor.cyan
        twister.rotation = SCNVector4(1, 1, 0, Double.pi / 2.0)

        node.addChildNode(twister)
        scene.rootNode.addChildNode(node)

        let particle = FusionParticle(node: node, species: .proton)
        particles.append(particle)

        return particle
    }

    private func spawnHelium4(at position: SCNVector3) {
        let sphere = SCNSphere(radius: Species.helium4.radius)
        let node = SCNNode(geometry: sphere)

        node.position = position

        node.geometry?.firstMaterial?.diffuse.contents =
            Species.helium4.color

        node.geometry?.firstMaterial?.emission.contents =
            Species.helium4.color

        scene.rootNode.addChildNode(node)
        heliumNodes.append(node)

        let pulse = SCNAction.sequence([
            .scale(to: 1.35, duration: 0.25),
            .scale(to: 1.0, duration: 0.25)
        ])

        node.runAction(pulse)
    }

    private func resetHydrogen() {
        particles.forEach { $0.node.removeFromParentNode() }
        particles.removeAll()

        heliumNodes.forEach { $0.removeFromParentNode() }
        heliumNodes.removeAll()

        fusionEventsNode.childNodes.forEach {
            $0.removeFromParentNode()
        }

        for _ in 0..<particleCount {
            spawnHydrogen(at: randomPosition())
        }

        hydrogenCount = particles.count
        coupledCount = 0
        heliumCount = 0
        totalReactions = 0
        reactionRateHz = 0.0
        fusionProbability = 0.0
        frameFusionEnergyMeV = 0.0
        frameEvents = 0

        if waveParticleNode == nil {
            createWaveParticle()
        }
    }

    private func adjustHydrogenInventory() {
        let desired = max(
            FusionConstants.protonsPerFusion,
            particleCount
        )

        if desired > particles.count {
            for _ in 0..<(desired - particles.count) {
                spawnHydrogen(at: randomPosition())
            }
        } else if desired < particles.count {
            var numberToRemove = particles.count - desired
            var index = particles.count - 1

            while numberToRemove > 0 && index >= 0 {
                if !particles[index].coupled {
                    particles[index].node.removeFromParentNode()
                    particles.remove(at: index)
                    numberToRemove -= 1
                }

                index -= 1
            }
        }

        hydrogenCount = particles.count
    }

    private func replenishHydrogen() {
        let deficit = particleCount - particles.count

        guard deficit > 0 else { return }

        for _ in 0..<min(deficit, 2) {
            spawnHydrogen(at: randomPosition())
        }

        hydrogenCount = particles.count
    }

    // MARK: - Main Update

    private func update() {
        let dt = simulationTimeStep

        updateWaveParticle(dt: dt)
        updateCoilAnimation()

        updateQRTLResonance()
        updateEnergyShell(dt: dt)
        stepHydrogenLattice()
        runHydrogenToHeliumFusion()
        replenishHydrogen()
        updatePower(dt: dt)
        updateVisualFeedback()
    }

    private func updateWaveParticle(dt: Double) {
        if waveParticleNode == nil {
            createWaveParticle()
        }

        // Visual animation only; this does not render 1e15 Hz directly.
        waveParticlePhase +=
            dt * targetFrequencyHz / 1.0e15 * 2.0 * Double.pi

        let interpolation = 0.5 * (1.0 + sin(waveParticlePhase))
        let sourceZ: Float = 18.0
        let targetZ: Float = 0.0

        let positionZ =
            sourceZ * Float(1.0 - interpolation)
            + targetZ * Float(interpolation)

        waveParticleNode?.position = SCNVector3(0, 0, positionZ)
    }

    private func updateCoilAnimation() {
        phase += 0.05

        for (index, coil) in superCoils.enumerated() {
            coil.eulerAngles.y = Float(phase + Double(index) * 0.3)
        }
    }

    // MARK: - Stage 1: Resonance

    private func updateQRTLResonance() {
        if autoLockEnabled {
            detuningPPM *= 0.97

            if abs(detuningPPM) < 0.01 {
                detuningPPM = 0.0
            }
        }

        phaseErrorRad = QRTLModel.phaseError(
            detuningPPM: detuningPPM
        )

        coherence = QRTLModel.coherence(
            detuningPPM: detuningPPM,
            magneticField: magneticField
        )

        latticeProbability = QRTLModel.latticeProbability(
            coherence: coherence
        )

        latticeOrder = QRTLModel.latticeOrder(
            coherence: coherence,
            magneticField: magneticField
        )

        fusionProbability = QRTLModel.fusionProbability(
            coherence: coherence,
            latticeOrder: latticeOrder,
            latticeProbability: latticeProbability,
            yieldScale: reactionYieldScale
        )
    }

    // MARK: - Shell Energy Model

    private func updateEnergyShell(dt: Double) {
        guard dt.isFinite, dt > 0.0 else { return }

        guard coherence > 0.0 else {
            shellPhase = "idle"
            shellResonanceEnvelope = 0.0
            return
        }

        let detuningRatio =
            abs(appliedFrequencyHz - shellNaturalFrequencyHz)
            / max(shellNaturalFrequencyHz, 1.0)

        let bandwidth = max(
            30.0e-6,
            1.0 / shellQualityFactor
        )

        shellResonanceEnvelope = min(
            1.0,
            max(
                0.0,
                exp(-0.5 * pow(detuningRatio / bandwidth, 2.0))
                    * coherence
            )
        )

        let cryoPowerMW = 0.6 + magneticField * 0.12
        let rfPowerMW = 1.2 * (
            1.0 + 0.01 * min(abs(detuningPPM), 50.0)
        )
        let controlPowerMW = 0.3

        let drivePowerW =
            (cryoPowerMW + rfPowerMW + controlPowerMW)
            * 1.0e6
            * shellDriveFraction
            * shellResonanceEnvelope

        let canAccumulate =
            shellResonanceEnvelope > 0.05
                && shellStoredEnergyJ < shellMaxStoredEnergyJ

        if canAccumulate {
            shellStoredEnergyJ = min(
                shellMaxStoredEnergyJ,
                shellStoredEnergyJ + max(0.0, drivePowerW * dt)
            )

            shellFormationTime += dt
        }

        updateShellDisplacement()

        guard shellFormationTime >= shellFormationSeconds else {
            shellPhase = "forming"
            return
        }

        guard shellResonanceEnvelope > 0.80 else {
            shellPhase = "forming"
            return
        }

        // Only discharge after a meaningful reservoir has accumulated.
        guard !shellEnergyReleasedThisCycle else {
            shellPhase = "recharging"
            return
        }

        guard shellStoredEnergyJ >= shellMaxStoredEnergyJ * 0.95 else {
            shellPhase = "compressed"
            return
        }

        let releaseJ = shellStoredEnergyJ * shellReleaseFraction

        shellStoredEnergyJ -= releaseJ
        shellEnergyReleasedJ += releaseJ
        latticeEnergyInputJ += releaseJ

        shellEnergyReleasedThisCycle = true
        shellPhase = "released"

        updateShellDisplacement()

        // Permit a new discharge only after the reservoir has recharged.
        if shellStoredEnergyJ <= shellMaxStoredEnergyJ * 0.25 {
            shellEnergyReleasedThisCycle = false
            shellFormationTime = shellFormationSeconds
        }
    }

    private func updateShellDisplacement() {
        shellDisplacementM = sqrt(
            max(
                0.0,
                2.0 * shellStoredEnergyJ
                    / shellRestoringConstantNPerM
            )
        )
    }

    // MARK: - Stage 2: Lattice Coupling

    private func vectorLength(_ vector: SCNVector3) -> Float {
        sqrtf(
            vector.x * vector.x
                + vector.y * vector.y
                + vector.z * vector.z
        )
    }

    private func stepHydrogenLattice() {
        let jitter = Float(max(0.0, 1.0 - coherence)) * 0.04
        let cosine = cosf(0.03)
        let sine = sinf(0.03)

        var coupled = 0

        for particle in particles {
            var position = particle.node.position

            if particle.coupled {
                position.x -= position.x * 0.03
                position.y -= position.y * 0.03
                position.z -= position.z * 0.03

                let x = position.x * cosine - position.z * sine
                let z = position.x * sine + position.z * cosine

                position.x = x
                position.z = z

                let localJitter = jitter * 0.25

                position.x += Float.random(
                    in: -localJitter...localJitter
                )
                position.y += Float.random(
                    in: -localJitter...localJitter
                )
                position.z += Float.random(
                    in: -localJitter...localJitter
                )

                particle.node.position = position

                if coherence < 0.60 {
                    particle.coupled = false
                    particle.node.scale = SCNVector3(1, 1, 1)

                    particle.node.geometry?.firstMaterial?
                        .emission.contents =
                        Species.proton.color.withAlphaComponent(0.5)
                } else {
                    coupled += 1
                }
            } else {
                let pull: Float = 0.0018

                position.x +=
                    -position.x * pull
                    + Float.random(in: -jitter...jitter)

                position.y +=
                    -position.y * pull
                    + Float.random(in: -jitter...jitter)

                position.z +=
                    -position.z * pull
                    + Float.random(in: -jitter...jitter)

                particle.node.position = position

                if vectorLength(position) < 2.8 && coherence > 0.75 {
                    particle.coupled = true
                    particle.node.scale = SCNVector3(0.7, 0.7, 0.7)

                    particle.node.geometry?.firstMaterial?
                        .emission.contents = Species.proton.color

                    coupled += 1
                }
            }
        }

        coupledCount = coupled
        hydrogenCount = particles.count
    }

    // MARK: - Stage 3: H → He-4 Model

    private func runHydrogenToHeliumFusion() {
        guard coherence > 0.85,
              latticeOrder > 0.60,
              latticeProbability > 0.90,
              shellResonanceEnvelope > 0.80,
              shellStoredEnergyJ > 0.0
        else {
            return
        }

        let coupledParticles = particles.filter(\.coupled)

        guard coupledParticles.count >= FusionConstants.protonsPerFusion else {
            return
        }

        var consumed = Set<ObjectIdentifier>()
        var eventsThisFrame = 0

        while eventsThisFrame < maxEventsPerFrame {
            let available = coupledParticles.filter {
                !consumed.contains(ObjectIdentifier($0))
            }

            guard available.count >= FusionConstants.protonsPerFusion,
                  let group = findProtonFusionGroup(in: available)
            else {
                break
            }

            guard Double.random(in: 0..<1) < fusionProbability else {
                break
            }

            fuseFourProtons(group)

            for proton in group {
                consumed.insert(ObjectIdentifier(proton))
            }

            eventsThisFrame += 1
        }
    }

    private func findProtonFusionGroup(
        in protons: [FusionParticle]
    ) -> [FusionParticle]? {
        guard protons.count >= FusionConstants.protonsPerFusion else {
            return nil
        }

        for index in 0..<(protons.count - 3) {
            let anchor = protons[index]
            var group = [anchor]

            for candidateIndex in (index + 1)..<protons.count {
                let candidate = protons[candidateIndex]

                let dx =
                    anchor.node.position.x - candidate.node.position.x
                let dy =
                    anchor.node.position.y - candidate.node.position.y
                let dz =
                    anchor.node.position.z - candidate.node.position.z

                let distance = sqrtf(dx * dx + dy * dy + dz * dz)

                if distance <= pairingRadius {
                    group.append(candidate)
                }

                if group.count == FusionConstants.protonsPerFusion {
                    return group
                }
            }
        }

        return nil
    }

    private func fuseFourProtons(_ protons: [FusionParticle]) {
        guard protons.count == FusionConstants.protonsPerFusion else {
            return
        }

        let midpoint = SCNVector3(
            Float(protons.reduce(0.0) {
                $0 + Double($1.node.position.x)
            } / Double(protons.count)),

            Float(protons.reduce(0.0) {
                $0 + Double($1.node.position.y)
            } / Double(protons.count)),

            Float(protons.reduce(0.0) {
                $0 + Double($1.node.position.z)
            } / Double(protons.count))
        )

        let event = FusionEvent.hydrogenToHelium4

        for proton in protons {
            proton.node.removeFromParentNode()
        }

        particles.removeAll { particle in
            protons.contains { $0 === particle }
        }

        spawnHelium4(at: midpoint)

        heliumCount += event.heliumProduced
        totalReactions += 1
        frameEvents += 1
        frameFusionEnergyMeV += event.energyMeV

        spawnFusionFlash(
            at: midpoint,
            energyMeV: event.energyMeV
        )
    }

    // MARK: - Fusion Flash

    private func spawnFusionFlash(
        at position: SCNVector3,
        energyMeV: Double
    ) {
        let radius = CGFloat(0.25 + 0.02 * energyMeV)

        let flash = SCNNode(
            geometry: SCNSphere(radius: radius)
        )

        flash.geometry?.firstMaterial?.emission.contents = UIColor.yellow
        flash.geometry?.firstMaterial?.diffuse.contents = UIColor.yellow

        // This was previously hard-coded to (0, 0, 0), not the reaction.
        flash.position = position

        fusionEventsNode.addChildNode(flash)

        let grow = SCNAction.scale(to: 4.0, duration: 0.4)
        let fade = SCNAction.fadeOut(duration: 0.4)

        flash.runAction(
            .sequence([
                .group([grow, fade]),
                .removeFromParentNode()
            ])
        )
    }

    // MARK: - Stage 4: Power Accounting

    private func updatePower(dt: Double) {
        let cryoPowerMW = 0.6 + magneticField * 0.12

        let rfPowerMW = 1.2 * (
            1.0 + 0.01 * min(abs(detuningPPM), 50.0)
        )

        let controlPowerMW = 0.3

        inputPowerMW =
            cryoPowerMW
            + rfPowerMW
            + controlPowerMW

        let instantaneousFusionMW =
            frameFusionEnergyMeV
            * FusionConstants.mevToJoule
            * macroParticleWeight
            / dt
            / 1.0e6

        let alpha = 0.03

        fusionPowerFilteredMW += alpha * (
            instantaneousFusionMW - fusionPowerFilteredMW
        )

        reactionRateHz += alpha * (
            Double(frameEvents) / dt - reactionRateHz
        )

        fusionPowerMW = fusionPowerFilteredMW
        electricalOutputMW =
            fusionPowerMW * directConversionEfficiency

        netPowerMW = electricalOutputMW - inputPowerMW

        cumulativeNetMWh +=
            max(0.0, netPowerMW) * dt / 3600.0

        qFactor = inputPowerMW > 0.0
            ? fusionPowerMW / inputPowerMW
            : 0.0

        energyPerReactionMeV =
            FusionConstants.effectiveFusionEnergyMeV

        frameFusionEnergyMeV = 0.0
        frameEvents = 0

        updateOutputCurrent()
    }

    private func updateOutputCurrent() {
        let voltageV = max(1.0, extractionVoltageKV * 1000.0)

        outputCurrentA =
            electricalOutputMW * 1.0e6 / voltageV
    }

    // MARK: - Visual Feedback

    private func updateVisualFeedback() {
        fieldLinesNode.isHidden = coherence <= 0.65

        let glow = CGFloat(
            min(
                0.9,
                max(0.0, qFactor / 5.0)
            )
        )

        for coil in superCoils {
            coil.geometry?.firstMaterial?.emission.contents =
                coherence > 0.85
                    ? UIColor.green.withAlphaComponent(0.8)
                    : UIColor.cyan.withAlphaComponent(0.6)
        }

        haloLight.light?.intensity = CGFloat(coherence * 1200.0)

        haloLight.light?.color = isFusing
            ? UIColor.yellow
            : (isLocked ? UIColor.green : UIColor.orange)

        for helium in heliumNodes {
            helium.opacity = max(0.45, Double(glow) + 0.45)
        }
    }
}
