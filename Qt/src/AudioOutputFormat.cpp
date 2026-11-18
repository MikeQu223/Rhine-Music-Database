#include "AudioOutputFormat.h"
#include <QtGlobal>
#ifdef Q_OS_MACOS
#include <CoreAudio/CoreAudio.h>
#endif
#ifdef Q_OS_WIN
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <ksmedia.h>
#include <wrl/client.h>
#endif

namespace AudioOutputFormat {
QAudioFormat select(const QAudioFormat &source, const QAudioFormat &system, const QAudioFormat &preferred,
                    Policy policy, const std::function<bool(const QAudioFormat &)> &supported) {
    if (!source.isValid()) {
        return {};
    }
    // 逐个候选组合实测；设备的 min/max 区间不是格式矩阵。
    if (policy == Policy::Source && supported(source)) {
        return source;
    }
    auto observed = system;
    if (observed.sampleRate() > 0 && !observed.isValid()) {
        observed = source;
        observed.setSampleRate(system.sampleRate());
        observed.setSampleFormat(QAudioFormat::Float);
    }
    for (auto candidate : {observed, preferred}) {
        if (!candidate.isValid()) {
            continue;
        }
        // 端点接受原声道布局时保持单/双声道语义；不因为系统配了环绕声就把音乐上混。
        auto channels = candidate;
        channels.setChannelConfig(source.channelConfig());
        if (source.channelConfig() == QAudioFormat::ChannelConfigUnknown) {
            channels.setChannelCount(source.channelCount());
        }
        auto floating = channels;
        floating.setSampleFormat(QAudioFormat::Float);
        if (supported(floating)) {
            return floating;
        }
        if (supported(channels)) {
            return channels;
        }
        if (supported(candidate)) {
            return candidate;
        }
    }
    return supported(source) ? source : QAudioFormat{};
}

QString describe(int rate, int channels, int sampleFormat) {
    if (rate <= 0 || channels <= 0 || sampleFormat <= 0) {
        return QStringLiteral("未知 / 未打开");
    }
    QString type;
    switch (QAudioFormat::SampleFormat(sampleFormat)) {
    case QAudioFormat::UInt8:
        type = "UInt8";
        break;
    case QAudioFormat::Int16:
        type = "Int16";
        break;
    case QAudioFormat::Int32:
        type = QStringLiteral("Int32 容器");
        break;
    case QAudioFormat::Float:
        type = "Float32";
        break;
    default:
        return QStringLiteral("未知格式");
    }
    return QStringLiteral("%1 Hz / %2 / %3 声道").arg(rate).arg(type).arg(channels);
}

#ifndef Q_OS_IOS
SystemFormat systemFormat(const QByteArray &deviceId, bool isDefault) {
    SystemFormat result;
    if (!isDefault) {
        return result;
    }
#ifdef Q_OS_MACOS
    // CoreAudio 只能查询系统默认端点，设备 id 在这里用不上。
    Q_UNUSED(deviceId);
    AudioDeviceID endpoint = kAudioObjectUnknown;
    UInt32 size = sizeof(endpoint);
    AudioObjectPropertyAddress address{kAudioHardwarePropertyDefaultOutputDevice,
                                       kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, &endpoint) !=
        noErr) {
        return result;
    }
    AudioStreamBasicDescription stream{};
    size = sizeof(stream);
    address = {kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeOutput,
               kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(endpoint, &address, 0, nullptr, &size, &stream) != noErr ||
        stream.mFormatID != kAudioFormatLinearPCM) {
        return result;
    }
    auto &format = result.format;
    format.setSampleRate(qRound(stream.mSampleRate));
    format.setChannelCount(int(stream.mChannelsPerFrame));
    if (stream.mFormatFlags & kAudioFormatFlagIsFloat) {
        format.setSampleFormat(stream.mBitsPerChannel == 32 ? QAudioFormat::Float : QAudioFormat::Unknown);
    } else if (stream.mBitsPerChannel == 16) {
        format.setSampleFormat(QAudioFormat::Int16);
    } else if (stream.mBitsPerChannel > 16 && stream.mBitsPerChannel <= 32 &&
               stream.mBytesPerFrame >= 4 * ((stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved)
                                                 ? 1u
                                                 : stream.mChannelsPerFrame)) {
        // 打包 24 位没有对应的 QAudioFormat，只有观测到四字节容器时才报告 Int32。
        format.setSampleFormat(QAudioFormat::Int32);
    }
    // 这是 HAL 流格式观测，不是 QAudioSink 客户端格式或 DAC 格式。
    result.status = format.isValid() ? 1 : format.sampleRate() > 0 ? 2 : 0;
#elif defined(Q_OS_WIN)
    using Microsoft::WRL::ComPtr;
    // 工作线程自行初始化 MTA；COM 指针全部在 CoUninitialize 之前释放。
    const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    {
        ComPtr<IMMDeviceEnumerator> enumerator;
        ComPtr<IMMDevice> endpoint;
        ComPtr<IAudioClient> client;
        if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                       IID_PPV_ARGS(&enumerator))) &&
            SUCCEEDED(enumerator->GetDevice(reinterpret_cast<LPCWSTR>(QString::fromUtf8(deviceId).utf16()),
                                            &endpoint)) &&
            SUCCEEDED(endpoint->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                         reinterpret_cast<void **>(client.GetAddressOf())))) {
            WAVEFORMATEX *mix = nullptr;
            if (SUCCEEDED(client->GetMixFormat(&mix))) {
                auto &format = result.format;
                format.setSampleRate(int(mix->nSamplesPerSec));
                format.setChannelCount(int(mix->nChannels));
                bool floating = mix->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
                if (mix->wFormatTag == WAVE_FORMAT_EXTENSIBLE && mix->cbSize >= 22) {
                    floating = IsEqualGUID(reinterpret_cast<WAVEFORMATEXTENSIBLE *>(mix)->SubFormat,
                                           KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
                }
                format.setSampleFormat(floating && mix->wBitsPerSample == 32 ? QAudioFormat::Float
                                       : mix->wBitsPerSample == 16           ? QAudioFormat::Int16
                                       : mix->wBitsPerSample == 32           ? QAudioFormat::Int32
                                                                             : QAudioFormat::Unknown);
                result.status = format.isValid() ? 1 : format.sampleRate() > 0 ? 2 : 0;
                CoTaskMemFree(mix);
            }
        }
    }
    if (SUCCEEDED(initialized)) {
        CoUninitialize();
    }
#else
    Q_UNUSED(deviceId);
#endif
    return result;
}

SystemFormat systemFormat(const QAudioDevice &device) {
    if (device.isNull() || !device.isDefault()) {
        return {};
    }
    return systemFormat(device.id(), true);
}
#endif
} // namespace AudioOutputFormat
