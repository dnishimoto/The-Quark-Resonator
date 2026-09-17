//
//  ContentView.swift
//  The Quark Resonator
//
//  Updated:
//  - Electrical input-energy integration (fixed double-counting)
//  - Resonator-mode identification
//  - Incremental frequency sweep/search
//  - Automatic power increase when insufficient
//  - Live target-frequency key
//  - 3D SceneKit visualization
//  - Cleaner timer management
//

import SwiftUI
import SceneKit
import Combine
import UIKit

// MARK: - Constants

enum QRConstants {
    static let targetFrequencyHz = 1.0e15
    static let speedOfLight = 299_792_458.0
    static let planck = 6.626_070_15e-34
    static let electronVolt = 1.602_176_634e-19
}

// MARK: - Configuration

struct ResonatorConfiguration {

    // Physical resonator parameters
    var effectiveMassKg: Double = 1.0e-30

    // For m = 1e-30 kg and f = 1e15 Hz:
    // k = m * (2πf)^2 ≈ 39.4784176 N/m
    var restoringConstant: Double = 39.4784176

    var damping: Double = 1.0e-18

    // Electrical input
    var inputVoltage: Double = 10.0
    var maximumCurrent: Double = 10.0
    var commandedCurrent: Double = 0.0

    // Driver
    var driveFrequencyHz: Double = 1.0e15
    var driveAmplitude: Double = 1.0e-12
    var drivePhase: Double = 0.0

    // Efficiency
    var driverEfficiency: Double = 0.80
    var couplingEfficiency: Double = 0.50

    // Frequency control
    var frequencyToleranceFraction: Double = 0.01

    // Phase control
    var phaseGain: Double = 0.10

    // Power feedback
    var powerGain: Double = 0.05

    // QRTL
    var qrtlCoupling: Double = 0.10

    // Hydrogen
    var hydrogenAtoms: Double = 1.0e6
    var excitationProbability: Double = 0.10
    var hydrogenShellEnergyEV: Double = 10.2

    // Frequency sweep
    var sweepStartFrequencyHz: Double = 1.0e12
    var sweepEndFrequencyHz: Double = 2.0e15
    var sweepStepFrequencyHz: Double = 1.0e13

    // Resonance identification
    var resonanceThreshold: Double = 1.0

    // Power feedback
    var powerFeedbackEnabled: Bool = true
}

// MARK: - Resonator Mode

struct ResonatorMode: Identifiable {

    let id = UUID()

    var frequencyHz: Double
    var amplitude: Double
    var energyJ: Double
    var phase: Double

    var label: String
    var order: Int

    var resonanceResponse: Double = 0.0
    var isResonant: Bool = false
    var targetDistanceHz: Double = .infinity
}

// MARK: - Canonical Machine State

struct QuarkResonatorState {

    // Electrical input
    var inputVoltageV: Double = 10.0
    var inputCurrentA: Double = 0.0
    var inputPowerW: Double = 0.0
    var inputEnergyJ: Double = 0.0

    // Resonator
    var effectiveMassKg: Double = 1.0e-30
    var restoringConstant: Double = 39.4784176
    var damping: Double = 1.0e-18

    // Frequencies
    var naturalFrequencyHz: Double = 0.0
    var outputFrequencyHz: Double = 0.0
    var targetFrequencyHz: Double = QRConstants.targetFrequencyHz

    var frequencyErrorHz: Double = 0.0
    var frequencyErrorPercent: Double = 100.0

    // Motion
    var displacement: Double = 0.0
    var velocity: Double = 0.0
    var acceleration: Double = 0.0

    // Amplitude / phase
    var amplitude: Double = 0.0
    var targetModeAmplitude: Double = 0.0

    var phase: Double = 0.0
    var phaseError: Double = 0.0

    // Energy
    var storedEnergyJ: Double = 0.0
    var targetModeEnergyJ: Double = 0.0
    var generatedModeEnergyJ: Double = 0.0
    var lossPowerW: Double = 0.0

    // Resonance
    var resonanceResponse: Double = 0.0
    var resonantModeFrequencyHz: Double = 0.0
    var resonantModeOrder: Int = 0

    // Spectral state
    var spectrumAnalyzed: Bool = false
    var resonantModeDetected: Bool = false
    var targetModeDetected: Bool = false

    // Q
    var bandwidthHz: Double = 0.0
    var qualityFactor: Double = 0.0
    var decayTimeS: Double = 0.0

    // QRTL
    var qrtlCoupling: Double = 0.0
    var qrtlEnergyJ: Double = 0.0

    // Hydrogen
    var hydrogenGroundPopulation: Double = 1.0
    var hydrogenExcitedPopulation: Double = 0.0
    var hydrogenShellEnergyJ: Double = 0.0
    var hydrogenEnergyChangeJ: Double = 0.0

    var requiredHydrogenEnergyJ: Double = 0.0
    var requiredHydrogenPowerW: Double = 0.0

    // Electrical requirement
    var requiredInputPowerW: Double = 0.0
    var requiredInputCurrentA: Double = 0.0

    // Power feedback
    var powerDeficitW: Double = 0.0
    var powerFeedbackActive: Bool = false

    // Frequency search
    var frequencySearchActive: Bool = false
    var frequencySearchCompleted: Bool = false

    var sweepFrequencyHz: Double = 0.0
    var bestResponseFrequencyHz: Double = 0.0
    var bestResonanceResponse: Double = 0.0

    // Phase lock
    var phaseLocked: Bool = false

    // Verification
    var energyTargetReached: Bool = false

    // Controls
    var qrtlEnabled: Bool = false
    var running: Bool = false

    var statusMessage: String = "READY"
}

// MARK: - Engine

@MainActor
final class QuarkResonatorEngine: ObservableObject {

    @Published private(set) var state = QuarkResonatorState()
    @Published private(set) var modes: [ResonatorMode] = []

    var configuration = ResonatorConfiguration()
    var simulationTime: Double = 0.0

    // Incremental sweep state
    private var sweepFrequencyHz: Double = 0.0
    private var sweepBestFrequencyHz: Double = 0.0
    private var sweepBestResponse: Double = 0.0
    private var sweepHasStarted = false

    init() {
        updateConfiguration(configuration)
    }

    // MARK: Configuration

    func updateConfiguration(_ newConfiguration: ResonatorConfiguration) {
        configuration = newConfiguration

        state.effectiveMassKg = newConfiguration.effectiveMassKg
        state.restoringConstant = newConfiguration.restoringConstant
        state.damping = newConfiguration.damping
        state.targetFrequencyHz = QRConstants.targetFrequencyHz
        state.qrtlCoupling = newConfiguration.qrtlCoupling
        state.inputVoltageV = newConfiguration.inputVoltage

        calculateNaturalFrequency()
        calculateHydrogenTarget()
        calculateElectricalPower()
    }

    // MARK: Natural Frequency

    func calculateNaturalFrequency() {
        let mass = max(configuration.effectiveMassKg, 1.0e-60)
        let stiffness = max(configuration.restoringConstant, 0.0)

        state.naturalFrequencyHz = sqrt(stiffness / mass) / (2.0 * Double.pi)

        if state.naturalFrequencyHz.isFinite {
            state.outputFrequencyHz = state.naturalFrequencyHz
        } else {
            state.outputFrequencyHz = 0.0
        }

        updateFrequencyError()
    }

    // MARK: Frequency Error

    private func updateFrequencyError() {
        state.frequencyErrorHz = state.outputFrequencyHz - state.targetFrequencyHz
        state.frequencyErrorPercent =
            abs(state.frequencyErrorHz) / max(state.targetFrequencyHz, 1.0) * 100.0

        state.targetModeDetected =
            state.frequencyErrorPercent <= configuration.frequencyToleranceFraction * 100.0
    }

    // MARK: Electrical Power

    func calculateElectricalPower() {
        let current = min(
            configuration.maximumCurrent,
            max(0.0, configuration.commandedCurrent)
        )

        state.inputCurrentA = current
        state.inputPowerW = state.inputVoltageV * state.inputCurrentA
    }

    // MARK: Electrical Input Energy (single integration point)

    func integrateInputEnergy(deltaTime: Double) {
        guard deltaTime > 0 else { return }

        let power = max(0.0, state.inputPowerW)
        state.inputEnergyJ += power * deltaTime

        if !state.inputEnergyJ.isFinite {
            state.inputEnergyJ = 0.0
        }
    }

    // MARK: Hydrogen Target

    func calculateHydrogenTarget() {
        let energyPerAtom =
            configuration.hydrogenShellEnergyEV * QRConstants.electronVolt

        state.requiredHydrogenEnergyJ =
            configuration.hydrogenAtoms *
            configuration.excitationProbability *
            energyPerAtom
    }

    // MARK: Resonance Response

    func calculateResonanceResponse(frequencyHz: Double) -> Double {
        let f0 = max(state.naturalFrequencyHz, 1.0)
        let frequency = max(frequencyHz, 1.0)
        let mass = max(state.effectiveMassKg, 1.0e-60)
        let stiffness = max(state.restoringConstant, 1.0e-60)
        let damping = max(state.damping, 0.0)

        let dampingRatio =
            damping / max(2.0 * sqrt(stiffness * mass), 1.0e-60)

        let frequencyRatio = frequency / f0

        let denominator = sqrt(
            pow(1.0 - frequencyRatio * frequencyRatio, 2.0) +
            pow(2.0 * dampingRatio * frequencyRatio, 2.0)
        )

        let response = denominator > 0.0 ? 1.0 / denominator : 0.0
        return response.isFinite ? response : 0.0
    }

    // MARK: Incremental Frequency Sweep

    func startFrequencySweep() {
        sweepFrequencyHz = max(configuration.sweepStartFrequencyHz, 1.0)
        sweepBestFrequencyHz = sweepFrequencyHz
        sweepBestResponse = 0.0
        sweepHasStarted = true

        state.frequencySearchActive = true
        state.frequencySearchCompleted = false
        state.sweepFrequencyHz = sweepFrequencyHz
        state.bestResponseFrequencyHz = sweepBestFrequencyHz
        state.bestResonanceResponse = sweepBestResponse
        state.statusMessage = "SEARCHING FREQUENCY"
    }

    func advanceFrequencySweep() {
        guard sweepHasStarted else {
            startFrequencySweep()
            return
        }

        let response = calculateResonanceResponse(frequencyHz: sweepFrequencyHz)

        if response > sweepBestResponse {
            sweepBestResponse = response
            sweepBestFrequencyHz = sweepFrequencyHz
        }

        state.sweepFrequencyHz = sweepFrequencyHz
        state.bestResponseFrequencyHz = sweepBestFrequencyHz
        state.bestResonanceResponse = sweepBestResponse

        sweepFrequencyHz += max(configuration.sweepStepFrequencyHz, 1.0)

        if sweepFrequencyHz > configuration.sweepEndFrequencyHz {
            finishFrequencySweep()
        }
    }

    private func finishFrequencySweep() {
        sweepHasStarted = false
        state.frequencySearchActive = false
        state.frequencySearchCompleted = true

        state.bestResponseFrequencyHz = sweepBestFrequencyHz
        state.bestResonanceResponse = sweepBestResponse
        state.outputFrequencyHz = sweepBestFrequencyHz

        updateFrequencyError()
        identifyResonatorModes()

        if state.targetModeDetected {
            state.statusMessage = "TARGET FREQUENCY FOUND"
        } else {
            state.statusMessage = "RESONANT MODE IDENTIFIED"
        }
    }

    // MARK: Resonator Mode Identification

    func identifyResonatorModes() {
        modes.removeAll()

        let fundamental = max(state.naturalFrequencyHz, 1.0)
        let baseAmplitude = max(configuration.driveAmplitude, 1.0e-18)

        // Fundamental
        let fundamentalResponse = calculateResonanceResponse(frequencyHz: fundamental)
        let fundamentalEnergy = calculateModeEnergy(amplitude: baseAmplitude)

        modes.append(
            ResonatorMode(
                frequencyHz: fundamental,
                amplitude: baseAmplitude,
                energyJ: fundamentalEnergy,
                phase: state.phase,
                label: "Fundamental",
                order: 1,
                resonanceResponse: fundamentalResponse,
                isResonant: fundamentalResponse >= configuration.resonanceThreshold,
                targetDistanceHz: abs(fundamental - state.targetFrequencyHz)
            )
        )

        // Harmonic / nonlinear candidate modes
        for order in 2...12 {
            let frequency = fundamental * Double(order)
            let nonlinearFactor = pow(max(configuration.qrtlCoupling, 0.000001), Double(order - 1))
            let amplitude = baseAmplitude * nonlinearFactor
            let energy = calculateModeEnergy(amplitude: amplitude)
            let response = calculateResonanceResponse(frequencyHz: frequency)

            modes.append(
                ResonatorMode(
                    frequencyHz: frequency,
                    amplitude: amplitude,
                    energyJ: energy,
                    phase: state.phase,
                    label: "Harmonic \(order)",
                    order: order,
                    resonanceResponse: response,
                    isResonant: response >= configuration.resonanceThreshold,
                    targetDistanceHz: abs(frequency - state.targetFrequencyHz)
                )
            )
        }

        state.spectrumAnalyzed = true
        selectIdentifiedResonantMode()
    }

    // MARK: Select Resonant Mode

    private func selectIdentifiedResonantMode() {
        guard !modes.isEmpty else {
            state.resonantModeDetected = false
            return
        }

        let resonantModes = modes.filter { $0.isResonant }

        let selected: ResonatorMode?

        if !resonantModes.isEmpty {
            selected = resonantModes.max { $0.resonanceResponse < $1.resonanceResponse }
        } else {
            selected = modes.max { $0.resonanceResponse < $1.resonanceResponse }
        }

        guard let mode = selected else { return }

        state.resonanceResponse = mode.resonanceResponse
        state.resonantModeFrequencyHz = mode.frequencyHz
        state.resonantModeOrder = mode.order
        state.targetModeAmplitude = mode.amplitude
        state.targetModeEnergyJ = mode.energyJ
        state.generatedModeEnergyJ = mode.energyJ
        state.outputFrequencyHz = mode.frequencyHz
        state.resonantModeDetected = mode.isResonant

        updateFrequencyError()

        if state.targetModeDetected {
            state.statusMessage = "TARGET MODE DETECTED"
        } else if state.resonantModeDetected {
            state.statusMessage = "RESONANT MODE DETECTED"
        }
    }

    // MARK: Mode Energy

    private func calculateModeEnergy(amplitude: Double) -> Double {
        let k = max(state.restoringConstant, 0.0)
        return 0.5 * k * amplitude * amplitude
    }

    // MARK: Stored Energy

    func calculateStoredEnergy() {
        let kinetic = 0.5 * state.effectiveMassKg * state.velocity * state.velocity
        let potential = 0.5 * state.restoringConstant * state.displacement * state.displacement

        state.storedEnergyJ = max(0.0, kinetic + potential)
        state.qrtlEnergyJ = state.targetModeEnergyJ * configuration.qrtlCoupling
    }

    // MARK: Loss

    func calculateLoss() {
        let omega = 2.0 * Double.pi * max(state.outputFrequencyHz, 1.0)
        let damping = max(state.damping, 0.0)

        state.lossPowerW = damping * state.velocity * state.velocity
        if !state.lossPowerW.isFinite {
            state.lossPowerW = 0.0
        }

        if damping > 0.0 {
            state.decayTimeS = 2.0 * state.effectiveMassKg / damping
            state.qualityFactor = state.effectiveMassKg * omega / damping
        } else {
            state.decayTimeS = .infinity
            state.qualityFactor = .infinity
        }

        if state.qualityFactor.isFinite && state.qualityFactor > 0.0 {
            state.bandwidthHz = state.outputFrequencyHz / state.qualityFactor
        } else {
            state.bandwidthHz = 0.0
        }
    }

    // MARK: Required Power

    func calculateRequiredPower() {
        let timeS = 1.0
        state.requiredHydrogenPowerW = state.requiredHydrogenEnergyJ / timeS

        let efficiency = max(0.000001, configuration.driverEfficiency * configuration.couplingEfficiency)
        state.requiredInputPowerW = state.requiredHydrogenPowerW / efficiency
        state.requiredInputPowerW += max(0.0, state.lossPowerW)

        state.requiredInputCurrentA =
            state.requiredInputPowerW / max(state.inputVoltageV, 0.000001)

        state.powerDeficitW = max(0.0, state.requiredInputPowerW - state.inputPowerW)
        state.energyTargetReached = state.hydrogenEnergyChangeJ >= state.requiredHydrogenEnergyJ
    }

    // MARK: Automatic Power Increase

    func increasePowerIfInsufficient(deltaTime: Double) {
        guard configuration.powerFeedbackEnabled else {
            state.powerFeedbackActive = false
            return
        }

        let requiredPower = max(0.0, state.requiredInputPowerW)
        let availablePower = max(0.0, state.inputPowerW)
        let deficit = max(0.0, requiredPower - availablePower)

        state.powerDeficitW = deficit

        guard deficit > 0.0, deltaTime > 0.0 else {
            state.powerFeedbackActive = false
            return
        }

        let voltage = max(state.inputVoltageV, 1.0e-12)
        let currentCorrection = (deficit / voltage) * configuration.powerGain * deltaTime
        let newCurrent = configuration.commandedCurrent + currentCorrection

        configuration.commandedCurrent = min(
            configuration.maximumCurrent,
            max(0.0, newCurrent)
        )

        state.powerFeedbackActive = true
        calculateElectricalPower()

        if configuration.commandedCurrent >= configuration.maximumCurrent &&
            state.inputPowerW < requiredPower {
            state.statusMessage = "POWER LIMIT REACHED"
        } else {
            state.statusMessage = "INCREASING INPUT POWER"
        }
    }

    // MARK: Resonator Simulation

    func step(deltaTime: Double) {
        guard deltaTime > 0.0, state.running else { return }

        simulationTime += deltaTime

        // Electrical system
        calculateElectricalPower()
        integrateInputEnergy(deltaTime: deltaTime)          // ← single integration

        // Frequency search
        if state.frequencySearchActive {
            advanceFrequencySweep()
        }

        // Driven resonator once search is complete
        if state.frequencySearchCompleted {
            let frequency = max(state.outputFrequencyHz, 1.0)
            let omega = 2.0 * Double.pi * frequency

            let driveForce =
                configuration.driveAmplitude *
                cos(omega * simulationTime + configuration.drivePhase)

            let restoringForce = state.restoringConstant * state.displacement
            let dampingForce = state.damping * state.velocity

            let acceleration =
                (driveForce - restoringForce - dampingForce) /
                max(state.effectiveMassKg, 1.0e-60)

            state.acceleration = acceleration
            state.velocity += acceleration * deltaTime
            state.displacement += state.velocity * deltaTime
            state.amplitude = abs(state.displacement)
            state.phase = atan2(state.velocity, omega * state.displacement + 1.0e-30)
        }

        calculateStoredEnergy()
        calculateLoss()
        identifyResonatorModes()
        calculateHydrogenResponse()
        calculateRequiredPower()
        increasePowerIfInsufficient(deltaTime: deltaTime)
        calculateElectricalPower()
        // Note: energy is NOT integrated a second time
    }

    // MARK: Phase Lock

    func phaseLock() {
        let error = -state.phase
        let correction = configuration.phaseGain * error

        configuration.drivePhase += correction
        state.phaseError = error
        state.phaseLocked = abs(error) < 0.05

        state.statusMessage = state.phaseLocked ? "PHASE LOCKED" : "PHASE CORRECTION"
    }

    // MARK: Hydrogen

    func calculateHydrogenResponse() {
        guard state.qrtlEnabled else {
            state.hydrogenGroundPopulation = 1.0
            state.hydrogenExcitedPopulation = 0.0
            state.hydrogenShellEnergyJ = 0.0
            state.hydrogenEnergyChangeJ = 0.0
            return
        }

        guard state.targetModeDetected else {
            state.hydrogenGroundPopulation = 1.0
            state.hydrogenExcitedPopulation = 0.0
            state.hydrogenShellEnergyJ = 0.0
            state.hydrogenEnergyChangeJ = 0.0
            return
        }

        let availableEnergy = state.qrtlEnergyJ * configuration.couplingEfficiency
        let excitationFraction = min(
            1.0,
            availableEnergy / max(state.requiredHydrogenEnergyJ, 1.0e-30)
        )

        state.hydrogenExcitedPopulation = excitationFraction
        state.hydrogenGroundPopulation = 1.0 - excitationFraction
        state.hydrogenEnergyChangeJ = state.requiredHydrogenEnergyJ * excitationFraction
        state.hydrogenShellEnergyJ = state.hydrogenEnergyChangeJ
    }

    // MARK: Start / Stop / Reset

    func start() {
        simulationTime = 0.0
        state.running = true

        configuration.commandedCurrent = min(
            configuration.maximumCurrent,
            max(configuration.commandedCurrent, 0.01)
        )

        startFrequencySweep()
        state.statusMessage = "STARTING FREQUENCY SEARCH"
    }

    func stop() {
        state.running = false
        state.statusMessage = "STOPPED"
    }

    func reset() {
        simulationTime = 0.0
        configuration.commandedCurrent = 0.0

        state = QuarkResonatorState()
        state.targetFrequencyHz = QRConstants.targetFrequencyHz
        state.effectiveMassKg = configuration.effectiveMassKg
        state.restoringConstant = configuration.restoringConstant
        state.damping = configuration.damping
        state.inputVoltageV = configuration.inputVoltage
        state.qrtlCoupling = configuration.qrtlCoupling

        modes.removeAll()
        sweepFrequencyHz = 0.0
        sweepBestFrequencyHz = 0.0
        sweepBestResponse = 0.0
        sweepHasStarted = false

        calculateNaturalFrequency()
        calculateHydrogenTarget()
        calculateElectricalPower()

        state.statusMessage = "READY"
    }

    // MARK: QRTL

    func setQRTLEnabled(_ enabled: Bool) {
        state.qrtlEnabled = enabled
        state.statusMessage = enabled ? "QRTL ENABLED" : "QRTL DISABLED"
    }
}

// MARK: - Scene Controller

@MainActor
final class QuarkResonatorSceneController: ObservableObject {

    let scene = SCNScene()

    private(set) var resonatorNode = SCNNode()
    private(set) var fieldNode = SCNNode()
    private(set) var hydrogenNode = SCNNode()
    private(set) var energyNode = SCNNode()

    private var hydrogenRotationAction = false

    init() {
        scene.background.contents = UIColor.black
        buildScene()
    }

    private func buildScene() {
        buildCamera()
        buildLights()
        buildResonator()
        buildHydrogen()
        buildEnergyField()
        buildAxes()
    }

    private func buildCamera() {
        let cameraNode = SCNNode()
        cameraNode.name = "MainCamera"
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 55.0
        cameraNode.position = SCNVector3(0, 3, 12)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
    }

    private func buildLights() {
        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .omni
        keyLight.light?.intensity = 1000
        keyLight.position = SCNVector3(4, 6, 8)
        scene.rootNode.addChildNode(keyLight)

        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .ambient
        fillLight.light?.intensity = 300
        scene.rootNode.addChildNode(fillLight)
    }

    private func buildResonator() {
        let outer = SCNTorus(ringRadius: 2.4, pipeRadius: 0.12)
        outer.firstMaterial = SCNMaterial()
        outer.firstMaterial?.diffuse.contents = UIColor.cyan
        outer.firstMaterial?.emission.contents = UIColor.cyan

        resonatorNode = SCNNode(geometry: outer)
        resonatorNode.name = "Resonator"
        scene.rootNode.addChildNode(resonatorNode)

        let inner = SCNTorus(ringRadius: 1.65, pipeRadius: 0.07)
        inner.firstMaterial = SCNMaterial()
        inner.firstMaterial?.diffuse.contents = UIColor.systemBlue
        inner.firstMaterial?.emission.contents = UIColor.systemBlue

        let innerNode = SCNNode(geometry: inner)
        resonatorNode.addChildNode(innerNode)
    }

    private func buildHydrogen() {
        hydrogenNode = SCNNode()
        hydrogenNode.name = "Hydrogen"

        let nucleus = SCNSphere(radius: 0.35)
        nucleus.firstMaterial = SCNMaterial()
        nucleus.firstMaterial?.diffuse.contents = UIColor.red
        nucleus.firstMaterial?.emission.contents = UIColor.red

        let nucleusNode = SCNNode(geometry: nucleus)
        hydrogenNode.addChildNode(nucleusNode)

        for radius in [CGFloat(0.75), CGFloat(1.15), CGFloat(1.55)] {
            let shell = SCNTorus(ringRadius: radius, pipeRadius: 0.025)
            shell.firstMaterial = SCNMaterial()
            shell.firstMaterial?.diffuse.contents = UIColor.yellow
            shell.firstMaterial?.emission.contents = UIColor.yellow

            let shellNode = SCNNode(geometry: shell)
            hydrogenNode.addChildNode(shellNode)
        }

        hydrogenNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(hydrogenNode)
    }

    private func buildEnergyField() {
        let sphere = SCNSphere(radius: 1.9)
        sphere.firstMaterial = SCNMaterial()
        sphere.firstMaterial?.diffuse.contents = UIColor.orange
        sphere.firstMaterial?.emission.contents = UIColor.orange
        sphere.firstMaterial?.transparency = 0.12

        fieldNode = SCNNode(geometry: sphere)
        fieldNode.name = "EnergyField"
        scene.rootNode.addChildNode(fieldNode)
    }

    private func buildAxes() {
        let x = SCNNode(geometry: SCNCylinder(radius: 0.015, height: 8))
        x.eulerAngles.z = Float.pi / 2
        x.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(x)
    }

    func update(state: QuarkResonatorState) {
        let normalizedAmplitude = min(1.0, max(0.0, state.targetModeAmplitude / 1.0e-9))
        let scale = Float(1.0 + normalizedAmplitude * 0.35)
        resonatorNode.scale = SCNVector3(scale, scale, scale)

        let energyScale = Float(
            min(1.0, max(0.0, log10(1.0 + state.qrtlEnergyJ * 1.0e30) / 10.0))
        )
        let fieldScale = Float(0.65 + energyScale)
        fieldNode.scale = SCNVector3(fieldScale, fieldScale, fieldScale)
        fieldNode.opacity = CGFloat(0.10 + 0.45 * energyScale)

        let shellScale = Float(1.0 + state.hydrogenExcitedPopulation * 0.5)
        hydrogenNode.scale = SCNVector3(shellScale, shellScale, shellScale)

        if state.running && !hydrogenRotationAction {
            hydrogenRotationAction = true
            let rotation = SCNAction.rotateBy(x: 0, y: CGFloat(Double.pi * 2.0), z: 0, duration: 1.0)
            hydrogenNode.runAction(SCNAction.repeatForever(rotation))
        }

        if !state.running && hydrogenRotationAction {
            hydrogenNode.removeAllActions()
            hydrogenRotationAction = false
        }
    }
}

// MARK: - Scene View

struct QuarkResonatorSceneView: UIViewRepresentable {

    let controller: QuarkResonatorSceneController

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = controller.scene
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = .black

        if let camera = controller.scene.rootNode.childNode(withName: "MainCamera", recursively: true) {
            view.pointOfView = camera
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

// MARK: - Content View

struct ContentView: View {

    @StateObject private var engine = QuarkResonatorEngine()
    @StateObject private var sceneController = QuarkResonatorSceneController()

    @State private var timer: Timer?

    private var estimatedShellEnergyEV: Double {
        abs(engine.state.hydrogenEnergyChangeJ) / QRConstants.electronVolt
    }

    // MARK: - Live Activity Helper

    private var liveActivity: (title: String, detail: String, color: Color, progress: Double?) {
        let s = engine.state

        if !s.running {
            return ("IDLE", "Press START to begin frequency search", .gray, nil)
        }

        if s.frequencySearchActive {
            let totalRange = max(
                engine.configuration.sweepEndFrequencyHz - engine.configuration.sweepStartFrequencyHz,
                1.0
            )
            let current = max(0, s.sweepFrequencyHz - engine.configuration.sweepStartFrequencyHz)
            let progress = min(1.0, current / totalRange)

            return (
                "SEARCHING FREQUENCY",
                "Sweeping… looking for strongest resonance",
                .orange,
                progress
            )
        }

        if s.frequencySearchCompleted && !s.targetModeDetected {
            return (
                "RESONANT MODE FOUND",
                "Best mode identified – driving resonator",
                .yellow,
                1.0
            )
        }

        if s.targetModeDetected {
            if s.powerFeedbackActive {
                return (
                    "INCREASING POWER",
                    "Raising current to meet energy demand",
                    .cyan,
                    nil
                )
            }
            if s.phaseLocked {
                return (
                    "PHASE LOCKED + TARGET MODE",
                    "Resonator locked on target frequency",
                    .green,
                    nil
                )
            }
            return (
                "TARGET MODE ACTIVE",
                "Driving at target frequency",
                .green,
                nil
            )
        }

        return (
            "RUNNING",
            s.statusMessage,
            .blue,
            nil
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                frequencyKey

                QuarkResonatorSceneView(controller: sceneController)
                    .frame(minHeight: 320)

                ScrollView {
                    VStack(spacing: 12) {
                        liveActivityPanel          // ← NEW
                        frequencyPanel
                        electricalPanel
                        resonancePanel
                        energyPanel
                        hydrogenPanel
                        sweepPanel
                        controlPanel
                    }
                    .padding()
                }
            }
        }
        .onAppear {
            sceneController.update(state: engine.state)
        }
        .onDisappear {
            stopTimer()
            engine.stop()
        }
    }

    // MARK: - Live Activity Panel (NEW)

    private var liveActivityPanel: some View {
        let activity = liveActivity

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(activity.color)
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle()
                            .stroke(activity.color.opacity(0.4), lineWidth: 4)
                            .scaleEffect(engine.state.running ? 1.6 : 1.0)
                            .opacity(engine.state.running ? 0 : 1)
                            .animation(
                                engine.state.running
                                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                                    : .default,
                                value: engine.state.running
                            )
                    )

                Text(activity.title)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(activity.color)

                Spacer()

                if engine.state.running {
                    Text("LIVE")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(activity.color)
                        .clipShape(Capsule())
                }
            }

            Text(activity.detail)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))

            if let progress = activity.progress {
                ProgressView(value: progress)
                    .tint(activity.color)
                    .scaleEffect(x: 1, y: 1.6, anchor: .center)

                Text(String(format: "Sweep Progress  %.1f%%", progress * 100))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.gray)
            }

            // Quick live numbers while searching
            if engine.state.frequencySearchActive {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current")
                            .font(.caption2)
                            .foregroundColor(.gray)
                        Text(formatFrequency(engine.state.sweepFrequencyHz))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.cyan)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Best so far")
                            .font(.caption2)
                            .foregroundColor(.gray)
                        Text(formatFrequency(engine.state.bestResponseFrequencyHz))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.green)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(activity.color.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Frequency Key (slightly improved)

    private var frequencyKey: some View {
        VStack(spacing: 4) {
            Text("QUARK RESONATOR")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            let fusion = hydrogenFusionStatus

            HStack(spacing: 8) {
                Circle()
                    .fill(fusion.color)
                    .frame(width: 10, height: 10)

                Text(fusion.title)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(fusion.color)
            }

            Text(String(format: "Shell Energy: %.3e eV", estimatedShellEnergyEV))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white)

            Text(fusion.detail)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Divider().background(Color.white.opacity(0.2))

            Text("TARGET  \(formatFrequency(QRConstants.targetFrequencyHz))")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)

            Text("ACTUAL  \(formatFrequency(engine.state.outputFrequencyHz))")
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundColor(.white)

            Text(engine.state.statusMessage)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(engine.state.targetModeDetected ? .green : .orange)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.85))
    }

    // MARK: - Fusion Status (unchanged logic)

    private var hydrogenFusionStatus: (title: String, color: Color, detail: String) {
        let energyEV = estimatedShellEnergyEV
        let coupling = engine.state.qrtlCoupling
        let isFrequencyLocked =
            abs(engine.state.frequencyErrorHz) <=
            max(QRConstants.targetFrequencyHz * 1.0e-6, 1.0)

        let fusionRelevantEnergyEV = 10_000.0

        if !energyEV.isFinite || !coupling.isFinite {
            return ("FUSION STATUS: INVALID INPUT", .red, "Energy or coupling is not finite.")
        }

        if energyEV >= fusionRelevantEnergyEV && coupling >= 0.90 && isFrequencyLocked {
            return ("FUSION STATUS: CONDITIONS MET", .green,
                    "Model energy, coupling, and frequency-lock criteria are met.")
        }

        if energyEV >= fusionRelevantEnergyEV {
            return ("FUSION STATUS: ENERGY REGIME ONLY", .yellow,
                    "Energy criterion is met; coupling or frequency lock is insufficient.")
        }

        return ("FUSION STATUS: NOT PLAUSIBLE", .orange,
                "Shell-energy change is below the model fusion-energy threshold.")
    }

    // MARK: - All other panels (unchanged)

    private var frequencyPanel: some View {
        panel(title: "FREQUENCY") {
            valueRow("Natural Frequency", formatFrequency(engine.state.naturalFrequencyHz))
            valueRow("Output Frequency", formatFrequency(engine.state.outputFrequencyHz))
            valueRow("Target Frequency", formatFrequency(engine.state.targetFrequencyHz))
            valueRow("Error", String(format: "%.6f%%", engine.state.frequencyErrorPercent))
            valueRow("Target Detected", engine.state.targetModeDetected ? "TRUE" : "FALSE")
        }
    }

    private var electricalPanel: some View {
        panel(title: "ELECTRICAL INPUT") {
            valueRow("Voltage", String(format: "%.4f V", engine.state.inputVoltageV))
            valueRow("Current", String(format: "%.6f A", engine.state.inputCurrentA))
            valueRow("Input Power", formatPower(engine.state.inputPowerW))
            valueRow("Input Energy", formatEnergy(engine.state.inputEnergyJ))
            valueRow("Required Power", formatPower(engine.state.requiredInputPowerW))
            valueRow("Power Deficit", formatPower(engine.state.powerDeficitW))
            valueRow("Feedback", engine.state.powerFeedbackActive ? "INCREASING" : "HOLD")
        }
    }

    private var resonancePanel: some View {
        panel(title: "RESONATOR MODE") {
            valueRow("Mode",
                     engine.state.resonantModeDetected ? "\(engine.state.resonantModeOrder)" : "NONE")
            valueRow("Mode Frequency", formatFrequency(engine.state.resonantModeFrequencyHz))
            valueRow("Resonance Response", String(format: "%.6f", engine.state.resonanceResponse))
            valueRow("Mode Amplitude", formatScientific(engine.state.targetModeAmplitude))
            valueRow("Q", formatScientific(engine.state.qualityFactor))
            valueRow("Bandwidth", formatFrequency(engine.state.bandwidthHz))
            valueRow("Decay Time", formatScientific(engine.state.decayTimeS))
        }
    }

    private var energyPanel: some View {
        panel(title: "ENERGY") {
            valueRow("Stored Energy", formatEnergy(engine.state.storedEnergyJ))
            valueRow("Target Mode Energy", formatEnergy(engine.state.targetModeEnergyJ))
            valueRow("Generated Mode Energy", formatEnergy(engine.state.generatedModeEnergyJ))
            valueRow("QRTL Energy", formatEnergy(engine.state.qrtlEnergyJ))
            valueRow("Loss Power", formatPower(engine.state.lossPowerW))
            valueRow("Input Energy", formatEnergy(engine.state.inputEnergyJ))
        }
    }

    private var hydrogenPanel: some View {
        panel(title: "HYDROGEN") {
            Toggle("QRTL Enabled", isOn: Binding(
                get: { engine.state.qrtlEnabled },
                set: { engine.setQRTLEnabled($0) }
            ))
            .foregroundStyle(.white)

            valueRow("Ground Population", String(format: "%.6f", engine.state.hydrogenGroundPopulation))
            valueRow("Excited Population", String(format: "%.6f", engine.state.hydrogenExcitedPopulation))
            valueRow("Shell Energy", formatEnergy(engine.state.hydrogenShellEnergyJ))
            valueRow("Energy Change", formatEnergy(engine.state.hydrogenEnergyChangeJ))
        }
    }

    private var sweepPanel: some View {
        panel(title: "FREQUENCY SEARCH") {
            valueRow("Search Active", engine.state.frequencySearchActive ? "TRUE" : "FALSE")
            valueRow("Search Complete", engine.state.frequencySearchCompleted ? "TRUE" : "FALSE")
            valueRow("Sweep Frequency", formatFrequency(engine.state.sweepFrequencyHz))
            valueRow("Best Frequency", formatFrequency(engine.state.bestResponseFrequencyHz))
            valueRow("Best Response", String(format: "%.6f", engine.state.bestResonanceResponse))
            valueRow("Spectrum Analyzed", engine.state.spectrumAnalyzed ? "TRUE" : "FALSE")
        }
    }

    private var controlPanel: some View {
        panel(title: "CONTROL") {
            HStack(spacing: 10) {
                Button("START") {
                    engine.start()
                    startTimer()
                }
                .buttonStyle(.borderedProminent)

                Button("STOP") {
                    engine.stop()
                    stopTimer()
                }
                .buttonStyle(.bordered)

                Button("PHASE LOCK") {
                    engine.phaseLock()
                }
                .buttonStyle(.bordered)

                Button("RESET") {
                    engine.reset()
                    stopTimer()
                    sceneController.update(state: engine.state)
                }
                .buttonStyle(.bordered)
            }

            valueRow("Phase Error", String(format: "%.6f rad", engine.state.phaseError))
            valueRow("Phase Locked", engine.state.phaseLocked ? "TRUE" : "FALSE")
            valueRow("Energy Target",
                     engine.state.energyTargetReached ? "REACHED" : "NOT REACHED")
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            Task { @MainActor in
                engine.step(deltaTime: 0.016)
                sceneController.update(state: engine.state)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Helpers

    private func panel<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.cyan)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white)
        }
    }

    private func formatFrequency(_ value: Double) -> String {
        guard value.isFinite else { return "∞" }
        return String(format: "%.4e Hz", value)
    }

    private func formatPower(_ value: Double) -> String {
        guard value.isFinite else { return "∞" }
        return String(format: "%.4e W", value)
    }

    private func formatEnergy(_ value: Double) -> String {
        guard value.isFinite else { return "∞" }
        return String(format: "%.4e J", value)
    }

    private func formatScientific(_ value: Double) -> String {
        guard value.isFinite else { return "∞" }
        return String(format: "%.4e", value)
    }
}

// MARK: - SceneKit Helpers

extension SCNNode {
    func look(at target: SCNVector3) {
        let dx = target.x - position.x
        let dy = target.y - position.y
        let dz = target.z - position.z
        let horizontalDistance = sqrt(dx * dx + dz * dz)

        eulerAngles.y = -atan2(dx, dz)
        eulerAngles.x = atan2(dy, horizontalDistance)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}
