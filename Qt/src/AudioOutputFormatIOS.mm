#include "AudioOutputFormat.h"
#import <AVFAudio/AVFAudio.h>

namespace AudioOutputFormat {
SystemFormat systemFormat(const QAudioDevice &device) {
    SystemFormat result;
    if (device.isNull() || !device.isDefault()) {
        return result;
    }
    AVAudioSession *session = [AVAudioSession sharedInstance];
    result.format.setSampleRate(qRound(session.sampleRate));
    result.format.setChannelCount(int(session.outputNumberOfChannels));
    result.status = result.format.sampleRate() > 0 ? 2 : 0;
    // AVAudioSession exposes rate/channels, not the actual PCM sample representation.
    // Leave the format incomplete rather than invent a Float32 device observation.
    return result;
}
} // namespace AudioOutputFormat
