//
//  BBOCrystalStage.swift
//  The Quark Resonator
//
//  Nonlinear-optics stage: a BBO (beta-barium borate) crystal that frequency-doubles
//  a pump laser into the UV. With a pump at 5.0e14 Hz (599.6 nm) the second harmonic
//  is 1.0e15 Hz (299.8 nm), the simulation's target frequency.
//
//  Contents
//    1. BBOCrystalConfiguration  - crystal / pump parameters
//    2. BBOConversionResult      - what the model reports
//    3. BBOCrystalModel          - Sellmeier indices, phase-match angle, SHG efficiency
//    4. BBOCrystalStageNode      - SceneKit equipment (pump, rotation stage, crystal,
//                                  dichroic mirror, beam dump, UV output)
//
//  Model notes (type-I o + o -> e second-harmonic generation):
//    - Indices: Eimerl et al. Sellmeier equations for BBO (wavelength in micrometres).
//    - Phase matching: n_o(w) = n_e(2w, theta), solved by bisection.
//    - Efficiency: undepleted-pump plane-wave estimate,
//          eta = tanh^2(Gamma L) * sinc^2(dk L / 2)
//      with Gamma^2 = 2 w^2 d_eff^2 I / (n1^2 n2 eps0 c^3).
//      This is a first-order engineering estimate: no walk-off, beam profile,
//      pulse shape, absorption or thermal effects.
//    - d_eff = d22 cos(theta) (phi = 90 deg orientation; the small d31 term is ignored).
//
//  The crystal converts light. It does not turn mechanical motion into 1e15 Hz.
//  The rotation stage is the only mechanical part: it sets the crystal angle.
//

import Foundation
import SceneKit
import UIKit

// MARK: - Configuration

struct BBOCrystalConfiguration {

    /// Pump laser frequency. 5.0e14 Hz doubles to 1.0e15 Hz.
    var pumpFrequencyHz: Double = 5.0e14

    /// Crystal length along the beam.
    var crystalLengthM: Double = 5.0e-3

    /// Pump intensity inside the crystal (1e13 W/m^2 = 1 GW/cm^2).
    var pumpIntensityWPerM2: Double = 1.0e13

    /// Nonlinear coefficient d22 of BBO, in pm/V.
    var d22PmPerV: Double = 2.2

    /// Mechanical angle error of the rotation stage relative to phase matching.
    var angleDetuneRad: Double = 0.0

    /// Commercial BBO transmission window, in nm.
    var transmissionMinNm: Double = 189.0
    var transmissionMaxNm: Double = 3500.0
}

// MARK: - Result

struct BBOConversionResult {

    var pumpWavelengthNm: Double = 0.0
    var outputFrequencyHz: Double = 0.0
    var outputWavelengthNm: Double = 0.0

    /// Angle between beam and optic axis that satisfies phase matching (nil if impossible).
    var phaseMatchAngleRad: Double? = nil

    /// Angle the stage actually sits at (phase-match angle plus detune).
    var operatingAngleRad: Double = 0.0

    var phaseMismatchRadPerM: Double = 0.0
    var effectiveNonlinearityPmPerV: Double = 0.0

    /// Fraction of pump power converted to the second harmonic (0...1).
    var conversionEfficiency: Double = 0.0

    var pumpTransmitted: Bool = false
    var outputTransmitted: Bool = false

    var isPhaseMatchable: Bool { phaseMatchAngleRad != nil }
    
    var successful : Bool = false
}

// MARK: - Model

enum BBOCrystalModel {

    private static let speedOfLight = 299_792_458.0

    private static let vacuumPermittivity = 8.854_187_812_8e-12

    // ----------------------------------------------------
    // Empty result
    // ----------------------------------------------------

    static func emptyResult() -> BBOConversionResult {

        return BBOConversionResult(
            pumpWavelengthNm: 0.0,
            outputFrequencyHz: 0.0,
            outputWavelengthNm: 0.0,
            phaseMatchAngleRad: nil,
            operatingAngleRad: 0.0,
            phaseMismatchRadPerM: 0.0,
            effectiveNonlinearityPmPerV: 0.0,
            conversionEfficiency: 0.0,
            pumpTransmitted: false,
            outputTransmitted: false,
            successful: false
        )
    }

    // Eimerl Sellmeier equations, wavelength in micrometres.

    static func ordinaryIndex(wavelengthUm l: Double) -> Double {

        let l2 = l * l

        let n2 =
            2.7359
            + 0.01878 / (l2 - 0.01822)
            - 0.01354 * l2

        return n2 > 0 ? n2.squareRoot() : 1.0
    }

    static func extraordinaryIndexPrincipal(
        wavelengthUm l: Double
    ) -> Double {

        let l2 = l * l

        let n2 =
            2.3753
            + 0.01224 / (l2 - 0.01667)
            - 0.01516 * l2

        return n2 > 0 ? n2.squareRoot() : 1.0
    }

    /// Extraordinary index at angle theta from the optic axis.
    static func extraordinaryIndex(
        wavelengthUm l: Double,
        angleRad theta: Double
    ) -> Double {

        let no =
            ordinaryIndex(
                wavelengthUm: l
            )

        let ne =
            extraordinaryIndexPrincipal(
                wavelengthUm: l
            )

        let s = sin(theta)
        let c = cos(theta)

        let inverseSquare =
            (s * s) / (ne * ne)
            + (c * c) / (no * no)

        return inverseSquare > 0
            ? 1.0 / inverseSquare.squareRoot()
            : no
    }

    /// Type-I phase-matching angle for second-harmonic generation, or nil.
    static func phaseMatchAngle(
        pumpWavelengthUm l1: Double
    ) -> Double? {

        let l2 = l1 / 2.0

        let targetIndex =
            ordinaryIndex(
                wavelengthUm: l1
            )

        func mismatch(_ theta: Double) -> Double {

            extraordinaryIndex(
                wavelengthUm: l2,
                angleRad: theta
            ) - targetIndex
        }

        var low = 0.0
        var high = Double.pi / 2.0

        let fLow = mismatch(low)
        let fHigh = mismatch(high)

        guard
            fLow.isFinite,
            fHigh.isFinite,
            fLow * fHigh <= 0
        else {
            return nil
        }

        for _ in 0..<80 {

            let mid =
                0.5 * (low + high)

            if mismatch(low) * mismatch(mid) <= 0 {

                high = mid

            } else {

                low = mid
            }
        }

        return 0.5 * (low + high)
    }

    private static func sinc(
        _ x: Double
    ) -> Double {

        abs(x) < 1.0e-9
            ? 1.0
            : sin(x) / x
    }

    static func convert(
        _ config: BBOCrystalConfiguration
    ) -> BBOConversionResult {

        var result = BBOConversionResult()

        // ----------------------------------------------------
        // Validate pump frequency
        // ----------------------------------------------------

        guard
            config.pumpFrequencyHz.isFinite,
            config.pumpFrequencyHz > 0.0
        else {
            return result
        }

        // ----------------------------------------------------
        // Pump wavelength
        //
        // λ = c / f
        // ----------------------------------------------------

        let pumpWavelengthM =
            speedOfLight / config.pumpFrequencyHz

        let pumpWavelengthUm =
            pumpWavelengthM * 1.0e6

        // ----------------------------------------------------
        // Second-harmonic wavelength
        //
        // SHG:
        //
        // f₂ = 2 f₁
        // λ₂ = λ₁ / 2
        // ----------------------------------------------------

        let outputWavelengthUm =
            pumpWavelengthUm / 2.0

        result.pumpWavelengthNm =
            pumpWavelengthUm * 1.0e3

        result.outputFrequencyHz =
            2.0 * config.pumpFrequencyHz

        result.outputWavelengthNm =
            outputWavelengthUm * 1.0e3

        // ----------------------------------------------------
        // BBO transmission window
        // ----------------------------------------------------

        result.pumpTransmitted =
            result.pumpWavelengthNm >= config.transmissionMinNm &&
            result.pumpWavelengthNm <= config.transmissionMaxNm

        result.outputTransmitted =
            result.outputWavelengthNm >= config.transmissionMinNm &&
            result.outputWavelengthNm <= config.transmissionMaxNm

        // ----------------------------------------------------
        // Find Type-I phase-matching angle
        // ----------------------------------------------------

        guard let matchAngle =
            phaseMatchAngle(
                pumpWavelengthUm: pumpWavelengthUm
            )
        else {
            return result
        }

        // ----------------------------------------------------
        // Apply crystal angle detuning
        // ----------------------------------------------------

        let operatingAngle =
            matchAngle + config.angleDetuneRad

        result.phaseMatchAngleRad =
            matchAngle

        result.operatingAngleRad =
            operatingAngle

        // ----------------------------------------------------
        // Refractive indices
        // ----------------------------------------------------

        let n1 =
            ordinaryIndex(
                wavelengthUm: pumpWavelengthUm
            )

        let n2 =
            extraordinaryIndex(
                wavelengthUm: outputWavelengthUm,
                angleRad: operatingAngle
            )

        // ----------------------------------------------------
        // Effective nonlinear coefficient
        // ----------------------------------------------------

        let deffPm =
            config.d22PmPerV *
            cos(operatingAngle)

        let deff =
            deffPm * 1.0e-12

        result.effectiveNonlinearityPmPerV =
            deffPm

        // ----------------------------------------------------
        // Nonlinear coupling strength
        // ----------------------------------------------------

        let omega =
            2.0 *
            Double.pi *
            config.pumpFrequencyHz

        let c3 =
            speedOfLight *
            speedOfLight *
            speedOfLight

        let pumpIntensity =
            max(
                config.pumpIntensityWPerM2,
                0.0
            )

        let gammaSquared =
            (
                2.0 *
                omega *
                omega *
                deff *
                deff *
                pumpIntensity
            )
            /
            (
                n1 *
                n1 *
                n2 *
                vacuumPermittivity *
                c3
            )

        let gamma =
            gammaSquared > 0.0
            ? gammaSquared.squareRoot()
            : 0.0

        // ----------------------------------------------------
        // Phase mismatch
        //
        // Δk = k₂ - 2k₁
        // ----------------------------------------------------

        let k1 =
            2.0 *
            Double.pi *
            n1 /
            pumpWavelengthM

        let k2 =
            2.0 *
            Double.pi *
            n2 /
            (pumpWavelengthM / 2.0)

        let deltaK =
            k2 - 2.0 * k1

        result.phaseMismatchRadPerM =
            deltaK

        // ----------------------------------------------------
        // Crystal conversion
        // ----------------------------------------------------

        let length =
            max(
                config.crystalLengthM,
                0.0
            )

        let tanhTerm =
            tanh(
                gamma * length
            )

        let sincTerm =
            sinc(
                deltaK * length / 2.0
            )

        var efficiency =
            tanhTerm *
            tanhTerm *
            sincTerm *
            sincTerm

        // ----------------------------------------------------
        // Transmission requirement
        // ----------------------------------------------------

        if !(
            result.pumpTransmitted &&
            result.outputTransmitted
        ) {
            efficiency = 0.0
        }

        // ----------------------------------------------------
        // Clamp conversion efficiency
        // ----------------------------------------------------

        result.conversionEfficiency =
            efficiency.isFinite
            ? min(
                1.0,
                max(
                    0.0,
                    efficiency
                )
            )
            : 0.0

        // ----------------------------------------------------
        // Final BBO outcome
        //
        // The conversion is considered successful only when
        // the pump and output are transmitted, phase matching
        // exists, and a positive conversion efficiency was
        // calculated.
        // ----------------------------------------------------

        result.successful =
            result.pumpTransmitted &&
            result.outputTransmitted &&
            result.isPhaseMatchable &&
            result.conversionEfficiency > 0.0

        return result
    }
}

// MARK: - SceneKit Stage

/// Beam axis is local +X. Stage spans roughly x = -1.9 ... +2.4. Place it after the
/// existing output, for example `bboStage.position = SCNVector3(7.6, 0, 0)`.
final class BBOCrystalStageNode: SCNNode {

    private let rotor = SCNNode()            // rotates about Y with the crystal angle
    private let crystalNode = SCNNode()
    private let pumpBeam = SCNNode()
    private let residualBeamX = SCNNode()
    private let residualBeamZ = SCNNode()
    private let uvBeam = SCNNode()

    private var titleReadout = SCNNode()
    private var lineOneReadout = SCNNode()
    private var lineTwoReadout = SCNNode()
    private var lastLineOne = ""
    private var lastLineTwo = ""

    private let pumpColor = UIColor(red: 1.0, green: 0.55, blue: 0.10, alpha: 1.0)
    private let uvColor = UIColor(red: 0.62, green: 0.30, blue: 1.0, alpha: 1.0)

    override init() {
        super.init()
        name = "BBOCrystalStage"
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    // MARK: Build

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

    private func build() {

        // Base plate
        let base = SCNBox(width: 4.6, height: 0.16, length: 3.4, chamferRadius: 0.04)
        base.firstMaterial = material(UIColor(white: 0.20, alpha: 1.0))
        let baseNode = SCNNode(geometry: base)
        baseNode.position = SCNVector3(0.25, -1.05, 0)
        addChildNode(baseNode)

        // Input beam (pump laser)
        pumpBeam.addChildNode(beamAlongX(from: -1.9, to: -0.35, radius: 0.06, color: pumpColor))
        addChildNode(pumpBeam)

        let pumpPort = SCNCylinder(radius: 0.22, height: 0.5)
        pumpPort.firstMaterial = material(UIColor(white: 0.35, alpha: 1.0))
        let pumpPortNode = SCNNode(geometry: pumpPort)
        pumpPortNode.eulerAngles.z = Float.pi / 2
        pumpPortNode.position = SCNVector3(-2.1, 0, 0)
        addChildNode(pumpPortNode)

        // Rotation stage (the mechanical part): turntable that tilts the crystal
        let table = SCNCylinder(radius: 0.75, height: 0.14)
        table.firstMaterial = material(UIColor(white: 0.45, alpha: 1.0))
        let tableNode = SCNNode(geometry: table)
        tableNode.position = SCNVector3(0, -0.85, 0)
        addChildNode(tableNode)

        let scale = SCNTorus(ringRadius: 0.78, pipeRadius: 0.018)
        scale.firstMaterial = material(.systemYellow, emissive: true)
        let scaleNode = SCNNode(geometry: scale)
        scaleNode.position = SCNVector3(0, -0.77, 0)
        addChildNode(scaleNode)

        rotor.position = SCNVector3(0, -0.72, 0)
        addChildNode(rotor)

        // Pointer on the rotor so the angle is visible
        let pointer = SCNBox(width: 0.75, height: 0.04, length: 0.06, chamferRadius: 0)
        pointer.firstMaterial = material(.systemYellow, emissive: true)
        let pointerNode = SCNNode(geometry: pointer)
        pointerNode.position = SCNVector3(0.0, 0.0, 0.62)
        rotor.addChildNode(pointerNode)

        // Crystal holder post and crystal
        let post = SCNCylinder(radius: 0.05, height: 0.72)
        post.firstMaterial = material(UIColor(white: 0.6, alpha: 1.0))
        let postNode = SCNNode(geometry: post)
        postNode.position = SCNVector3(0, 0.36, 0)
        rotor.addChildNode(postNode)

        let crystal = SCNBox(width: 0.9, height: 0.5, length: 0.5, chamferRadius: 0.03)
        let crystalMaterial = material(UIColor(red: 0.70, green: 0.85, blue: 1.0, alpha: 1.0), alpha: 0.45)
        crystalMaterial.transparency = 0.45
        crystalMaterial.writesToDepthBuffer = false
        crystalMaterial.emission.contents = uvColor
        crystalMaterial.emission.intensity = 0.0
        crystal.firstMaterial = crystalMaterial
        crystalNode.geometry = crystal
        crystalNode.position = SCNVector3(0, 0.72, 0)
        crystalNode.renderingOrder = 10
        rotor.addChildNode(crystalNode)

        // Output side: residual pump, UV beam, dichroic mirror, beam dump
        residualBeamX.addChildNode(beamAlongX(from: 0.45, to: 1.0, radius: 0.035, color: pumpColor))
        addChildNode(residualBeamX)

        let zLeg = SCNCylinder(radius: 0.035, height: 1.4)
        zLeg.firstMaterial = material(pumpColor, emissive: true)
        residualBeamZ.geometry = zLeg
        residualBeamZ.eulerAngles.x = Float.pi / 2
        residualBeamZ.position = SCNVector3(1.0, 0, -0.7)
        addChildNode(residualBeamZ)

        uvBeam.addChildNode(beamAlongX(from: 0.45, to: 2.4, radius: 0.06, color: uvColor))
        addChildNode(uvBeam)

        let mirror = SCNBox(width: 0.03, height: 0.7, length: 0.7, chamferRadius: 0)
        let mirrorMaterial = material(UIColor(red: 0.6, green: 0.9, blue: 1.0, alpha: 1.0), alpha: 0.5)
        mirrorMaterial.transparency = 0.5
        mirrorMaterial.writesToDepthBuffer = false
        mirror.firstMaterial = mirrorMaterial
        let mirrorNode = SCNNode(geometry: mirror)
        mirrorNode.position = SCNVector3(1.0, 0, 0)
        mirrorNode.eulerAngles.y = Float.pi / 4
        mirrorNode.renderingOrder = 10
        addChildNode(mirrorNode)

        let dump = SCNBox(width: 0.5, height: 0.5, length: 0.3, chamferRadius: 0.02)
        dump.firstMaterial = material(UIColor(white: 0.05, alpha: 1.0))
        let dumpNode = SCNNode(geometry: dump)
        dumpNode.position = SCNVector3(1.0, 0, -1.5)
        addChildNode(dumpNode)

        let uvPort = SCNCylinder(radius: 0.2, height: 0.4)
        uvPort.firstMaterial = material(uvColor, emissive: true)
        let uvPortNode = SCNNode(geometry: uvPort)
        uvPortNode.eulerAngles.z = Float.pi / 2
        uvPortNode.position = SCNVector3(2.6, 0, 0)
        addChildNode(uvPortNode)

        // Labels
        let title = makeText("BBO NONLINEAR CRYSTAL", color: uvColor, size: 0.30)
        title.position = SCNVector3(0.2, 1.75, 0)
        addChildNode(title)
        titleReadout = title

        let pumpLabel = makeText("PUMP LASER", color: pumpColor, size: 0.24)
        pumpLabel.position = SCNVector3(-1.6, 0.6, 0)
        addChildNode(pumpLabel)

        let stageLabel = makeText("ROTATION STAGE", color: .systemYellow, size: 0.24)
        stageLabel.position = SCNVector3(0.0, -1.45, 0.9)
        addChildNode(stageLabel)

        let mirrorLabel = makeText("DICHROIC", color: .systemTeal, size: 0.24)
        mirrorLabel.position = SCNVector3(1.0, 0.7, 0)
        addChildNode(mirrorLabel)

        let dumpLabel = makeText("PUMP DUMP", color: .lightGray, size: 0.22)
        dumpLabel.position = SCNVector3(1.0, -0.5, -1.5)
        addChildNode(dumpLabel)

        let uvLabel = makeText("UV OUT", color: uvColor, size: 0.24)
        uvLabel.position = SCNVector3(2.4, 0.5, 0)
        addChildNode(uvLabel)

        lineOneReadout = makeText("SHG type-I", color: .white, size: 0.26)
        lineOneReadout.position = SCNVector3(0.25, 1.35, 0)
        addChildNode(lineOneReadout)

        lineTwoReadout = makeText("--", color: .white, size: 0.26)
        lineTwoReadout.position = SCNVector3(0.25, 1.05, 0)
        addChildNode(lineTwoReadout)

        setBeamOpacity(pump: 0.15, residual: 0.0, uv: 0.05)
    }

    // MARK: Update

    private func setBeamOpacity(pump: CGFloat, residual: CGFloat, uv: CGFloat) {
        pumpBeam.opacity = pump
        residualBeamX.opacity = residual
        residualBeamZ.opacity = residual
        uvBeam.opacity = uv
    }

    private func setText(_ node: SCNNode, _ string: String, color: UIColor) {
        guard let text = node.geometry as? SCNText else { return }
        text.string = string
        text.firstMaterial?.diffuse.contents = color
        text.firstMaterial?.emission.contents = color
        recenter(node)
    }

    /// Call from the scene controller's `update(state:)`.
    func update(result: BBOConversionResult, running: Bool) {

        // Mechanical: rotate the crystal to the operating angle
        rotor.eulerAngles.y = Float(result.operatingAngleRad)

        let efficiency = result.conversionEfficiency
        let active = running && result.isPhaseMatchable

        if active {
            let uvOpacity = CGFloat(0.05 + 0.95 * efficiency.squareRoot())
            let residualOpacity = CGFloat(0.9 * (1.0 - efficiency))
            setBeamOpacity(pump: 0.9, residual: residualOpacity, uv: uvOpacity)
            crystalNode.geometry?.firstMaterial?.emission.intensity = CGFloat(efficiency)
        } else {
            setBeamOpacity(pump: running ? 0.9 : 0.15, residual: 0.0, uv: 0.05)
            crystalNode.geometry?.firstMaterial?.emission.intensity = 0.0
        }

        let lineOne: String
        let lineTwo: String
        let color: UIColor

        if !result.isPhaseMatchable {
            lineOne = "NOT PHASE-MATCHABLE"
            lineTwo = String(format: "pump %.1f nm", result.pumpWavelengthNm)
            color = .systemRed
        } else if !(result.pumpTransmitted && result.outputTransmitted) {
            lineOne = "OUTSIDE BBO TRANSMISSION"
            lineTwo = String(format: "%.1f nm -> %.1f nm", result.pumpWavelengthNm, result.outputWavelengthNm)
            color = .systemRed
        } else {
            let thetaDeg = (result.phaseMatchAngleRad ?? 0.0) * 180.0 / Double.pi
            let detuneDeg = (result.operatingAngleRad - (result.phaseMatchAngleRad ?? 0.0)) * 180.0 / Double.pi
            lineOne = String(format: "theta_pm %.2f deg  detune %+.3f deg  eta %.1f%%",
                             thetaDeg, detuneDeg, efficiency * 100.0)
            lineTwo = String(format: "%.1f nm -> %.1f nm  (%.4e Hz)",
                             result.pumpWavelengthNm, result.outputWavelengthNm, result.outputFrequencyHz)
            color = efficiency > 0.5 ? .systemGreen : .systemYellow
        }

        if lineOne != lastLineOne {
            lastLineOne = lineOne
            setText(lineOneReadout, lineOne, color: color)
        }

        if lineTwo != lastLineTwo {
            lastLineTwo = lineTwo
            setText(lineTwoReadout, lineTwo, color: color)
        }
    }
}

