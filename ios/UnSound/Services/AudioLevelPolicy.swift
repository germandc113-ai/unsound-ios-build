import Foundation

enum AudioLevelPolicy {
    /// Attenuation-only RMS matching: never amplify a quiet file or silence.
    /// This is deliberately not advertised as an EBU R128/LUFS measurement.
    static func matchingGainDB(rms: Double) -> Double {
        guard rms.isFinite, rms > 0.00001 else { return 0 }
        return min(0, max(-18, -18 - 20 * log10(rms)))
    }

    static func clampedTrim(_ value: Double) -> Double {
        value.isFinite ? min(6, max(-6, value)) : 0
    }
}
