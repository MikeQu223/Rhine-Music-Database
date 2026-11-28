#include "WindowsAudioOutput.h"
#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <ksmedia.h>
#include <avrt.h>
#include <wrl/client.h>
#include <QList>
#include <QtEndian>
#include <algorithm>
#include <bit>
#include <condition_variable>
#include <chrono>
#include <cstring>
#include <mutex>
#include <thread>
#include <utility>

using Microsoft::WRL::ComPtr;
namespace {
struct PcmEncoding {
    QAudioFormat::SampleFormat type;
    WORD containerBits;
    WORD validBits;
    bool operator==(const PcmEncoding &) const = default;
};

struct EventGuard {
    HANDLE value = nullptr;
    ~EventGuard() {
        if (value) {
            CloseHandle(value);
        }
    }
};

WAVEFORMATEXTENSIBLE describe(const QAudioFormat &format, PcmEncoding encoding) {
    WAVEFORMATEXTENSIBLE description{};
    auto &wave = description.Format;
    wave.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    wave.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    wave.nChannels = WORD(format.channelCount());
    wave.wBitsPerSample = encoding.containerBits;
    wave.nBlockAlign = WORD(format.channelCount() * encoding.containerBits / 8);
    wave.nSamplesPerSec = DWORD(format.sampleRate());
    wave.nAvgBytesPerSec = wave.nSamplesPerSec * wave.nBlockAlign;
    description.Samples.wValidBitsPerSample = encoding.validBits;
    auto channels = format.channelConfig();
    if (channels == QAudioFormat::ChannelConfigUnknown && format.channelCount() <= 2) {
        channels = QAudioFormat::defaultChannelConfigForChannelCount(format.channelCount());
    }
    const auto mask = quint32(channels) >> 1;
    description.dwChannelMask = mask <= 0x3ffff ? mask : 0;
    description.SubFormat =
        encoding.type == QAudioFormat::Float ? KSDATAFORMAT_SUBTYPE_IEEE_FLOAT : KSDATAFORMAT_SUBTYPE_PCM;
    return description;
}

QAudioFormat mixPcmFormat(const WAVEFORMATEX &wave, PcmEncoding &encoding) {
    WORD validBits = wave.wBitsPerSample;
    DWORD mask = 0;
    bool floating = wave.wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    bool integer = wave.wFormatTag == WAVE_FORMAT_PCM;
    if (wave.wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
        wave.cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
        const auto &extended = reinterpret_cast<const WAVEFORMATEXTENSIBLE &>(wave);
        validBits = extended.Samples.wValidBitsPerSample;
        mask = extended.dwChannelMask;
        floating = IsEqualGUID(extended.SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
        integer = IsEqualGUID(extended.SubFormat, KSDATAFORMAT_SUBTYPE_PCM);
    }
    const WORD bits = wave.wBitsPerSample;
    QAudioFormat::SampleFormat type = QAudioFormat::Unknown;
    if (floating && bits == 32 && validBits == 32) {
        type = QAudioFormat::Float;
    } else if (integer && bits == 8 && validBits == 8) {
        type = QAudioFormat::UInt8;
    } else if (integer && bits == 16 && validBits == 16) {
        type = QAudioFormat::Int16;
    } else if (integer &&
               ((bits == 24 && validBits == 24) || (bits == 32 && (validBits == 24 || validBits == 32)))) {
        type = QAudioFormat::Int32;
    }
    if (type == QAudioFormat::Unknown || wave.nBlockAlign != wave.nChannels * (bits / 8)) {
        return {};
    }

    QAudioFormat format;
    format.setSampleRate(int(wave.nSamplesPerSec));
    format.setChannelCount(wave.nChannels);
    if (mask <= 0x3ffff && std::popcount(quint32(mask)) == wave.nChannels) {
        format.setChannelConfig(QAudioFormat::ChannelConfig(mask << 1));
    }
    format.setSampleFormat(type);
    encoding = {type, bits, validBits};
    return format;
}

bool rejectedFormat(HRESULT hr) {
    return hr == S_FALSE || hr == AUDCLNT_E_UNSUPPORTED_FORMAT || hr == E_INVALIDARG;
}
}

struct WindowsAudioOutput::State {
    std::thread thread;
    std::mutex mutex;
    std::condition_variable initialized;
    bool ready = false;
    std::atomic<bool> quit{false};
    std::atomic<long> failure{0};
    std::atomic<float> volume{.7f};
    std::atomic<quint64> consumed{0};
    std::atomic<qint64> processed{0};
    std::atomic<int> underruns{0};
    bool paused = false;
    bool finishing = false;
    std::chrono::steady_clock::time_point lastWrite{};
    std::chrono::milliseconds drainDelay{150};
    quint64 lastPcmFrame = 0;
    quint64 generation = 0;
    QAudioFormat format;
    int shareMode = 0;
    int validBits = 0;
    int containerBits = 0;
    QByteArray queue;
    qsizetype read = 0, size = 0;
    ~State() {
        quit = true;
        if (thread.joinable()) {
            thread.join();
        }
    }
    void run(QByteArray deviceId, bool exclusive, QAudioFormat requested, QAudioFormat fallback,
             bool preferSource) {
        const auto com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(com)) {
            failure = com;
            std::lock_guard lock(mutex);
            ready = true;
            initialized.notify_one();
            return;
        }
        // All COM references are released before CoUninitialize, on this thread.
        const auto result = render(deviceId, exclusive, requested, fallback, preferSource);
        failure = result;
        {
            std::lock_guard lock(mutex);
            ready = true;
            initialized.notify_one();
        }
        CoUninitialize();
    }
    HRESULT render(const QByteArray &deviceId, bool exclusive, QAudioFormat requested,
                   const QAudioFormat &fallback, bool preferSource) {
        EventGuard eventGuard;
        ComPtr<IMMDeviceEnumerator> enumerator;
        ComPtr<IMMDevice> device;
        ComPtr<IAudioClient> client;
        ComPtr<IAudioRenderClient> output;
        HRESULT hr =
            CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
        if (FAILED(hr)) {
            return hr;
        }
        const auto id = QString::fromUtf8(deviceId);
        hr = enumerator->GetDevice(reinterpret_cast<LPCWSTR>(id.utf16()), &device);
        if (FAILED(hr)) {
            return hr;
        }
        auto activate = [&] {
            client.Reset();
            return device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                    reinterpret_cast<void **>(client.GetAddressOf()));
        };
        if (FAILED(hr = activate())) {
            return hr;
        }
        if (!requested.isValid()) {
            requested.setSampleRate(48000);
            requested.setChannelConfig(QAudioFormat::ChannelConfigStereo);
            requested.setSampleFormat(QAudioFormat::Float);
        }
        const auto mode = exclusive ? AUDCLNT_SHAREMODE_EXCLUSIVE : AUDCLNT_SHAREMODE_SHARED;
        const DWORD flags =
            AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
            (exclusive ? 0 : AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY);
        REFERENCE_TIME devicePeriod = 1000000; // 100 ms shared buffer tolerates scheduler jitter.
        if (exclusive) {
            if (FAILED(hr = client->GetDevicePeriod(&devicePeriod, nullptr))) {
                return hr;
            }
            // Music playback can spend 40 ms per packet to tolerate scheduling jitter.
            devicePeriod = std::max<REFERENCE_TIME>(devicePeriod, 400000);
        }

        bool attemptedInitialize = false;
        auto initialize = [&](const WAVEFORMATEX &wave, bool exactSharedMix = false) -> HRESULT {
            // A failed Initialize may leave the audio client unusable for the next attempt.
            HRESULT result = S_OK;
            if (attemptedInitialize && FAILED(result = activate())) {
                return result;
            }
            attemptedInitialize = false;
            if (exclusive) {
                const auto supported = client->IsFormatSupported(mode, &wave, nullptr);
                if (supported != S_OK) {
                    return rejectedFormat(supported) ? AUDCLNT_E_UNSUPPORTED_FORMAT : supported;
                }
            }
            attemptedInitialize = true;
            auto period = exactSharedMix ? 0 : devicePeriod;
            result = client->Initialize(mode, exactSharedMix ? AUDCLNT_STREAMFLAGS_EVENTCALLBACK : flags,
                                        period, exclusive ? period : 0, &wave, nullptr);
            if (result == AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED && exclusive) {
                UINT32 aligned = 0;
                if (FAILED(result = client->GetBufferSize(&aligned)) || FAILED(result = activate())) {
                    return result;
                }
                period = (10000000LL * aligned + wave.nSamplesPerSec / 2) / wave.nSamplesPerSec;
                result = client->Initialize(mode, flags, period, period, &wave, nullptr);
            }
            return result;
        };

        QAudioFormat selected = requested;
        const WORD requestedBits = WORD(requested.bytesPerSample() * 8);
        PcmEncoding encoding{requested.sampleFormat(), requestedBits, requestedBits};
        auto description = describe(selected, encoding);
        std::unique_ptr<WAVEFORMATEX, decltype(&CoTaskMemFree)> mix(nullptr, &CoTaskMemFree);
        const WAVEFORMATEX *wireFormat = &description.Format;
        if (!exclusive) {
            if (!preferSource) {
                // Some Qt device profiles omit the current high-rate mix format. Use the
                // live WASAPI format directly and resample PCM before it reaches Windows.
                WAVEFORMATEX *wave = nullptr;
                const auto mixResult = client->GetMixFormat(&wave);
                mix.reset(wave);
                PcmEncoding mixEncoding{};
                const auto mixFormat =
                    SUCCEEDED(mixResult) && mix ? mixPcmFormat(*mix, mixEncoding) : QAudioFormat{};
                if (mixFormat.isValid()) {
                    hr = initialize(*mix, true);
                    if (hr == S_OK) {
                        selected = mixFormat;
                        encoding = mixEncoding;
                        wireFormat = mix.get();
                    } else if (!rejectedFormat(hr)) {
                        return hr;
                    }
                }
            }
            if (wireFormat == &description.Format) {
                hr = initialize(description.Format);
            }
        } else {
            QList<QAudioFormat> targets{requested};
            auto addTarget = [&](QAudioFormat target) {
                if (target.isValid() &&
                    std::none_of(targets.cbegin(), targets.cend(), [&](const auto &other) {
                        return target == other && target.channelConfig() == other.channelConfig();
                    })) {
                    targets.append(target);
                }
            };
            auto stereo = requested;
            stereo.setChannelConfig(QAudioFormat::ChannelConfigStereo);
            if (requested.channelConfig() != QAudioFormat::ChannelConfigUnknown ||
                requested.channelCount() != 2) {
                addTarget(stereo);
            }
            addTarget(fallback);
            if (fallback.isValid()) {
                stereo.setSampleRate(fallback.sampleRate());
                addTarget(stereo);
            }
            for (int rate : {48000, 44100, 96000, 88200, 192000, 176400}) {
                stereo.setSampleRate(rate);
                addTarget(stereo);
            }

            const auto negotiate = [&]() -> HRESULT {
                for (const auto &target : std::as_const(targets)) {
                    const WORD bits = WORD(target.bytesPerSample() * 8);
                    // On source preference, preserve the decoded format when supported.
                    // The system mix may be float even when the endpoint prefers integer PCM.
                    QList<PcmEncoding> candidates{{QAudioFormat::Int32, 32, 24},
                                                  {QAudioFormat::Int32, 24, 24},
                                                  {QAudioFormat::Int32, 32, 32},
                                                  {QAudioFormat::Int16, 16, 16},
                                                  {QAudioFormat::Float, 32, 32}};
                    if (target.sampleFormat() != QAudioFormat::Float ||
                        (preferSource && &target == &targets.constFirst())) {
                        const PcmEncoding exact{target.sampleFormat(), bits, bits};
                        candidates.removeAll(exact);
                        candidates.prepend(exact);
                    }
                    for (const auto &candidate : std::as_const(candidates)) {
                        auto wire = describe(target, candidate);
                        auto result = initialize(wire.Format);
                        const auto mask = wire.dwChannelMask;
                        if (rejectedFormat(result) && candidate.type != QAudioFormat::Float &&
                            candidate.containerBits == candidate.validBits &&
                            (mask == SPEAKER_FRONT_CENTER || mask == KSAUDIO_SPEAKER_STEREO)) {
                            wire.Format.wFormatTag = WAVE_FORMAT_PCM;
                            wire.Format.cbSize = 0;
                            result = initialize(wire.Format);
                        }
                        if (result == S_OK) {
                            selected = target;
                            selected.setSampleFormat(candidate.type);
                            encoding = candidate;
                            description = wire;
                            return result;
                        }
                        if (!rejectedFormat(result)) {
                            return result;
                        }
                    }
                }
                return AUDCLNT_E_UNSUPPORTED_FORMAT;
            };
            hr = negotiate();
        }
        if (FAILED(hr)) {
            return hr;
        }
        const auto &wave = *wireFormat;
        const auto event = eventGuard.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!event) {
            return HRESULT_FROM_WIN32(GetLastError());
        }
        UINT32 frames = 0;
        if (FAILED(hr = client->GetBufferSize(&frames))) {
            return hr;
        }
        if (FAILED(hr = client->SetEventHandle(event))) {
            return hr;
        }
        if (FAILED(hr = client->GetService(IID_PPV_ARGS(&output)))) {
            return hr;
        }
        ComPtr<IAudioClock> clock;
        UINT64 frequency = 0;
        if (FAILED(hr = client->GetService(IID_PPV_ARGS(&clock))) ||
            FAILED(hr = clock->GetFrequency(&frequency)) || frequency == 0) {
            return FAILED(hr) ? hr : E_FAIL;
        }
        const auto pcmFrameBytes = selected.bytesPerFrame();
        const auto pcmBytesPerSecond = qsizetype(selected.sampleRate()) * pcmFrameBytes;
        const auto packetMs = (quint64(frames) * 1000 + wave.nSamplesPerSec - 1) / wave.nSamplesPerSec;
        const auto waitMs = exclusive ? DWORD(std::min<quint64>(packetMs + 10, 100)) : 20;
        const bool packed24 = encoding.containerBits == 24;
        const bool padded24 = encoding.containerBits == 32 && encoding.validBits == 24;
        QByteArray unpacked(packed24 ? qsizetype(frames) * pcmFrameBytes : 0, Qt::Uninitialized);
        {
            std::lock_guard lock(mutex);
            format = selected;
            shareMode = exclusive ? 2 : 1;
            validBits = encoding.validBits;
            containerBits = encoding.containerBits;
            queue.resize(pcmBytesPerSecond * 2);
            drainDelay = std::chrono::milliseconds(packetMs * (exclusive ? 2 : 1) + 20);
            ready = true;
            initialized.notify_one();
        }
        DWORD task = 0;
        HANDLE mmcss = AvSetMmThreadCharacteristicsW(L"Audio", &task);
        struct TaskGuard {
            HANDLE value;
            ~TaskGuard() {
                if (value) {
                    AvRevertMmThreadCharacteristics(value);
                }
            }
        } taskGuard{mmcss};
        bool started = false;
        bool suspended = false;
        bool readyBeforePause = false;
        bool underrunning = false;
        quint64 observed = 0;
        quint64 deviceFrames = 0;
        int unavailablePackets = 0;
        while (!quit) {
            bool renderReady = true;
            if (started) {
                const auto wait = WaitForSingleObject(event, waitMs);
                if (wait != WAIT_OBJECT_0 && wait != WAIT_TIMEOUT) {
                    return HRESULT_FROM_WIN32(GetLastError());
                }
                renderReady = wait == WAIT_OBJECT_0;
            } else {
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            std::lock_guard lock(mutex);
            if (generation != observed) {
                if (started && FAILED(hr = client->Stop())) {
                    return hr;
                }
                if (FAILED(hr = client->Reset())) {
                    return hr;
                }
                started = false;
                suspended = false;
                readyBeforePause = false;
                ResetEvent(event);
                observed = generation;
                processed = 0;
                deviceFrames = 0;
                unavailablePackets = 0;
                underrunning = false;
            }
            if (paused) {
                if (started) {
                    if (FAILED(hr = client->Stop())) {
                        return hr;
                    }
                    started = false;
                    // This wait may already have consumed an exclusive buffer notification.
                    // Preserve that unserviced buffer across Stop/Start.
                    readyBeforePause = exclusive && renderReady;
                    if (!exclusive) {
                        ResetEvent(event);
                    }
                    suspended = true;
                }
                continue;
            }
            if (suspended) {
                if (FAILED(hr = client->Start())) {
                    return hr;
                }
                started = true;
                suspended = false;
                if (!std::exchange(readyBeforePause, false)) {
                    continue;
                }
                renderReady = true;
            }
            UINT64 devicePosition = 0;
            if (SUCCEEDED(clock->GetPosition(&devicePosition, nullptr))) {
                processed = qint64(devicePosition * 1000000 / frequency);
            }
            if ((started && !renderReady) ||
                (!started && (size == 0 || (!finishing && size < std::max(qsizetype(frames) * pcmFrameBytes,
                                                                          pcmBytesPerSecond / 4))))) {
                continue;
            }
            UINT32 available = frames;
            bool underrun = false;
            if (!exclusive) {
                UINT32 padding = 0;
                if (FAILED(hr = client->GetCurrentPadding(&padding))) {
                    return hr;
                }
                available -= std::min(padding, frames);
                underrun = started && padding == 0 && size == 0 && !finishing;
                // Shared mode allows partial packets. Leave queued device audio
                // playing until the decoder supplies the next packet; padding
                // every free frame with silence would insert gaps between packets.
                available = std::min<UINT32>(available, UINT32(size / pcmFrameBytes));
            }
            if (exclusive) {
                underrun = started && size < qsizetype(frames) * pcmFrameBytes && !finishing;
            }
            if (underrun && !underrunning) {
                ++underruns;
            }
            underrunning = underrun;
            if (!available) {
                continue;
            }
            BYTE *destination = nullptr;
            hr = output->GetBuffer(available, &destination);
            if (exclusive && started && hr == AUDCLNT_E_BUFFER_ERROR && ++unavailablePackets < 100) {
                continue;
            }
            if (FAILED(hr)) {
                return hr;
            }
            unavailablePackets = 0;
            auto *pcm = packed24 ? reinterpret_cast<BYTE *>(unpacked.data()) : destination;
            const auto copied = std::min(qsizetype(available) * pcmFrameBytes, size);
            const auto first = std::min(copied, queue.size() - read);
            std::memcpy(pcm, queue.constData() + read, size_t(first));
            std::memcpy(pcm + first, queue.constData(), size_t(copied - first));
            read = (read + copied) % queue.size();
            size -= copied;
            const float gain = volume.load();
            if (format.sampleFormat() == QAudioFormat::Float) {
                auto *samples = reinterpret_cast<float *>(destination);
                for (qsizetype i = 0; i < copied / 4; ++i) {
                    samples[i] *= gain;
                }
            } else if (format.sampleFormat() == QAudioFormat::Int32) {
                if (gain != 1.f || packed24 || padded24) {
                    for (qsizetype i = 0; i < copied / 4; ++i) {
                        const auto sample = qFromLittleEndian<qint32>(pcm + i * 4);
                        const auto scaled = quint32(qint32(double(sample) * gain));
                        // WAVEFORMATEXTENSIBLE stores the valid bits at the high end of the container.
                        if (packed24) {
                            auto *packed = destination + i * 3;
                            packed[0] = BYTE(scaled >> 8);
                            packed[1] = BYTE(scaled >> 16);
                            packed[2] = BYTE(scaled >> 24);
                        } else {
                            qToLittleEndian(padded24 ? scaled & 0xffffff00u : scaled, pcm + i * 4);
                        }
                    }
                }
            } else if (format.sampleFormat() == QAudioFormat::UInt8) {
                for (qsizetype i = 0; i < copied; ++i) {
                    destination[i] = BYTE(128 + (int(destination[i]) - 128) * gain);
                }
            } else {
                auto *samples = reinterpret_cast<qint16 *>(destination);
                for (qsizetype i = 0; i < copied / 2; ++i) {
                    samples[i] = qint16(samples[i] * gain);
                }
            }
            const auto copiedFrames = copied / pcmFrameBytes;
            std::memset(destination + copiedFrames * wave.nBlockAlign,
                        format.sampleFormat() == QAudioFormat::UInt8 ? 128 : 0,
                        size_t((available - copiedFrames) * wave.nBlockAlign));
            if (FAILED(hr = output->ReleaseBuffer(available, copied ? 0 : AUDCLNT_BUFFERFLAGS_SILENT))) {
                return hr;
            }
            consumed += quint64(copiedFrames);
            if (copied) {
                lastWrite = std::chrono::steady_clock::now();
                lastPcmFrame = deviceFrames + quint64(copiedFrames);
            }
            deviceFrames += available;
            if (!started) {
                if (FAILED(hr = client->Start())) {
                    return hr;
                }
                started = true;
            }
        }
        if (started) {
            client->Stop();
        }
        return S_OK;
    }
};
WindowsAudioOutput::WindowsAudioOutput() : state(std::make_unique<State>()) {
}
WindowsAudioOutput::~WindowsAudioOutput() = default;
bool WindowsAudioOutput::open(const QByteArray &id, bool exclusive, const QAudioFormat &requested,
                              const QAudioFormat &fallback, bool preferSource) {
    state->thread = std::thread([s = state.get(), id, exclusive, requested, fallback, preferSource] {
        s->run(id, exclusive, requested, fallback, preferSource);
    });
    std::unique_lock lock(state->mutex);
    state->initialized.wait(lock, [this] { return state->ready; });
    return state->failure == 0 && state->format.isValid();
}
QAudioFormat WindowsAudioOutput::format() const {
    return state->format;
}
int WindowsAudioOutput::shareMode() const {
    return state->shareMode;
}
int WindowsAudioOutput::validBits() const {
    return state->validBits;
}
int WindowsAudioOutput::containerBits() const {
    return state->containerBits;
}
void WindowsAudioOutput::enqueue(const QAudioBuffer &buffer) {
    if (!buffer.isValid() || buffer.format() != state->format) {
        return;
    }
    std::lock_guard lock(state->mutex);
    if (state->paused) {
        return;
    }
    const auto bytes = buffer.byteCount();
    if (bytes > state->queue.size() - state->size) {
        state->failure = AUDCLNT_E_BUFFER_TOO_LARGE;
        return;
    }
    const auto write = (state->read + state->size) % state->queue.size();
    const auto first = std::min<qsizetype>(bytes, state->queue.size() - write);
    std::memcpy(state->queue.data() + write, buffer.constData<char>(), size_t(first));
    std::memcpy(state->queue.data(), buffer.constData<char>() + first, size_t(bytes - first));
    state->size += bytes;
}
void WindowsAudioOutput::reset(bool paused) {
    std::lock_guard lock(state->mutex);
    state->read = state->size = 0;
    state->paused = paused;
    state->finishing = false;
    state->lastPcmFrame = 0;
    ++state->generation;
}
void WindowsAudioOutput::setPaused(bool paused) {
    std::lock_guard lock(state->mutex);
    state->paused = paused;
}
void WindowsAudioOutput::setVolume(float value) {
    state->volume = value;
}
long WindowsAudioOutput::error() const {
    return state->failure;
}
quint64 WindowsAudioOutput::consumedFrames() const {
    return state->consumed;
}
void WindowsAudioOutput::finish() {
    std::lock_guard lock(state->mutex);
    state->finishing = true;
}
bool WindowsAudioOutput::drained() const {
    std::lock_guard lock(state->mutex);
    if (state->size > 0 || std::chrono::steady_clock::now() - state->lastWrite < state->drainDelay) {
        return false;
    }
    // Wait for the device clock to pass the final PCM frame, excluding trailing silence.
    return state->lastPcmFrame == 0 || state->shareMode != 2 ||
           state->processed >= qint64(state->lastPcmFrame * 1000000 / state->format.sampleRate());
}
int WindowsAudioOutput::underrunCount() const {
    return state->underruns;
}
qint64 WindowsAudioOutput::processedUSecs() const {
    return state->processed;
}
qsizetype WindowsAudioOutput::queuedBytes() const {
    std::lock_guard lock(state->mutex);
    return state->size;
}
qsizetype WindowsAudioOutput::bytesFree() const {
    std::lock_guard lock(state->mutex);
    return state->queue.size() - state->size;
}
#endif
