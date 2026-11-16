import SwiftUI

struct SoundPlaybackSettings: View {
    @ObservedObject var audio: AudioEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            trimControl("Sub bass", value: $audio.subBassTrim)
            trimControl("Kick", value: $audio.kickTrim)
            Toggle(AppLocalization.text("Peak limiter"), isOn: $audio.limiterEnabled)
            Text(AppLocalization.text("Limits output peaks after EQ and effects. Hardware Sensory Bass is adjusted on your headphones."))
                .font(.caption2).foregroundStyle(USTheme.secondary)
            Toggle(AppLocalization.text("Match song volume"), isOn: $audio.volumeMatchingEnabled)
            Text(AppLocalization.text("Reduces loud songs using a background RMS estimate. New measurements apply on the next play; quiet songs are not amplified."))
                .font(.caption2).foregroundStyle(USTheme.secondary)
            Button(AppLocalization.text("Reset bass detail")) {
                audio.subBassTrim = 0
                audio.kickTrim = 0
            }
            .font(.caption.bold())
        }
        .tint(USTheme.accent)
    }

    private func trimControl(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(AppLocalization.text(title)).font(.subheadline.bold())
                Spacer()
                Text(String(format: "%+.1f dB", value.wrappedValue)).font(.caption.monospacedDigit())
            }
            Slider(value: value, in: -6...6, step: 0.5)
        }
    }
}
