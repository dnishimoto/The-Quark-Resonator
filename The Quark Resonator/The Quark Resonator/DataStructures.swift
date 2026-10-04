//
//  File.swift
//  The Quark Resonator
//
//  Created by David Nishimoto on 9/30/26.
//

import Foundation
import SwiftUI
import SceneKit

struct FusionPrediction {
    var coherence: Double = 0.0
    var latticeOrder: Double = 0.0
    var latticeProbability: Double = 0.0

    /// Probability of a four-proton event per attempt.
    var eventProbability: Double = 0.0

    /// Predicted modeled events per second.
    var eventsPerSecond: Double = 0.0
    var secondsToFirstEvent: Double? = nil

    var fusionPowerMW: Double = 0.0
    var inputPowerMW: Double = 0.0
    var qFactor: Double = 0.0

    var predicted: Bool = false
    var reason: String = "waiting for 1e15 Hz"
}

enum FusionPredictor {

    /// The fusion simulator tries events once per 60 Hz frame, up to 2 per frame.
    static let attemptsPerSecond: Double = 60.0
    static let maxEventsPerAttempt: Int = 2

    static let macroParticleWeight: Double = 1.0e18
    static let directConversionEfficiency: Double = 0.80

    static func predict(
        detuningPPM: Double,
        magneticField: Double,
        coupledProtons: Int,
        yieldScale: Double = 1.0
    ) -> FusionPrediction {

        var p = FusionPrediction()

        p.coherence = QRTLModel.coherence(
            detuningPPM: detuningPPM,
            magneticField: magneticField
        )

        p.latticeProbability = QRTLModel.latticeProbability(
            coherence: p.coherence
        )

        p.latticeOrder = QRTLModel.latticeOrder(
            coherence: p.coherence,
            magneticField: magneticField
        )

        p.eventProbability = QRTLModel.fusionProbability(
            coherence: p.coherence,
            latticeOrder: p.latticeOrder,
            latticeProbability: p.latticeProbability,
            yieldScale: yieldScale
        )

        // Conceptual input power, same terms as the fusion simulator.
        let cryoMW = 0.6 + magneticField * 0.12
        let rfMW = 1.2 * (1.0 + 0.01 * min(abs(detuningPPM), 50.0))
        let controlMW = 0.3
        p.inputPowerMW = cryoMW + rfMW + controlMW

        let groups = coupledProtons / FusionConstants.protonsPerFusion
        let attempts = min(groups, maxEventsPerAttempt)

        if p.coherence <= 0.85 {
            p.reason = String(format: "coherence %.2f <= 0.85", p.coherence)
        } else if p.latticeOrder <= 0.60 {
            p.reason = String(format: "lattice order %.2f <= 0.60", p.latticeOrder)
        } else if p.latticeProbability <= 0.90 {
            p.reason = String(format: "lattice prob %.2f <= 0.90", p.latticeProbability)
        } else if groups < 1 {
            p.reason = "fewer than 4 coupled protons"
        } else if p.eventProbability <= 0.0 {
            p.reason = "event probability is zero"
        } else {
            p.predicted = true
            p.reason = "all QRTL gates passed"

            p.eventsPerSecond =
                Double(attempts) * p.eventProbability * attemptsPerSecond

            p.secondsToFirstEvent =
                p.eventsPerSecond > 0 ? 1.0 / p.eventsPerSecond : nil

            p.fusionPowerMW =
                p.eventsPerSecond *
                FusionConstants.effectiveFusionEnergyMeV *
                FusionConstants.mevToJoule *
                macroParticleWeight /
                1.0e6

            p.qFactor =
                p.inputPowerMW > 0 ? p.fusionPowerMW / p.inputPowerMW : 0.0
        }

        return p
    }
}

// MARK: - Phase

enum FusionChamberPhase: Int {
    case dormant = 0
    case emRamp
    case injection
    case resonance
    case active
}

// MARK: - Vector helpers (file private)

private func fcAdd(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
    SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z)
}

private func fcSub(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
    SCNVector3(a.x - b.x, a.y - b.y, a.z - b.z)
}

private func fcScale(_ a: SCNVector3, _ s: Float) -> SCNVector3 {
    SCNVector3(a.x * s, a.y * s, a.z * s)
}

private func fcMix(_ a: SCNVector3, _ b: SCNVector3, _ t: Float) -> SCNVector3 {
    fcAdd(a, fcScale(fcSub(b, a), t))
}

private func fcRandomInSphere(_ radius: Float) -> SCNVector3 {
    while true {
        let v = SCNVector3(
            Float.random(in: -1...1),
            Float.random(in: -1...1),
            Float.random(in: -1...1)
        )
        if v.x * v.x + v.y * v.y + v.z * v.z <= 1.0 {
            return fcScale(v, radius)
        }
    }
}

// MARK: - Fuel proton

private final class FuelProton {
    let node: SCNNode
    let slot: Int
    var wander: SCNVector3
    var consumed = false

    init(node: SCNNode, slot: Int, wander: SCNVector3) {
        self.node = node
        self.slot = slot
        self.wander = wander
    }
}

// MARK: - Stage

final class FusionChamberStageNode: SCNNode {

    // MARK: Geometry constants

    static let chamberRadius: Float = 1.5
    static let entryLength: Float = 0.6
    static var centerX: Float { entryLength + chamberRadius }
    static var endX: Float { entryLength + 2.0 * chamberRadius }

    // MARK: Sequence constants

    /// EM field the coils ramp to (tesla), same as the fusion simulator default.
    private let emTargetTesla: Double = 8.5
    private let emRampSeconds: Double = 2.5
    private let resonanceSeconds: Double = 2.5

    /// Four groups of four protons on the lattice.
    private let fuelTarget = 16
    private let injectInterval: Double = 0.18
    private let replenishInterval: Double = 0.35

    /// Visual fusion events per second are capped at this.
    private let visualRateCap: Double = 1.5

    // MARK: Inputs

    private struct Inputs {
        var frequencyHz: Double = 0.0
        var lockErrorFraction: Double = 1.0
        var targetLocked: Bool = false
        var uvStrength: Double = 0.0
        var shellExcited: Bool = false
        var running: Bool = false
    }

    private var input = Inputs()

    // MARK: Published results

    private(set) var phase: FusionChamberPhase = .dormant
    private(set) var prediction = FusionPrediction()
    private(set) var fieldTesla: Double = 0.0
    private(set) var heliumCount: Int = 0

    // MARK: Nodes

    private let uvBeam = SCNNode()
    private let coreNode = SCNNode()
    private let haloNode = SCNNode()
    private let vesselNode = SCNNode()
    private let coreLight = SCNNode()
    private let fuelNode = SCNNode()
    private let resonanceRing = SCNNode()
    private let waveNode = SCNNode()
    private var coilMaterials: [SCNMaterial] = []

    private var statusReadout = SCNNode()
    private var fieldReadout = SCNNode()
    private var fuelReadout = SCNNode()
    private var predictionReadout = SCNNode()

    private var lastStatus = ""
    private var lastField = ""
    private var lastFuel = ""
    private var lastPrediction = ""

    // MARK: Colors

    private let uvColor = UIColor(red: 0.62, green: 0.30, blue: 1.0, alpha: 1.0)
    private let fusionColor = UIColor(red: 1.0, green: 0.55, blue: 0.10, alpha: 1.0)
    private let emColor = UIColor(red: 0.20, green: 0.75, blue: 0.95, alpha: 1.0)

    // MARK: Runtime state

    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var lostTime: Double = 0
    private var phaseTime: Double = 0
    private var spawnTimer: Double = 0
    private var readoutTimer: Double = 1.0
    private var lastIdleRefresh: CFTimeInterval = 0
    private var resonanceProgress: Double = 0

    /// Residual detuning (ppm) of the protons from the 1e15 Hz drive.
    /// Starts at the resonator's lock error and is pulled to zero by the UV
    /// resonance, the same servo behaviour as FusionResonatorSimulator's auto-lock
    /// (x0.97 per 60 Hz frame).
    private var detuningPPM: Double = 0
    private let resonanceTimeoutSeconds: Double = 20.0

    private var protons: [FuelProton] = []
    private var usedSlots = Set<Int>()
    private let protonGeometry = SCNSphere(radius: 0.07)

    /// Lattice sites: 4 groups (tetrahedron) of 4 protons (small tetrahedron).
    private static let sites: [SCNVector3] = {
        let dirs: [(Float, Float, Float)] = [
            (1, 1, 1), (1, -1, -1), (-1, 1, -1), (-1, -1, 1)
        ]
        let inv: Float = 1.0 / Float(3.0).squareRoot()
        var out: [SCNVector3] = []
        for g in 0..<4 {
            let d = dirs[g]
            let c = SCNVector3(d.0 * inv * 0.75, d.1 * inv * 0.75, d.2 * inv * 0.75)
            for k in 0..<4 {
                let s = dirs[k]
                out.append(SCNVector3(
                    c.x + s.0 * inv * 0.16,
                    c.y + s.1 * inv * 0.16,
                    c.z + s.2 * inv * 0.16
                ))
            }
        }
        return out
    }()

    // MARK: Init

    override init() {
        super.init()
        name = "FusionChamberStage"
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: Helpers

    private func material(_ color: UIColor, emissive: Bool = false, alpha: CGFloat = 1.0) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color.withAlphaComponent(alpha)
        if emissive { m.emission.contents = color }
        m.lightingModel = .blinn
        return m
    }

    private func beamAlongX(from x0: Float, to x1: Float, radius: CGFloat, color: UIColor) -> SCNNode {
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(abs(x1 - x0)))
        cylinder.firstMaterial = material(color, emissive: true)
        let node = SCNNode(geometry: cylinder)
        node.eulerAngles.z = Float.pi / 2
        node.position = SCNVector3((x0 + x1) / 2, 0, 0)
        return node
    }

    private func makeText(_ string: String, color: UIColor, size: CGFloat) -> SCNNode {
        let text = SCNText(string: string, extrusionDepth: 0.02)
        text.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        text.flatness = 0.1
        text.firstMaterial = material(color, emissive: true)

        let node = SCNNode(geometry: text)
        recenter(node)
        let s = Float(size / 10.0)
        node.scale = SCNVector3(s, s, s)

        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        node.constraints = [billboard]
        return node
    }

    private func recenter(_ node: SCNNode) {
        let (minB, maxB) = node.boundingBox
        node.pivot = SCNMatrix4MakeTranslation((maxB.x + minB.x) / 2, (maxB.y + minB.y) / 2, 0)
    }

    private func setText(_ node: SCNNode, _ string: String, color: UIColor) {
        guard let text = node.geometry as? SCNText else { return }
        text.string = string
        text.firstMaterial?.diffuse.contents = color
        text.firstMaterial?.emission.contents = color
        recenter(node)
    }

    // MARK: Build

    private func build() {

        let radius = CGFloat(Self.chamberRadius)
        let cx = Self.centerX
        let R = Self.chamberRadius

        // Base plate and cradle
        let base = SCNBox(width: 4.0, height: 0.16, length: 3.4, chamferRadius: 0.04)
        base.firstMaterial = material(UIColor(white: 0.20, alpha: 1.0))
        let baseNode = SCNNode(geometry: base)
        baseNode.position = SCNVector3(cx, -R - 0.16, 0)
        addChildNode(baseNode)

        let cradle = SCNCylinder(radius: 0.45, height: 0.16)
        cradle.firstMaterial = material(UIColor(white: 0.40, alpha: 1.0))
        let cradleNode = SCNNode(geometry: cradle)
        cradleNode.position = SCNVector3(cx, -R - 0.04, 0)
        addChildNode(cradleNode)

        // UV entry tube and flange
        let tube = SCNCylinder(radius: 0.2, height: CGFloat(Self.entryLength))
        tube.firstMaterial = material(UIColor(white: 0.35, alpha: 1.0))
        let tubeNode = SCNNode(geometry: tube)
        tubeNode.eulerAngles.z = Float.pi / 2
        tubeNode.position = SCNVector3(Self.entryLength / 2, 0, 0)
        addChildNode(tubeNode)

        let flange = SCNTorus(ringRadius: 0.24, pipeRadius: 0.05)
        flange.firstMaterial = material(UIColor(white: 0.65, alpha: 1.0))
        let flangeNode = SCNNode(geometry: flange)
        flangeNode.eulerAngles.z = Float.pi / 2
        flangeNode.position = SCNVector3(Self.entryLength, 0, 0)
        addChildNode(flangeNode)

        // Reaction vessel
        let vessel = SCNSphere(radius: radius)
        vessel.segmentCount = 48
        let vesselMaterial = material(.systemBlue, alpha: 0.10)
        vesselMaterial.lightingModel = .constant
        vesselMaterial.isDoubleSided = true
        vesselMaterial.writesToDepthBuffer = false
        vessel.firstMaterial = vesselMaterial
        vesselNode.geometry = vessel
        vesselNode.position = SCNVector3(cx, 0, 0)
        vesselNode.renderingOrder = 10
        addChildNode(vesselNode)

        // EM coils (glow follows the field)
        for offset in [-0.8, 0.0, 0.8] as [CGFloat] {
            let coilRadius = sqrt(max(radius * radius - offset * offset, 0.01)) + 0.06
            let coil = SCNTorus(ringRadius: coilRadius, pipeRadius: 0.05)
            let m = material(UIColor(white: 0.30, alpha: 1.0))
            m.emission.contents = emColor
            m.emission.intensity = 0.0
            coil.firstMaterial = m
            coilMaterials.append(m)

            let coilNode = SCNNode(geometry: coil)
            coilNode.eulerAngles.z = Float.pi / 2
            coilNode.position = SCNVector3(cx + Float(offset), 0, 0)
            addChildNode(coilNode)
        }

        // Hydrogen injector on top of the vessel
        let injector = SCNCylinder(radius: 0.12, height: 0.34)
        injector.firstMaterial = material(UIColor(white: 0.45, alpha: 1.0))
        let injectorNode = SCNNode(geometry: injector)
        injectorNode.position = SCNVector3(cx, R + 0.17, 0)
        addChildNode(injectorNode)

        let injectorTip = SCNTorus(ringRadius: 0.13, pipeRadius: 0.03)
        injectorTip.firstMaterial = material(.systemOrange, emissive: true)
        let injectorTipNode = SCNNode(geometry: injectorTip)
        injectorTipNode.position = SCNVector3(cx, R + 0.34, 0)
        addChildNode(injectorTipNode)

        // UV beam: BBO port -> entry tube -> reaction core
        uvBeam.addChildNode(beamAlongX(from: 0.0, to: cx, radius: 0.06, color: uvColor))
        uvBeam.opacity = 0.05
        addChildNode(uvBeam)

        // Reaction core, halo and light
        let core = SCNSphere(radius: 0.28)
        let coreMaterial = material(fusionColor, emissive: true, alpha: 0.9)
        coreMaterial.emission.intensity = 0.0
        core.firstMaterial = coreMaterial
        coreNode.geometry = core
        coreNode.position = SCNVector3(cx, 0, 0)
        addChildNode(coreNode)

        let halo = SCNSphere(radius: 0.55)
        let haloMaterial = material(fusionColor, emissive: true, alpha: 0.25)
        haloMaterial.lightingModel = .constant
        haloMaterial.writesToDepthBuffer = false
        halo.firstMaterial = haloMaterial
        haloNode.geometry = halo
        haloNode.position = SCNVector3(cx, 0, 0)
        haloNode.opacity = 0.0
        haloNode.renderingOrder = 11
        addChildNode(haloNode)

        let light = SCNLight()
        light.type = .omni
        light.color = fusionColor
        light.intensity = 0
        coreLight.light = light
        coreLight.position = SCNVector3(cx, 0, 0)
        addChildNode(coreLight)

        // UV resonance ring (pulses while the UV drives the protons)
        let ring = SCNTorus(ringRadius: 1.0, pipeRadius: 0.015)
        let ringMaterial = material(uvColor, emissive: true)
        ringMaterial.lightingModel = .constant
        ring.firstMaterial = ringMaterial
        resonanceRing.geometry = ring
        resonanceRing.eulerAngles.z = Float.pi / 2
        resonanceRing.position = SCNVector3(cx, 0, 0)
        resonanceRing.opacity = 0.0
        addChildNode(resonanceRing)

        let ringPulse = SCNAction.sequence([
            SCNAction.scale(to: 1.12, duration: 0.25),
            SCNAction.scale(to: 0.88, duration: 0.25)
        ])
        resonanceRing.runAction(SCNAction.repeatForever(ringPulse))

        // UV wave: a train of particles that travel from the BBO port to the core
        // while wobbling transversely. Visual only; it does not draw 1e15 Hz.
        addChildNode(waveNode)
        waveNode.opacity = 0.0

        let waveCount = 7
        let waveLength = cx
        var waveParticles: [SCNNode] = []

        for i in 0..<waveCount {
            let big = (i == 0)
            let sphere = SCNSphere(radius: big ? 0.16 : 0.07)
            let m = SCNMaterial()
            m.diffuse.contents = big ? UIColor.cyan : uvColor
            m.emission.contents = big ? UIColor.cyan : uvColor
            m.lightingModel = .constant
            sphere.firstMaterial = m
            let n = SCNNode(geometry: sphere)
            waveNode.addChildNode(n)
            waveParticles.append(n)
        }

        let waveAction = SCNAction.customAction(duration: 1.0e6) { _, elapsed in
            let t = Double(elapsed)
            for (i, n) in waveParticles.enumerated() {
                let f = (t * 0.55 + Double(i) / Double(waveCount)).truncatingRemainder(dividingBy: 1.0)
                let x = Float(f) * waveLength
                let wobble = Float(0.14 * sin(2.0 * Double.pi * (f * 6.0 - t * 2.0)))
                n.position = SCNVector3(x, wobble, 0)
            }
        }
        waveNode.runAction(waveAction)

        // Fuel container (protons live in vessel-centre coordinates)
        fuelNode.position = SCNVector3(cx, 0, 0)
        addChildNode(fuelNode)

        let protonMaterial = material(.systemOrange, emissive: true)
        protonGeometry.firstMaterial = protonMaterial

        // Labels
        let title = makeText("FUSION CHAMBER", color: .cyan, size: 0.30)
        title.position = SCNVector3(cx, R + 1.1, 0)
        addChildNode(title)

        statusReadout = makeText("AWAITING UV", color: .lightGray, size: 0.26)
        statusReadout.position = SCNVector3(cx, R + 0.75, 0)
        addChildNode(statusReadout)

        let injectorLabel = makeText("H INJECTOR", color: .systemOrange, size: 0.18)
        injectorLabel.position = SCNVector3(cx + 0.85, R + 0.34, 0)
        addChildNode(injectorLabel)

        let inLabel = makeText("UV IN", color: uvColor, size: 0.22)
        inLabel.position = SCNVector3(Self.entryLength / 2, 0.5, 0)
        addChildNode(inLabel)

        let waveLabel = makeText("UV 1.000e15 Hz", color: .cyan, size: 0.18)
        waveLabel.position = SCNVector3(cx * 0.55, 0.55, 0)
        addChildNode(waveLabel)

        let emLabel = makeText("EM COILS", color: emColor, size: 0.18)
        emLabel.position = SCNVector3(cx - 1.25, R * 0.75, 0.6)
        addChildNode(emLabel)

        fieldReadout = makeText("B 0.0 T", color: .lightGray, size: 0.22)
        fieldReadout.position = SCNVector3(cx, -R - 0.45, 0.9)
        addChildNode(fieldReadout)

        fuelReadout = makeText("H 0  He-4 0", color: .lightGray, size: 0.22)
        fuelReadout.position = SCNVector3(cx, -R - 0.80, 0.9)
        addChildNode(fuelReadout)

        predictionReadout = makeText("--", color: .lightGray, size: 0.22)
        predictionReadout.position = SCNVector3(cx, -R - 1.15, 0.9)
        addChildNode(predictionReadout)
    }

    // MARK: External update

    /// Call from the scene controller's `update(state:)`.
    ///
    /// - Parameters:
    ///   - frequencyHz: resonator output frequency (state.outputFrequencyHz).
    ///   - lockErrorFraction: |actual - target| / target (state.frequencyLockErrorFraction).
    ///   - uvStrength: 0...1, UV arriving from the BBO stage.
    ///   - shellExcited: state.helium4ShellExcited (shown in the readout).
    ///   - running: whether the simulation is running.
    func update(
        frequencyHz: Double,
        lockErrorFraction: Double,
        targetLocked: Bool,
        uvStrength: Double,
        shellExcited: Bool,
        running: Bool
    ) {
        input = Inputs(
            frequencyHz: frequencyHz,
            lockErrorFraction: lockErrorFraction,
            targetLocked: targetLocked,
            uvStrength: max(0.0, min(1.0, uvStrength)),
            shellExcited: shellExcited,
            running: running
        )

        let uvLive = running && input.uvStrength > 0.05
        uvBeam.opacity = uvLive ? CGFloat(0.05 + 0.95 * input.uvStrength) : 0.05

        // UV wave particle is visible whenever UV is arriving from the BBO crystal
        waveNode.opacity = uvLive ? CGFloat(0.3 + 0.7 * input.uvStrength) : 0.0

        if sequenceWanted && timer == nil {
            startTimer()
        } else if timer == nil {
            // Idle: the tick timer is not running, so throttle the readouts here.
            let now = CACurrentMediaTime()
            if now - lastIdleRefresh >= 0.2 {
                lastIdleRefresh = now
                refreshReadouts(force: true)
            }
        }
    }

    /// True once the resonator output is on the 1e15 Hz target.
    ///
    /// "On target" means the engine's own lock (`targetFrequencyLocked`, a +/-1% window)
    /// or a frequency inside that same window. Requiring >= 1.0e15 exactly never opens
    /// when the lock lands a fraction of a percent below the target.
    private var sequenceWanted: Bool {
        let target = FusionConstants.resonatorFrequencyHz
        let inWindow = input.frequencyHz >= target * 0.99
        return input.running && (input.targetLocked || inWindow)
    }

    // MARK: Timer

    private func startTimer() {
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Tick

    private func setPhase(_ newPhase: FusionChamberPhase) {
        phase = newPhase
        phaseTime = 0
        spawnTimer = 0
    }

    private func tick() {

        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0.0, now - lastTick))
        lastTick = now

        phaseTime += dt
        readoutTimer += dt

        // Grace period so a brief dip below 1e15 Hz does not reset the sequence
        let wanted = sequenceWanted
        lostTime = wanted ? 0.0 : lostTime + dt

        if phase != .dormant && lostTime >= 1.0 {
            shutdown()
        }

        // EM field follows the phase
        let fieldTarget = (phase == .dormant) ? 0.0 : emTargetTesla
        let fieldStep = emTargetTesla / emRampSeconds * dt

        if fieldTesla < fieldTarget {
            fieldTesla = min(fieldTarget, fieldTesla + fieldStep)
        } else if fieldTesla > fieldTarget {
            fieldTesla = max(fieldTarget, fieldTesla - fieldStep)
        }

        // Phase machine
        switch phase {

        case .dormant:
            if wanted {
                heliumCount = 0
                resonanceProgress = 0
                detuningPPM = abs(input.lockErrorFraction) * 1.0e6
                setPhase(.emRamp)
            }

        case .emRamp:
            if fieldTesla >= emTargetTesla - 0.01 {
                setPhase(.injection)
            }

        case .injection:
            spawnTimer += dt
            if spawnTimer >= injectInterval && protons.count < fuelTarget {
                spawnTimer = 0
                spawnProton()
            }
            if protons.count >= fuelTarget {
                setPhase(.resonance)
            }

        case .resonance:
            replenish(dt)
            driveDetuning(dt)
            resonanceProgress = min(1.0, resonanceProgress + dt / resonanceSeconds)

            // Stay in resonance until the UV has locked the lattice (or give up).
            if resonanceProgress >= 1.0 &&
                (prediction.coherence >= 0.88 || phaseTime >= resonanceTimeoutSeconds) {
                setPhase(.active)
            }

        case .active:
            replenish(dt)
            driveDetuning(dt)
        }

        // Prediction from the current model state
        let coupled = Int(Double(protons.count) * resonanceProgress)
        prediction = FusionPredictor.predict(
            detuningPPM: detuningPPM,
            magneticField: fieldTesla,
            coupledProtons: coupled
        )

        // Visual fusion events
        if phase == .active && prediction.predicted {
            let visualRate = min(prediction.eventsPerSecond, visualRateCap)
            if Double.random(in: 0..<1) < visualRate * dt {
                attemptFusion()
            }
        }

        moveProtons(dt)
        updateVisuals(now: now)
        refreshReadouts(force: false)

        // Stop the timer once everything has wound down
        if phase == .dormant && !wanted && fieldTesla <= 0.0 && protons.isEmpty {
            stopTimer()
            refreshReadouts(force: true)
        }
    }

    /// The UV resonance pulls the residual detuning toward zero.
    private func driveDetuning(_ dt: Double) {
        guard input.uvStrength > 0.05 else { return }
        detuningPPM *= pow(0.97, dt * 60.0 * input.uvStrength)
        if detuningPPM < 0.01 { detuningPPM = 0 }
    }

    private func shutdown() {
        setPhase(.dormant)
        resonanceProgress = 0
        detuningPPM = 0

        for p in protons {
            p.node.runAction(SCNAction.sequence([
                SCNAction.fadeOut(duration: 0.3),
                SCNAction.removeFromParentNode()
            ]))
        }
        protons.removeAll()
        usedSlots.removeAll()
    }

    // MARK: Hydrogen

    private func spawnProton() {
        guard let slot = (0..<fuelTarget).first(where: { !usedSlots.contains($0) }) else {
            return
        }
        usedSlots.insert(slot)

        let node = SCNNode(geometry: protonGeometry)
        node.position = SCNVector3(0, Self.chamberRadius, 0)   // injector, vessel-centre coordinates
        fuelNode.addChildNode(node)

        protons.append(FuelProton(
            node: node,
            slot: slot,
            wander: fcRandomInSphere(1.0)
        ))
    }

    private func replenish(_ dt: Double) {
        guard protons.count < fuelTarget else { return }
        spawnTimer += dt
        if spawnTimer >= replenishInterval {
            spawnTimer = 0
            spawnProton()
        }
    }

    private func moveProtons(_ dt: Double) {

        let coherence = Float(prediction.coherence)
        let order = Float(min(1.0, prediction.latticeOrder / 0.6))
        let blend = Float(resonanceProgress) * order
        let step = Float(dt)
        let pull = min(1.0, 4.0 * step)
        let jitter = step * (0.3 + 2.0 * (1.0 - blend)) * (1.3 - coherence)

        for p in protons where !p.consumed {

            if Float.random(in: 0..<1) < 0.8 * step {
                p.wander = fcRandomInSphere(1.0)
            }

            let site = Self.sites[p.slot]
            let target = fcMix(p.wander, site, blend)

            var pos = p.node.position
            pos = fcAdd(pos, fcScale(fcSub(target, pos), pull))
            pos.x += Float.random(in: -1...1) * jitter
            pos.y += Float.random(in: -1...1) * jitter
            pos.z += Float.random(in: -1...1) * jitter
            p.node.position = pos
        }
    }

    // MARK: Fusion event

    private func attemptFusion() {

        for group in 0..<(fuelTarget / FusionConstants.protonsPerFusion) {

            let members = protons.filter {
                !$0.consumed && $0.slot / FusionConstants.protonsPerFusion == group
            }

            guard members.count == FusionConstants.protonsPerFusion else { continue }

            for m in members {
                m.consumed = true
                usedSlots.remove(m.slot)
                m.node.runAction(SCNAction.sequence([
                    SCNAction.move(to: SCNVector3Zero, duration: 0.25),
                    SCNAction.removeFromParentNode()
                ]))
            }
            protons.removeAll { $0.consumed }
            heliumCount += 1

            spawnFusionEffects()
            return
        }
    }

    private func spawnFusionEffects() {

        // Flash at the core, delayed until the protons arrive
        let flash = SCNNode(geometry: SCNSphere(radius: 0.25))
        let flashMaterial = material(.white, emissive: true)
        flashMaterial.lightingModel = .constant
        flash.geometry?.firstMaterial = flashMaterial
        flash.opacity = 0.0
        fuelNode.addChildNode(flash)
        flash.runAction(SCNAction.sequence([
            SCNAction.wait(duration: 0.25),
            SCNAction.fadeIn(duration: 0.02),
            SCNAction.group([
                SCNAction.scale(to: 5.0, duration: 0.5),
                SCNAction.fadeOut(duration: 0.5)
            ]),
            SCNAction.removeFromParentNode()
        ]))

        // He-4 leaves the core toward the wall
        let helium = SCNNode(geometry: SCNSphere(radius: 0.16))
        helium.geometry?.firstMaterial = material(.yellow, emissive: true)
        helium.opacity = 0.0
        fuelNode.addChildNode(helium)

        // Random direction, ending just inside the vessel wall
        var direction = fcRandomInSphere(1.0)
        let length = (direction.x * direction.x +
                      direction.y * direction.y +
                      direction.z * direction.z).squareRoot()
        if length < 0.1 {
            direction = SCNVector3(0, 1, 0)
        } else {
            direction = fcScale(direction, 1.0 / length)
        }
        let wallPoint = fcScale(direction, Self.chamberRadius - 0.2)

        helium.runAction(SCNAction.sequence([
            SCNAction.wait(duration: 0.25),
            SCNAction.fadeIn(duration: 0.02),
            SCNAction.move(to: wallPoint, duration: 1.4),
            SCNAction.fadeOut(duration: 0.4),
            SCNAction.removeFromParentNode()
        ]))
    }

    // MARK: Visuals

    private func updateVisuals(now: CFTimeInterval) {

        // EM coils
        let fieldFraction = CGFloat(fieldTesla / emTargetTesla)
        for m in coilMaterials {
            m.emission.intensity = fieldFraction
        }

        // UV resonance ring
        let ringOpacity: CGFloat
        switch phase {
        case .resonance, .active:
            ringOpacity = CGFloat(resonanceProgress * prediction.coherence)
        default:
            ringOpacity = 0.0
        }
        resonanceRing.opacity = ringOpacity

        // Core, halo, light
        let coreIntensity: CGFloat
        let haloOpacity: CGFloat
        let lightIntensity: CGFloat

        switch phase {
        case .resonance:
            coreIntensity = CGFloat(0.15 + 0.35 * resonanceProgress)
            haloOpacity = 0.0
            lightIntensity = CGFloat(150.0 * resonanceProgress)
        case .active:
            if prediction.predicted {
                let pulse = 0.8 + 0.2 * sin(now * 6.0)
                coreIntensity = CGFloat(pulse)
                haloOpacity = 0.6
                lightIntensity = 900
            } else {
                coreIntensity = 0.25
                haloOpacity = 0.0
                lightIntensity = 150
            }
        default:
            coreIntensity = 0.0
            haloOpacity = 0.0
            lightIntensity = 0
        }

        coreNode.geometry?.firstMaterial?.emission.intensity = coreIntensity
        haloNode.opacity = haloOpacity
        coreLight.light?.intensity = lightIntensity

        // Vessel tint
        let tint: UIColor
        switch phase {
        case .dormant:    tint = .systemBlue
        case .emRamp:     tint = emColor
        case .injection:  tint = .systemTeal
        case .resonance:  tint = uvColor
        case .active:     tint = prediction.predicted ? fusionColor : .systemYellow
        }
        vesselNode.geometry?.firstMaterial?.diffuse.contents =
            tint.withAlphaComponent(phase == .dormant ? 0.10 : 0.14)
    }

    // MARK: Readouts

    private func refreshReadouts(force: Bool) {

        if !force && readoutTimer < 0.2 { return }
        readoutTimer = 0

        // Status
        let status: String
        let statusColor: UIColor

        switch phase {
        case .dormant:
            if !input.running {
                status = "STOPPED"
            } else if input.uvStrength <= 0.05 {
                status = "AWAITING UV"
            } else if !sequenceWanted {
                status = String(
                    format: "UV ON - %.2f%% OFF 1e15 Hz",
                    input.lockErrorFraction * 100.0
                )
            } else {
                status = "STARTING"
            }
            statusColor = .lightGray
        case .emRamp:
            status = "EM COILS ENERGIZING"
            statusColor = emColor
        case .injection:
            status = "HYDROGEN INJECTION"
            statusColor = .systemOrange
        case .resonance:
            status = String(format: "UV RESONANCE %.3e Hz", input.frequencyHz)
            statusColor = uvColor
        case .active:
            status = prediction.predicted ? "FUSION PREDICTED" : "FUSION NOT PREDICTED"
            statusColor = prediction.predicted ? .systemGreen : .systemYellow
        }

        if status != lastStatus {
            lastStatus = status
            setText(statusReadout, status, color: statusColor)
        }

        // Field / coherence / order
        let fieldLine: String
        if phase == .dormant && fieldTesla <= 0.0 {
            fieldLine = "B 0.0 T"
        } else {
            fieldLine = String(
                format: "B %.1f T  coh %.2f  order %.2f  det %.0f ppm",
                fieldTesla, prediction.coherence, prediction.latticeOrder, detuningPPM
            )
        }
        if fieldLine != lastField {
            lastField = fieldLine
            setText(fieldReadout, fieldLine, color: emColor)
        }

        // Fuel / products / shell
        let shellText = input.shellExcited ? "excited" : "not excited"
        let fuelLine = "H \(protons.count)  He-4 \(heliumCount)  shell \(shellText)"
        if fuelLine != lastFuel {
            lastFuel = fuelLine
            setText(fuelReadout, fuelLine, color: .systemOrange)
        }

        // Prediction
        let predictionLine: String
        let predictionColor: UIColor

        switch phase {
        case .resonance, .active:
            if prediction.predicted {
                predictionLine = String(
                    format: "p %.1f%%/evt  ~%.1f ev/s  %.1f MW  Q %.1f",
                    prediction.eventProbability * 100.0,
                    prediction.eventsPerSecond,
                    prediction.fusionPowerMW,
                    prediction.qFactor
                )
                predictionColor = .systemGreen
            } else {
                predictionLine = "no fusion: " + prediction.reason
                predictionColor = phase == .active ? .systemYellow : .lightGray
            }
        default:
            predictionLine = "--"
            predictionColor = .lightGray
        }
        if predictionLine != lastPrediction {
            lastPrediction = predictionLine
            setText(predictionReadout, predictionLine, color: predictionColor)
        }
    }
}







enum FusionConstants {
    /// QRTL conceptual drive frequency.
    static let resonatorFrequencyHz: Double = 1.0e15

    /// Effective fusion energy used by the supplied QRTL model.
    /// The model treats the complete H -> He-4 event as one effective event.
    static let effectiveFusionEnergyMeV: Double = 23.8

    static let mevToJoule: Double = 1.602_176_634e-13

    /// Four hydrogen nuclei are consumed for one modeled He-4 event.
    static let protonsPerFusion: Int = 4
}

// MARK: - QRTL Resonance Model

struct QRTLModel {

    /// Phase error from fractional detuning of the QRTL drive.
    static func phaseError(detuningPPM: Double) -> Double {
        min(2.0, abs(detuningPPM) * 0.065)
    }

    /// QRTL quark coherence.
    static func coherence(
        detuningPPM: Double,
        magneticField: Double
    ) -> Double {
        let error = phaseError(detuningPPM: detuningPPM)

        let gaussian =
            exp(
                -error * error /
                (2.0 * 0.85 * 0.85)
            )

        let vacuumCoupling =
            1.0 +
            0.35 *
            tanh((magneticField - 6.5) / 2.0)

        return min(
            1.0,
            max(0.0, gaussian * vacuumCoupling)
        )
    }

    /// QRTL lattice-order parameter.
    static func latticeOrder(
        coherence: Double,
        magneticField: Double
    ) -> Double {
        guard coherence > 0.62 else {
            return 0.0
        }

        let normalizedB =
            min(
                1.0,
                max(
                    0.0,
                    (magneticField - 4.0) / 8.0
                )
            )

        let t =
            min(
                1.0,
                max(
                    0.0,
                    (coherence - 0.62) / 0.38
                )
            )

        return min(
            1.0,
            pow(t, 3.5) *
            (1.0 + 0.4 * normalizedB)
        )
    }

    /// Probability that the QRTL proton population enters
    /// the synchronized lattice state.
    static func latticeProbability(
        coherence: Double
    ) -> Double {
        1.0 /
        (
            1.0 +
            exp(-15.0 * (coherence - 0.64))
        )
    }

    /// Conceptual fusion-gate probability.
    ///
    /// The four-proton reaction is only evaluated when the
    /// QRTL lattice is sufficiently coherent and ordered.
    static func fusionProbability(
        coherence: Double,
        latticeOrder: Double,
        latticeProbability: Double,
        yieldScale: Double
    ) -> Double {
        guard coherence > 0.85,
              latticeOrder > 0.60
        else {
            return 0.0
        }

        let nonlinearCoherence = pow(coherence, 4.0)
        let nonlinearOrder = pow(latticeOrder, 2.0)

        let probability =
            0.04 *
            nonlinearCoherence *
            nonlinearOrder *
            latticeProbability *
            yieldScale

        return min(1.0, max(0.0, probability))
    }
}

// MARK: - Species

enum Species: String {
    case proton
    case helium4

    var symbol: String {
        switch self {
        case .proton:
            return "p"
        case .helium4:
            return "⁴He"
        }
    }

    var color: UIColor {
        switch self {
        case .proton:
            return UIColor.orange
        case .helium4:
            return UIColor.yellow
        }
    }

    var radius: CGFloat {
        switch self {
        case .proton:
            return 0.22
        case .helium4:
            return 0.34
        }
    }
}

// MARK: - Fusion Event

struct FusionEvent {
    let protonsConsumed: Int
    let heliumProduced: Int
    let energyMeV: Double

    static let hydrogenToHelium4 = FusionEvent(
        protonsConsumed: FusionConstants.protonsPerFusion,
        heliumProduced: 1,
        energyMeV: FusionConstants.effectiveFusionEnergyMeV
    )
}

// MARK: - Particle

final class FusionParticle {
    let node: SCNNode
    var species: Species
    var coupled: Bool = false

    init(
        node: SCNNode,
        species: Species
    ) {
        self.node = node
        self.species = species
    }
}


enum QRConstants {

    static let targetFrequencyHz = 1.0e15

    static let speedOfLight = 299_792_458.0
    static let planck = 6.626_070_15e-34
    static let electronVolt = 1.602_176_634e-19

    // Electromagnetic field
    static let electromagneticFieldTesla = 5.0

    // Vacuum permeability
    static let vacuumPermeability =
        4.0 * Double.pi * 1.0e-7

    // Magnetic pressure:
    //
    // P = B² / (2 μ₀)
    //
    static let electromagneticPressurePa =
        electromagneticFieldTesla *
        electromagneticFieldTesla /
        (2.0 * vacuumPermeability)
}

// ============================================================
// MARK: - RESONATOR CONFIGURATION
// ============================================================

struct ResonatorConfiguration {
    var qrtlShellCompressionFraction: Double = 0.10
    var qrtlShellRadiusM: Double = 1.0e-12
    // --------------------------------------------------------
    // Mechanical resonator
    // --------------------------------------------------------

    var effectiveMassKg: Double = 1.0e-30

    var restoringConstant: Double = 39.4784176

    var damping: Double = 1.0e-18

    // --------------------------------------------------------
    // Electrical input
    // --------------------------------------------------------

    var inputVoltage: Double = 10.0

    var maximumCurrent: Double = 10.0

    var commandedCurrent: Double = 0.0

    // --------------------------------------------------------
    // Drive
    // --------------------------------------------------------

    var driveFrequencyHz: Double =
        QRConstants.targetFrequencyHz

    var driveAmplitude: Double = 1.0e-12

    var drivePhase: Double = 0.0

    // --------------------------------------------------------
    // Efficiency
    // --------------------------------------------------------

    var driverEfficiency: Double = 0.80

    var couplingEfficiency: Double = 0.50

    // --------------------------------------------------------
    // Frequency control
    // --------------------------------------------------------

    var frequencyToleranceFraction: Double = 0.01

    var phaseGain: Double = 0.10

    var powerGain: Double = 0.05

    var qrtlCoupling: Double = 0.10

    // --------------------------------------------------------
    // Hydrogen
    // --------------------------------------------------------

    var hydrogenAtoms: Double = 1.0e6

    var excitationProbability: Double = 0.10

    var hydrogenShellEnergyEV: Double = 10.2

    // --------------------------------------------------------
    // Frequency sweep
    // --------------------------------------------------------

    var sweepStartFrequencyHz: Double = 0.0

    var sweepEndFrequencyHz: Double = 2.0e15

    var sweepStepFrequencyHz: Double = 1.0e13

    // --------------------------------------------------------
    // Resonance
    // --------------------------------------------------------

    var resonanceThreshold: Double = 1.0

    // --------------------------------------------------------
    // Power feedback
    // --------------------------------------------------------

    var powerFeedbackEnabled: Bool = true

    // --------------------------------------------------------
    // BBO optical crystal
    // --------------------------------------------------------

    var bbo = BBOCrystalConfiguration()
}
// ============================================================
// MARK: - RESONATOR MODE
// ============================================================

struct ResonatorMode: Identifiable {

    let id = UUID()

    var frequencyHz: Double

    var amplitude: Double

    var energyJ: Double

    var phase: Double

    var label: String

    var order: Int

    var resonanceResponse: Double

    var isResonant: Bool

    var targetDistanceHz: Double
}

// ============================================================
// MARK: - PIPELINE STATUS
// ============================================================

enum PipelineStageStatus {
    
    case pending
    case active
    case done
    case skipped
    case complete
}

struct PipelineStageInfo: Identifiable {

    let id = UUID()

    var order: Int

    var name: String

    var detail: String

    var status: PipelineStageStatus
}

struct QuarkResonatorState {
    
    var electromagneticFieldTesla: Double = 0.0
    var electromagneticPressurePa: Double = 0.0
    var electromagneticShellEnergyJ: Double = 0.0

    // --------------------------------------------------------
    // Electrical
    // --------------------------------------------------------

    var inputVoltageV: Double = 10.0
    var inputCurrentA: Double = 0.0
    var inputPowerW: Double = 0.0
    var inputEnergyJ: Double = 0.0

    // --------------------------------------------------------
    // Mechanical resonator
    // --------------------------------------------------------

    var effectiveMassKg: Double = 1.0e-30
    var restoringConstant: Double = 39.4784176
    var damping: Double = 1.0e-18

    // --------------------------------------------------------
    // Frequency
    // --------------------------------------------------------

    var naturalFrequencyHz: Double = 0.0
    var outputFrequencyHz: Double = 0.0
    var targetFrequencyHz: Double =
        QRConstants.targetFrequencyHz
    var frequencyErrorHz: Double = 0.0
    var frequencyErrorPercent: Double = 0.0

    // --------------------------------------------------------
    // Motion
    // --------------------------------------------------------

    var displacement: Double = 0.0
    var velocity: Double = 0.0
    var acceleration: Double = 0.0

    // --------------------------------------------------------
    // Amplitude / phase
    // --------------------------------------------------------

    var amplitude: Double = 0.0
    var targetModeAmplitude: Double = 0.0
    var phase: Double = 0.0
    var phaseError: Double = 0.0

    // --------------------------------------------------------
    // Energy
    // --------------------------------------------------------

    var storedEnergyJ: Double = 0.0
    var targetModeEnergyJ: Double = 0.0
    var generatedModeEnergyJ: Double = 0.0
    var lossPowerW: Double = 0.0

    // --------------------------------------------------------
    // Resonance
    // --------------------------------------------------------

    var resonanceResponse: Double = 0.0
    var resonantModeFrequencyHz: Double = 0.0
    var resonantModeOrder: Int = 0

    // --------------------------------------------------------
    // Spectral analysis
    // --------------------------------------------------------

    var spectrumAnalyzed: Bool = false
    var resonantModeDetected: Bool = false
    var targetModeDetected: Bool = false

    // --------------------------------------------------------
    // Q
    // --------------------------------------------------------

    var bandwidthHz: Double = 0.0
    var qualityFactor: Double = 0.0
    var decayTimeS: Double = 0.0

    // --------------------------------------------------------
    // QRTL
    // --------------------------------------------------------

    var qrtlCoupling: Double = 0.10
    var qrtlEnergyJ: Double = 0.0

    // --------------------------------------------------------
    // Hydrogen calculation retained
    // --------------------------------------------------------

    var hydrogenGroundPopulation: Double = 1.0
    var hydrogenExcitedPopulation: Double = 0.0
    var hydrogenShellEnergyJ: Double = 0.0
    var hydrogenEnergyChangeJ: Double = 0.0
    var requiredHydrogenEnergyJ: Double = 0.0
    var requiredHydrogenPowerW: Double = 0.0

    // --------------------------------------------------------
    // Electrical requirement
    // --------------------------------------------------------

    var requiredInputPowerW: Double = 0.0
    var requiredInputCurrentA: Double = 0.0

    // --------------------------------------------------------
    // Power feedback
    // --------------------------------------------------------

    var powerDeficitW: Double = 0.0
    var powerFeedbackActive: Bool = false

    // --------------------------------------------------------
    // Frequency sweep
    // --------------------------------------------------------

    var frequencySearchActive: Bool = false
    var frequencySearchCompleted: Bool = false
    var sweepFrequencyHz: Double = 0.0
    var bestResponseFrequencyHz: Double = 0.0
    var bestResonanceResponse: Double = 0.0

    // --------------------------------------------------------
    // Phase
    // --------------------------------------------------------

    var phaseLocked: Bool = false

    // --------------------------------------------------------
    // Verification
    // --------------------------------------------------------

    var energyTargetReached: Bool = false

    // --------------------------------------------------------
    // QRTL resonance chain
    // --------------------------------------------------------

    var targetFrequencyLocked: Bool = false
    var frequencyLockErrorFraction: Double = 0.0
    var coherentCarrierActive: Bool = false
    var coherence: Double = 0.0
    var qrtlCoupledEnergyJ: Double = 0.0

    // --------------------------------------------------------
    // Helium-4 QRTL shell model
    // --------------------------------------------------------

    var helium4ShellEnergyJ: Double = 0.0
    var helium4ShellTargetEnergyJ: Double = 0.0
    var helium4ShellExcitationFraction: Double = 0.0
    var helium4ShellExcited: Bool = false
    var fusionTransitionReady: Bool = false

    // --------------------------------------------------------
    // BBO optical crystal
    // --------------------------------------------------------

    var bboResult = BBOConversionResult()

    // --------------------------------------------------------
    // Control
    // --------------------------------------------------------

    var qrtlEnabled: Bool = true
    var running: Bool = false
    var statusMessage: String = "READY"

    // --------------------------------------------------------
    // Pipeline
    // --------------------------------------------------------

    var pipelineStages: [PipelineStageInfo] = []
}
