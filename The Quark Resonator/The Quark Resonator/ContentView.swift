//
//  ContentView.swift
//  The Quark Resonator
//
//  Main screen. Shared types live in their own files:
//    DataStructures.swift                 QRConstants, ResonatorConfiguration, ResonatorMode,
//                                         PipelineStageStatus, PipelineStageInfo, QuarkResonatorState
//    QuarkResonatorEngine.swift           QuarkResonatorEngine
//    QuarkResonatorSceneController.swift  QuarkResonatorSceneController
//    QuarkResonatorSceneView.swift        QuarkResonatorSceneView
//    BBOCrystalStage.swift                BBO crystal model and 3D stage
//
//  Added here: BBO CRYSTAL panel.
//

import SwiftUI
import SceneKit
import Combine
import UIKit

// MARK: - Content View

struct ContentView: View {

    @StateObject private var engine = QuarkResonatorEngine()
    @StateObject private var sceneController = QuarkResonatorSceneController()
    @StateObject private var fusionSimulator = FusionResonatorSimulator()

    @State private var timer: Timer?
    @State private var showFusionSimulator = false
    @State private var fusionZoomedIn = false

    private var estimatedShellEnergyEV: Double {

        engine.state.qrtlEnergyJ /
        QRConstants.electronVolt
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
        if showFusionSimulator {
            ZStack(alignment: .topTrailing) {
                FusionResonatorSceneView(simulator: fusionSimulator, isZoomedIn: $fusionZoomedIn)
                    .ignoresSafeArea()
                VStack(alignment: .trailing, spacing: 10) {
                    Button {
                        showFusionSimulator = false
                        fusionSimulator.stopSimulation()
                    } label: {
                        Text("Return")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .padding(10)
                            .background(Color.black.opacity(0.6))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    Button {
                        fusionZoomedIn.toggle()
                    } label: {
                        Text(fusionZoomedIn ? "Zoom Out" : "Zoom In")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .padding(10)
                            .background(Color.black.opacity(0.6))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                }
                .padding()
            }
        } else {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    liveActivityPanel          // ← moved to top of screen
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    frequencyKey

                    QuarkResonatorSceneView(
                        controller: sceneController,
                        state: engine.state
                    )
                    .frame(minHeight: 320)
                    ScrollView {
                        VStack(spacing: 12) {
                            controlPanel
                            //pipelineStagesPanel        // ← NEW
                            //frequencyPanel
                            bboPanel                   // ← NEW
                            electricalPanel
                            //resonancePanel
                            energyPanel
                            //hydrogenPanel
                            //sweepPanel
                            
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
            .onChange(of: engine.state.outputFrequencyHz) { newValue in
                if newValue >= 1.0e15 && !showFusionSimulator {
                    showFusionSimulator = true
                    fusionSimulator.startSimulation()
                }
            }
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

    // MARK: - Pipeline Stages Panel (NEW)

    private var pipelineStagesPanel: some View {
        panel(title: "SIMULATION PIPELINE") {
            VStack(alignment: .leading, spacing: 0) {
                let stages = engine.state.pipelineStages

                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    pipelineStageRow(stage: stage, isLast: index == stages.count - 1)
                }

                if stages.isEmpty {
                    Text("No pipeline data yet — press START.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }
        }
    }

    private func pipelineStageRow(stage: PipelineStageInfo, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(pipelineStageColor(stage.status))
                        .frame(width: 22, height: 22)
                    Text("\(stage.order)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                }
                .overlay(
                    Circle()
                        .stroke(pipelineStageColor(stage.status).opacity(0.5), lineWidth: 3)
                        .scaleEffect(1.5)
                        .opacity(stage.status == .active ? 1 : 0)
                        .animation(
                            stage.status == .active
                                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                                : .default,
                            value: stage.status
                        )
                )

                if !isLast {
                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 2)
                        .frame(minHeight: 26)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(stage.name)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                
                }
                Text(stage.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)
            }
            .padding(.bottom, isLast ? 2 : 14)
        }
    }

    private func pipelineStageColor(
        _ status: PipelineStageStatus
    ) -> Color {

        switch status {

        case .pending:
            return .gray

        case .active:
            return .cyan

        case .done:
            return .green

        case .skipped:
            return .white.opacity(0.3)

        case .complete:
            return .green
        }
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

    // MARK: - BBO Crystal Panel (NEW)

    private var bboPanel: some View {
        let r = engine.state.bboResult
        let windowOK = r.pumpTransmitted && r.outputTransmitted

        return panel(title: "BBO CRYSTAL (SHG)") {
            valueRow("Pump",
                     String(format: "%.4e Hz (%.1f nm)",
                            engine.configuration.bbo.pumpFrequencyHz,
                            r.pumpWavelengthNm))
            valueRow("Output",
                     String(format: "%.4e Hz (%.1f nm)",
                            r.outputFrequencyHz,
                            r.outputWavelengthNm))
            valueRow("Phase-Match Angle",
                     r.phaseMatchAngleRad.map {
                         String(format: "%.3f°", $0 * 180.0 / Double.pi)
                     } ?? "NONE")
            valueRow("Phase Mismatch",
                     String(format: "%.3e rad/m", r.phaseMismatchRadPerM))
            valueRow("d_eff",
                     String(format: "%.3f pm/V", r.effectiveNonlinearityPmPerV))
            valueRow("Conversion",
                     String(format: "%.2f%%", r.conversionEfficiency * 100.0))
            valueRow("In BBO Window", windowOK ? "TRUE" : "FALSE")
        }
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
                if engine.state.outputFrequencyHz >= 1.0e15 && !showFusionSimulator {
                    showFusionSimulator = true
                    fusionSimulator.startSimulation()
                }
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

