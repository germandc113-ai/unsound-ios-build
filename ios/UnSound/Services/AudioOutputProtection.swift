import AVFoundation
import AudioToolbox

enum AudioOutputProtection {
    static func makeLimiter() -> AVAudioUnitEffect {
        let unit = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        ))
        AudioUnitSetParameter(unit.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
        return unit
    }
}
