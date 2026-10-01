//
//  File.swift
//  The Quark Resonator
//
//  Created by David Nishimoto on 9/30/26.
//

import Foundation
import SwiftUI
import SceneKit
// BBO types (BBOCrystalConfiguration, BBOConversionResult) live in BBOCrystalStage.swift

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
