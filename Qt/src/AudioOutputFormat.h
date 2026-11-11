#pragma once
#include <QAudioDevice>
#include <QAudioFormat>
#include <QByteArray>
#include <functional>

namespace AudioOutputFormat {
enum class Policy { System, Source };
struct SystemFormat {
    QAudioFormat format;
    // 0 = 不可用；1 = 当前系统混音/流格式；2 = 仅采样率与声道数。
    int status = 0;
};
/**
 * 主线程入口：只读取默认标记与设备 id，平台探测转交下面的 id 版本。
 * Qt 6.12 访问 QAudioDevice 的格式可能阻塞数秒，探测线程不得持有该对象。
 */
SystemFormat systemFormat(const QAudioDevice &device);
/** 后台线程入口：只依赖设备 id 与默认标记，不接触 QAudioDevice。 */
SystemFormat systemFormat(const QByteArray &deviceId, bool isDefault);
QAudioFormat select(const QAudioFormat &source, const QAudioFormat &system, const QAudioFormat &preferred,
                    Policy policy, const std::function<bool(const QAudioFormat &)> &supported);
QString describe(int rate, int channels, int sampleFormat);
} // namespace AudioOutputFormat
