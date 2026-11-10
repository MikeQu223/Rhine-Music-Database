#include "AudioOutputFormat.h"
#import <AVFAudio/AVFAudio.h>

namespace AudioOutputFormat {
SystemFormat systemFormat(const QByteArray &deviceId, bool isDefault) {
    SystemFormat result;
    if (!isDefault) {
        return result;
    }
    // AVAudioSession 是进程级会话，没有可按设备区分的入口。
    Q_UNUSED(deviceId);
    AVAudioSession *session = [AVAudioSession sharedInstance];
    result.format.setSampleRate(qRound(session.sampleRate));
    result.format.setChannelCount(int(session.outputNumberOfChannels));
    result.status = result.format.sampleRate() > 0 ? 2 : 0;
    // AVAudioSession 只暴露采样率与声道数，不给出 PCM 表示；
    // 这里保留不完整格式，不凭空编造 Float32 设备观测。
    return result;
}

SystemFormat systemFormat(const QAudioDevice &device) {
    if (device.isNull() || !device.isDefault()) {
        return {};
    }
    return systemFormat(device.id(), true);
}
} // namespace AudioOutputFormat
