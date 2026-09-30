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
final class QuarkResonatorEngine: ObservableObject {

    @Published private(set) var state =
        QuarkResonatorState()

    @Published private(set) var modes:
        [ResonatorMode] = []

    var configuration =
        ResonatorConfiguration()

    var simulationTime: Double = 0.0

    private var sweepFrequencyHz: Double = 0.0

    private var sweepBestFrequencyHz: Double = 0.0

    private var sweepBestResponse: Double = 0.0

    private var sweepBestTargetDistanceHz: Double =
        .greatestFiniteMagnitude

    private var sweepHasStarted: Bool = false

    private var driveEnvelopePhase: Double = 0.0

    // ========================================================
    // MARK: Init
    // ========================================================

    init() {

        updateConfiguration(
            configuration
        )

        updatePipelineStages()
    }

    // ========================================================
    // MARK: Configuration
    // ========================================================

    func updateConfiguration(
        _ configuration: ResonatorConfiguration
    ) {

        self.configuration =
            configuration

        state.effectiveMassKg =
            configuration.effectiveMassKg

        state.restoringConstant =
            configuration.restoringConstant

        state.damping =
            configuration.damping

        state.targetFrequencyHz =
            QRConstants.targetFrequencyHz

        state.qrtlCoupling =
            configuration.qrtlCoupling

        state.inputVoltageV =
            configuration.inputVoltage

        calculateNaturalFrequency()

        calculateHydrogenTarget()

        calculateHelium4ShellTarget()

        calculateElectricalPower()

        updateTargetFrequencyLock()

        // BBO nonlinear crystal conversion
        state.bboResult =
            BBOCrystalModel.convert(
                configuration.bbo
            )
    }

    // ========================================================
    // MARK: Natural Frequency
    // ========================================================

    private func calculateNaturalFrequency() {

        let mass =
            max(
                configuration.effectiveMassKg,
                1e-60
            )

        let stiffness =
            max(
                configuration.restoringConstant,
                1e-60
            )

        let omega =
            sqrt(
                stiffness / mass
            )

        let frequency =
            omega /
            (2.0 * Double.pi)

        state.naturalFrequencyHz =
            frequency.isFinite
            ? frequency
            : 0

        state.outputFrequencyHz =
            state.naturalFrequencyHz

        updateFrequencyError()
    }

    // ========================================================
    // MARK: Frequency Error
    // ========================================================

    private func updateFrequencyError() {

        let target =
            max(
                state.targetFrequencyHz,
                1
            )

        let error =
            state.outputFrequencyHz -
            target

        state.frequencyErrorHz =
            error.isFinite
            ? error
            : 0

        state.frequencyErrorPercent =
            (
                abs(error) /
                target
            ) *
            100.0

        state.targetModeDetected =
            state.frequencyErrorPercent <=
            configuration.frequencyToleranceFraction * 100.0
    }

    // ========================================================
    // MARK: Electrical Power
    // ========================================================

    private func calculateElectricalPower() {

        let current =
            min(
                configuration.maximumCurrent,
                max(
                    0,
                    configuration.commandedCurrent
                )
            )

        state.inputCurrentA =
            current

        state.inputVoltageV =
            configuration.inputVoltage

        let power =
            state.inputVoltageV *
            state.inputCurrentA

        state.inputPowerW =
            power.isFinite
            ? max(power, 0)
            : 0
    }

    // ========================================================
    // MARK: Input Energy
    // ========================================================

    private func integrateInputEnergy(
        deltaTime: Double
    ) {

        guard deltaTime > 0 else {
            return
        }

        state.inputEnergyJ +=
            max(
                0,
                state.inputPowerW
            ) *
            deltaTime

        if !state.inputEnergyJ.isFinite {
            state.inputEnergyJ = 0
        }
    }

    // ========================================================
    // MARK: Hydrogen Target
    // ========================================================

    private func calculateHydrogenTarget() {

        let energyPerAtom =
            configuration.hydrogenShellEnergyEV *
            QRConstants.electronVolt

        let energy =
            configuration.hydrogenAtoms *
            configuration.excitationProbability *
            energyPerAtom

        state.requiredHydrogenEnergyJ =
            energy.isFinite
            ? max(energy, 0)
            : 0
    }

    // ========================================================
    // MARK: Helium-4 Target
    // ========================================================

    private func calculateHelium4ShellTarget() {

        // QRTL MODEL PARAMETER.
        //
        // This is not an experimentally established
        // helium-4 fusion threshold.

        let energyEV =
            max(
                100.0,
                0
            )

        let energyJ =
            energyEV *
            QRConstants.electronVolt

        state.helium4ShellTargetEnergyJ =
            energyJ.isFinite
            ? energyJ
            : 0
    }

    // ========================================================
    // MARK: Resonance Response
    // ========================================================

    private func calculateResonanceResponse(
        frequency: Double
    ) -> Double {

        let f0 =
            max(
                state.naturalFrequencyHz,
                1e-30
            )

        let mass =
            max(
                configuration.effectiveMassKg,
                1e-60
            )

        let stiffness =
            max(
                configuration.restoringConstant,
                1e-60
            )

        let damping =
            max(
                configuration.damping,
                0
            )

        let zeta =
            damping /
            (
                2.0 *
                sqrt(
                    stiffness *
                    mass
                )
            )

        let ratio =
            frequency /
            f0

        let denominator =
            sqrt(
                pow(
                    1.0 - ratio * ratio,
                    2
                )
                +
                pow(
                    2.0 *
                    zeta *
                    ratio,
                    2
                )
            )

        guard denominator.isFinite,
              denominator > 0
        else {
            return 0
        }

        let response =
            1.0 /
            denominator

        return response.isFinite
            ? response
            : 0
    }

    // ========================================================
    // MARK: Frequency Sweep
    // ========================================================

    private func startFrequencySweep() {

        sweepFrequencyHz =
            configuration.sweepStartFrequencyHz

        sweepBestFrequencyHz =
            configuration.sweepStartFrequencyHz

        sweepBestResponse = 0

        sweepBestTargetDistanceHz =
            .greatestFiniteMagnitude

        sweepHasStarted = true

        state.frequencySearchActive =
            true

        state.frequencySearchCompleted =
            false

        state.sweepFrequencyHz =
            sweepFrequencyHz

        state.bestResponseFrequencyHz =
            sweepBestFrequencyHz

        state.bestResonanceResponse =
            0

        state.statusMessage =
            "SEARCHING FREQUENCY"
    }

    private func advanceFrequencySweep() {

        guard sweepHasStarted else {
            startFrequencySweep()
            return
        }

        let response =
            calculateResonanceResponse(
                frequency:
                    sweepFrequencyHz
            )

        let distance =
            abs(
                sweepFrequencyHz -
                state.targetFrequencyHz
            )

        if distance <
            sweepBestTargetDistanceHz {

            sweepBestTargetDistanceHz =
                distance

            sweepBestFrequencyHz =
                sweepFrequencyHz

            sweepBestResponse =
                response
        }

        state.sweepFrequencyHz =
            sweepFrequencyHz

        state.bestResponseFrequencyHz =
            sweepBestFrequencyHz

        state.bestResonanceResponse =
            sweepBestResponse

        sweepFrequencyHz +=
            configuration.sweepStepFrequencyHz

        if sweepFrequencyHz >
            configuration.sweepEndFrequencyHz {

            finishFrequencySweep()
        }
    }

    private func finishFrequencySweep() {

        state.frequencySearchActive =
            false

        state.frequencySearchCompleted =
            true

        state.bestResponseFrequencyHz =
            sweepBestFrequencyHz

        state.bestResonanceResponse =
            sweepBestResponse

        state.outputFrequencyHz =
            sweepBestFrequencyHz

        updateFrequencyError()

        identifyResonatorModes()

        if state.targetModeDetected {

            state.statusMessage =
                "TARGET FREQUENCY FOUND"

        } else {

            state.statusMessage =
                "RESONANT MODE IDENTIFIED"
        }
    }

    // ========================================================
    // MARK: Resonator Modes
    // ========================================================

    private func identifyResonatorModes() {

        modes.removeAll()

        let fundamental =
            max(
                state.naturalFrequencyHz,
                0
            )

        let baseAmplitude =
            max(
                configuration.driveAmplitude,
                1e-18
            )

        for order in 1...12 {

            let frequency =
                fundamental *
                Double(order)

            let nonlinearFactor =
                pow(
                    max(
                        configuration.qrtlCoupling,
                        1e-6
                    ),
                    Double(order - 1)
                )

            let amplitude =
                baseAmplitude *
                nonlinearFactor

            let energy =
                0.5 *
                configuration.restoringConstant *
                amplitude *
                amplitude

            let response =
                calculateResonanceResponse(
                    frequency: frequency
                )

            let distance =
                abs(
                    frequency -
                    state.targetFrequencyHz
                )

            let resonant =
                response >=
                configuration.resonanceThreshold

            let label =
                order == 1
                ? "Fundamental"
                : "Harmonic \(order)"

            modes.append(
                ResonatorMode(
                    frequencyHz: frequency,
                    amplitude: amplitude,
                    energyJ: energy,
                    phase: state.phase,
                    label: label,
                    order: order,
                    resonanceResponse: response,
                    isResonant: resonant,
                    targetDistanceHz: distance
                )
            )
        }

        state.spectrumAnalyzed = true

        selectIdentifiedResonantMode()
    }

    private func selectIdentifiedResonantMode() {

        guard !modes.isEmpty else {
            return
        }

        let resonantModes =
            modes.filter {
                $0.isResonant
            }

        let selected =
            resonantModes.max {
                $0.resonanceResponse <
                $1.resonanceResponse
            }
            ??
            modes.max {
                $0.resonanceResponse <
                $1.resonanceResponse
            }

        guard let mode = selected else {
            return
        }

        state.resonanceResponse =
            mode.resonanceResponse

        state.resonantModeFrequencyHz =
            mode.frequencyHz

        state.resonantModeOrder =
            mode.order

        state.targetModeAmplitude =
            mode.amplitude

        state.targetModeEnergyJ =
            mode.energyJ

        state.generatedModeEnergyJ =
            mode.energyJ

        if !state.frequencySearchActive {

            state.outputFrequencyHz =
                mode.frequencyHz
        }

        state.resonantModeDetected =
            true

        updateFrequencyError()
    }

    // ========================================================
    // MARK: Mode Energy
    // ========================================================

    private func calculateModeEnergy(
        amplitude: Double
    ) -> Double {

        let energy =
            0.5 *
            configuration.restoringConstant *
            amplitude *
            amplitude

        return energy.isFinite
            ? max(energy, 0)
            : 0
    }

    // ========================================================
    // MARK: Stored Energy
    // ========================================================

    private func calculateStoredEnergy() {

        let kinetic =
            0.5 *
            configuration.effectiveMassKg *
            state.velocity *
            state.velocity

        let potential =
            0.5 *
            configuration.restoringConstant *
            state.displacement *
            state.displacement

        let total =
            kinetic +
            potential

        state.storedEnergyJ =
            total.isFinite
            ? max(total, 0)
            : 0

        state.qrtlEnergyJ =
            state.targetModeEnergyJ *
            configuration.qrtlCoupling
    }

    // ========================================================
    // MARK: Resonator Drive
    // ========================================================

    private func updateResonatorDrive(
        deltaTime: Double
    ) {

        let safeDeltaTime =
            min(
                0.1,
                max(
                    deltaTime,
                    0
                )
            )

        guard safeDeltaTime > 0 else {
            return
        }

        let frequency =
            max(
                state.outputFrequencyHz.isFinite
                ? state.outputFrequencyHz
                : 0,
                1
            )

        let omega =
            2.0 *
            Double.pi *
            frequency

        let responseFactor =
            min(
                1,
                max(
                    0,
                    state.resonanceResponse
                )
            )

        let stiffness =
            max(
                configuration.restoringConstant,
                1e-60
            )

        let driveAmplitude =
            max(
                configuration.driveAmplitude,
                0
            )

        let steadyStateAmplitude =
            (
                driveAmplitude /
                stiffness
            ) *
            responseFactor

        let decay =
            max(
                state.decayTimeS,
                1e-9
            )

        let envelope =
            1.0 -
            exp(
                -safeDeltaTime /
                decay
            )

        state.amplitude +=
            (
                steadyStateAmplitude -
                state.amplitude
            ) *
            envelope

        let phaseIncrement =
            omega *
            safeDeltaTime

        driveEnvelopePhase =
            (
                driveEnvelopePhase +
                phaseIncrement
            )
            .truncatingRemainder(
                dividingBy:
                    2.0 *
                    Double.pi
            )

        let phi =
            driveEnvelopePhase +
            configuration.drivePhase

        let x =
            state.amplitude *
            cos(phi)

        let v =
            -state.amplitude *
            omega *
            sin(phi)

        let a =
            -state.amplitude *
            omega *
            omega *
            cos(phi)

        state.displacement =
            x.isFinite
            ? x
            : 0

        state.velocity =
            v.isFinite
            ? v
            : 0

        state.acceleration =
            a.isFinite
            ? a
            : 0

        state.phase =
            phi
                .truncatingRemainder(
                    dividingBy:
                        2.0 *
                        Double.pi
                )
    }

    // ========================================================
    // MARK: Loss
    // ========================================================

    private func calculateLoss() {

        let omega =
            2.0 *
            Double.pi *
            max(
                state.outputFrequencyHz,
                1
            )

        let loss =
            configuration.damping *
            state.velocity *
            state.velocity

        state.lossPowerW =
            loss.isFinite
            ? max(loss, 0)
            : 0

        let decay =
            2.0 *
            configuration.effectiveMassKg /
            max(
                configuration.damping,
                1e-60
            )

        state.decayTimeS =
            decay.isFinite
            ? max(decay, 0)
            : 0

        let q =
            configuration.effectiveMassKg *
            omega /
            max(
                configuration.damping,
                1e-60
            )

        state.qualityFactor =
            q.isFinite
            ? max(q, 0)
            : 0

        state.bandwidthHz =
            state.qualityFactor > 0
            ? state.outputFrequencyHz /
              state.qualityFactor
            : 0
    }

    // ========================================================
    // MARK: Required Power
    // ========================================================

    private func calculateRequiredPower() {

        state.requiredHydrogenPowerW =
            state.requiredHydrogenEnergyJ /
            1.0

        let efficiency =
            max(
                configuration.driverEfficiency *
                configuration.couplingEfficiency,
                1e-6
            )

        state.requiredInputPowerW =
            (
                state.requiredHydrogenPowerW /
                efficiency
            )
            +
            state.lossPowerW

        state.requiredInputCurrentA =
            state.requiredInputPowerW /
            max(
                state.inputVoltageV,
                1e-12
            )

        state.powerDeficitW =
            max(
                state.requiredInputPowerW -
                state.inputPowerW,
                0
            )

        state.powerFeedbackActive =
            state.powerDeficitW > 0
    }

    // ========================================================
    // MARK: Power Feedback
    // ========================================================

    private func increasePowerIfInsufficient(
        deltaTime: Double
    ) {

        guard configuration.powerFeedbackEnabled,
              state.powerDeficitW > 0
        else {
            return
        }

        let voltage =
            max(
                state.inputVoltageV,
                1e-12
            )

        let correction =
            (
                state.powerDeficitW /
                voltage
            ) *
            configuration.powerGain *
            deltaTime

        configuration.commandedCurrent =
            min(
                configuration.maximumCurrent,
                max(
                    0,
                    configuration.commandedCurrent +
                    correction
                )
            )

        calculateElectricalPower()

        if configuration.commandedCurrent >=
            configuration.maximumCurrent {

            state.statusMessage =
                "POWER LIMIT REACHED"

        } else {

            state.statusMessage =
                "INCREASING INPUT POWER"
        }
    }

    // ========================================================
    // MARK: Target Frequency Lock
    // ========================================================

    private func updateTargetFrequencyLock() {

        let target =
            max(
                state.targetFrequencyHz,
                1
            )

        let actual =
            max(
                state.outputFrequencyHz,
                0
            )

        let errorFraction =
            abs(
                actual -
                target
            ) /
            target

        state.frequencyLockErrorFraction =
            errorFraction.isFinite
            ? errorFraction
            : 1

        state.targetFrequencyLocked =
            errorFraction <=
            configuration.frequencyToleranceFraction
    }

    // ========================================================
    // MARK: Coherence
    // ========================================================

    private func calculateCoherence() {

        guard state.targetFrequencyLocked
        else {

            state.coherence = 0

            state.coherentCarrierActive =
                false

            return
        }

        let frequencyError =
            state.frequencyLockErrorFraction

        let frequencyCoherence =
            max(
                0,
                1.0 -
                frequencyError /
                max(
                    configuration.frequencyToleranceFraction,
                    1e-12
                )
            )

        let phaseCoherence =
            max(
                0,
                cos(
                    state.phaseError
                )
            )

        let coherence =
            frequencyCoherence *
            phaseCoherence

        state.coherence =
            coherence.isFinite
            ? min(
                1,
                coherence
            )
            : 0

        state.coherentCarrierActive =
            state.coherence >= 0.90
    }

    // ========================================================
    // MARK: QRTL Coupling
    // ========================================================

    private func calculateQRTLCoupling() {

        guard state.coherentCarrierActive
        else {

            state.qrtlCoupledEnergyJ = 0

            state.qrtlEnergyJ = 0

            return
        }

        let modeEnergy =
            max(
                state.generatedModeEnergyJ,
                0
            )

        let coupling =
            min(
                1,
                max(
                    0,
                    configuration.qrtlCoupling
                )
            )

        let coupledEnergy =
            modeEnergy *
            state.coherence *
            coupling

        state.qrtlCoupledEnergyJ =
            coupledEnergy.isFinite
            ? coupledEnergy
            : 0

        state.qrtlEnergyJ =
            state.qrtlCoupledEnergyJ
    }

    // ========================================================
    // MARK: Helium-4 Shell
    // ========================================================

    private func calculateHelium4ShellExcitation() {

        let target =
            max(
                state.helium4ShellTargetEnergyJ,
                1e-30
            )

        let available =
            max(
                state.qrtlCoupledEnergyJ,
                0
            )

        let excitation =
            min(
                1,
                available /
                target
            )

        state.helium4ShellExcitationFraction =
            excitation.isFinite
            ? excitation
            : 0

        state.helium4ShellEnergyJ =
            target *
            state.helium4ShellExcitationFraction

        state.helium4ShellExcited =
            state.helium4ShellExcitationFraction >=
            1.0

        state.fusionTransitionReady =
            state.targetFrequencyLocked &&
            state.coherentCarrierActive &&
            state.helium4ShellExcited
    }

    // ========================================================
    // MARK: Phase Lock
    // ========================================================

    func phaseLock() {

        let error =
            -state.phase

        let correction =
            configuration.phaseGain *
            error

        configuration.drivePhase +=
            correction

        state.phaseError =
            error

        state.phaseLocked =
            abs(error) < 0.05
    }

    // ========================================================
    // MARK: Hydrogen Response
    // ========================================================

    private func calculateHydrogenResponse() {

        guard state.qrtlEnabled,
              state.targetModeDetected
        else {

            state.hydrogenGroundPopulation =
                1

            state.hydrogenExcitedPopulation =
                0

            state.hydrogenShellEnergyJ =
                0

            state.hydrogenEnergyChangeJ =
                0

            return
        }

        let availableEnergy =
            state.qrtlEnergyJ *
            configuration.couplingEfficiency

        let excitationFraction =
            min(
                1,
                availableEnergy /
                max(
                    state.requiredHydrogenEnergyJ,
                    1e-30
                )
            )

        state.hydrogenExcitedPopulation =
            excitationFraction

        state.hydrogenGroundPopulation =
            1 -
            excitationFraction

        state.hydrogenEnergyChangeJ =
            state.requiredHydrogenEnergyJ *
            excitationFraction

        state.hydrogenShellEnergyJ =
            state.hydrogenEnergyChangeJ

        state.energyTargetReached =
            state.hydrogenEnergyChangeJ >=
            state.requiredHydrogenEnergyJ
    }

    // ========================================================
    // MARK: Pipeline
    // ========================================================

    private func updatePipelineStages() {

        let stages = [

            (
                1,
                "Electrical Driver",
                "Electrical power supplied to the resonator."
            ),

            (
                2,
                "Frequency Search",
                "Sweeping the resonator toward 10¹⁵ Hz."
            ),

            (
                3,
                "Resonant Frequency Lock",
                "Comparing output frequency with the 10¹⁵ Hz target."
            ),

            (
                4,
                "Coherent Carrier",
                "Phase and frequency coherence established."
            ),

            (
                5,
                "QRTL Coupling",
                "Coherent resonator energy transferred into QRTL."
            ),

            (
                6,
                "Helium-4 Shell",
                "QRTL-coupled energy raises the modeled helium-4 shell."
            ),

            (
                7,
                "Fusion-State Transition",
                "Final modeled QRTL transition condition."
            )
        ]

        state.pipelineStages =
            stages.map {

                let status:
                    PipelineStageStatus

                switch $0.0 {

                case 1:
                    status =
                        state.inputPowerW > 0
                        ? .done
                        : .active

                case 2:
                    status =
                        state.frequencySearchActive
                        ? .active
                        :
                        state.frequencySearchCompleted
                        ? .done
                        : .pending

                case 3:
                    status =
                        state.targetFrequencyLocked
                        ? .done
                        :
                        state.frequencySearchCompleted
                        ? .active
                        : .pending

                case 4:
                    status =
                        state.coherentCarrierActive
                        ? .done
                        :
                        state.targetFrequencyLocked
                        ? .active
                        : .pending

                case 5:
                    status =
                        state.qrtlCoupledEnergyJ > 0
                        ? .done
                        :
                        state.coherentCarrierActive
                        ? .active
                        : .pending

                case 6:
                    status =
                        state.helium4ShellExcited
                        ? .done
                        :
                        state.qrtlCoupledEnergyJ > 0
                        ? .active
                        : .pending

                default:
                    status =
                        state.fusionTransitionReady
                        ? .complete
                        :
                        state.helium4ShellExcited
                        ? .active
                        : .pending
                }

                return PipelineStageInfo(
                    order: $0.0,
                    name: $0.1,
                    detail: $0.2,
                    status: status
                )
            }
    }

    // ========================================================
    // MARK: STEP
    // ========================================================

    func step(
        deltaTime: Double
    ) {

        guard state.running else {
            return
        }

        let safeDeltaTime =
            min(
                0.1,
                max(
                    deltaTime,
                    0
                )
            )

        simulationTime +=
            safeDeltaTime

        // 1. Electrical input
        calculateElectricalPower()

        // 2. Integrate electrical energy once
        integrateInputEnergy(
            deltaTime:
                safeDeltaTime
        )

        // 3. Frequency search
        if state.frequencySearchActive {

            advanceFrequencySweep()
        }

        // 4. Resonator carrier
        if state.frequencySearchCompleted {

            updateResonatorDrive(
                deltaTime:
                    safeDeltaTime
            )
        }

        // 5. Stored resonator energy
        calculateStoredEnergy()

        // 6. Loss and Q
        calculateLoss()

        // 7. Identify resonant modes
        identifyResonatorModes()

        // 8. Determine target frequency lock
        updateTargetFrequencyLock()

        // 9. Phase / coherence
        phaseLock()

        calculateCoherence()

        // 10. QRTL coupling
        calculateQRTLCoupling()

        // 11. Helium-4 shell
        calculateHelium4ShellExcitation()

        // Existing hydrogen response retained
        calculateHydrogenResponse()

        // 12. Required power
        calculateRequiredPower()

        // 13. Power feedback
        increasePowerIfInsufficient(
            deltaTime:
                safeDeltaTime
        )

        // 14. Final electrical state
        calculateElectricalPower()

        // 15. Pipeline
        updatePipelineStages()
    }

    // ========================================================
    // MARK: START
    // ========================================================

    func start() {

        guard !state.running else {
            return
        }

        simulationTime = 0

        state.running = true

        configuration.commandedCurrent =
            min(
                configuration.maximumCurrent,
                max(
                    configuration.commandedCurrent,
                    0.01
                )
            )

        startFrequencySweep()

        state.statusMessage =
            "STARTING FREQUENCY SEARCH"
    }

    // ========================================================
    // MARK: STOP
    // ========================================================

    func stop() {

        state.running = false

        state.statusMessage =
            "STOPPED"
    }

    // ========================================================
    // MARK: RESET
    // ========================================================

    func reset() {

        state.running = false

        simulationTime = 0

        configuration.commandedCurrent = 0

        driveEnvelopePhase = 0

        sweepFrequencyHz = 0

        sweepBestFrequencyHz = 0

        sweepBestResponse = 0

        sweepBestTargetDistanceHz =
            .greatestFiniteMagnitude

        sweepHasStarted = false

        modes.removeAll()

        state =
            QuarkResonatorState()

        updateConfiguration(
            configuration
        )

        updatePipelineStages()

        state.statusMessage =
            "READY"
    }

    // ========================================================
    // MARK: QRTL
    // ========================================================

    func setQRTLEnabled(
        _ enabled: Bool
    ) {

        state.qrtlEnabled =
            enabled

        if enabled {

            state.statusMessage =
                "QRTL ENABLED"

        } else {

            state.statusMessage =
                "QRTL DISABLED"
        }
    }
}

