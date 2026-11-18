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
#include <algorithm>
#include <condition_variable>
#include <chrono>
#include <cstring>
#include <mutex>
#include <thread>

using Microsoft::WRL::ComPtr;
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
    quint64 generation = 0;
    QAudioFormat format;
    QByteArray queue;
    qsizetype read = 0, size = 0;
    ~State() {
        quit = true;
        if (thread.joinable()) {
            thread.join();
        }
    }
    void run(QByteArray deviceId, bool exclusive, QAudioFormat requested) {
        const auto com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        if (FAILED(com)) {
            failure = com;
            std::lock_guard lock(mutex);
            ready = true;
            initialized.notify_one();
            return;
        }
        // All COM references are released before CoUninitialize, on this thread.
        const auto result = render(deviceId, exclusive, requested);
        failure = result;
        {
            std::lock_guard lock(mutex);
            ready = true;
            initialized.notify_one();
        }
        CoUninitialize();
    }
    HRESULT render(const QByteArray &deviceId, bool exclusive, const QAudioFormat &requested) {
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
            return device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                    reinterpret_cast<void **>(client.GetAddressOf()));
        };
        if (FAILED(hr = activate())) {
            return hr;
        }
        WAVEFORMATEXTENSIBLE description{};
        auto &wave = description.Format;
        QAudioFormat selected = requested;
        if (!selected.isValid()) {
            selected.setSampleRate(48000);
            selected.setChannelConfig(QAudioFormat::ChannelConfigStereo);
            selected.setSampleFormat(QAudioFormat::Float);
        }
        auto describe = [&] {
            wave.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
            wave.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
            wave.nChannels = WORD(selected.channelCount());
            wave.wBitsPerSample = WORD(selected.bytesPerSample() * 8);
            wave.nBlockAlign = WORD(selected.bytesPerFrame());
            wave.nSamplesPerSec = DWORD(selected.sampleRate());
            wave.nAvgBytesPerSec = wave.nSamplesPerSec * wave.nBlockAlign;
            description.Samples.wValidBitsPerSample = wave.wBitsPerSample;
            description.dwChannelMask = (quint32(selected.channelConfig()) >> 1) & 0x3ffff;
            description.SubFormat = selected.sampleFormat() == QAudioFormat::Float
                                        ? KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
                                        : KSDATAFORMAT_SUBTYPE_PCM;
        };
        describe();
        const auto mode = exclusive ? AUDCLNT_SHAREMODE_EXCLUSIVE : AUDCLNT_SHAREMODE_SHARED;
        if (exclusive && client->IsFormatSupported(mode, &wave, nullptr) != S_OK) {
            bool supported = false;
            // Preserve the selected rate/layout first, then negotiate a portable stereo fallback.
            for (auto type : {QAudioFormat::Float, QAudioFormat::Int32, QAudioFormat::Int16}) {
                selected.setSampleFormat(type);
                describe();
                if (client->IsFormatSupported(mode, &wave, nullptr) == S_OK) {
                    supported = true;
                    break;
                }
            }
            if (!supported) {
                selected.setChannelConfig(QAudioFormat::ChannelConfigStereo);
                for (auto type : {QAudioFormat::Float, QAudioFormat::Int32, QAudioFormat::Int16}) {
                    selected.setSampleFormat(type);
                    for (int rate : {48000, 44100, 96000, 192000}) {
                        selected.setSampleRate(rate);
                        describe();
                        if (client->IsFormatSupported(mode, &wave, nullptr) == S_OK) {
                            supported = true;
                            break;
                        }
                    }
                    if (supported) {
                        break;
                    }
                }
            }
            if (!supported) {
                return AUDCLNT_E_UNSUPPORTED_FORMAT;
            }
        }
        HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!event) {
            return HRESULT_FROM_WIN32(GetLastError());
        }
        struct EventGuard {
            HANDLE value;
            ~EventGuard() {
                CloseHandle(value);
            }
        } eventGuard{event};
        const DWORD flags =
            AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
            (exclusive ? 0 : AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY);
        REFERENCE_TIME period = 1000000; // 100 ms device buffer tolerates scheduler jitter.
        if (exclusive) {
            REFERENCE_TIME minimum = 0;
            if (FAILED(hr = client->GetDevicePeriod(&period, &minimum))) {
                return hr;
            }
            period = std::max<REFERENCE_TIME>(period, 100000);
        }
        hr = client->Initialize(mode, flags, period, exclusive ? period : 0, &wave, nullptr);
        if (hr == AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED && exclusive) {
            UINT32 aligned = 0;
            if (FAILED(hr = client->GetBufferSize(&aligned))) {
                return hr;
            }
            period = (10000000LL * aligned + wave.nSamplesPerSec / 2) / wave.nSamplesPerSec;
            client.Reset();
            if (FAILED(hr = activate())) {
                return hr;
            }
            hr = client->Initialize(mode, flags, period, period, &wave, nullptr);
        }
        if (FAILED(hr)) {
            return hr;
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
        {
            std::lock_guard lock(mutex);
            format = selected;
            queue.resize(wave.nAvgBytesPerSec * 2);
            drainDelay = std::chrono::milliseconds((quint64(frames) * 1000 + wave.nSamplesPerSec - 1) /
                                                       wave.nSamplesPerSec * (exclusive ? 2 : 1) +
                                                   20);
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
        bool underrunning = false;
        quint64 observed = 0;
        while (!quit) {
            if (started) {
                const auto wait = WaitForSingleObject(event, 20);
                if (wait == WAIT_TIMEOUT) {
                    continue;
                }
                if (wait != WAIT_OBJECT_0) {
                    return HRESULT_FROM_WIN32(GetLastError());
                }
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
                observed = generation;
                processed = 0;
            }
            if (paused) {
                if (started) {
                    if (FAILED(hr = client->Stop())) {
                        return hr;
                    }
                    started = false;
                    ResetEvent(event);
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
                continue;
            }
            UINT64 devicePosition = 0;
            if (SUCCEEDED(clock->GetPosition(&devicePosition, nullptr))) {
                processed = qint64(devicePosition * 1000000 / frequency);
            }
            if ((!started &&
                 (size == 0 || (!finishing && size < std::max<qsizetype>(frames * wave.nBlockAlign,
                                                                         wave.nAvgBytesPerSec / 4))))) {
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
                available = std::min<UINT32>(available, UINT32(size / wave.nBlockAlign));
            }
            if (exclusive) {
                underrun = started && size < qsizetype(frames * wave.nBlockAlign) && !finishing;
            }
            if (underrun && !underrunning) {
                ++underruns;
            }
            underrunning = underrun;
            if (!available) {
                continue;
            }
            BYTE *destination = nullptr;
            if (FAILED(hr = output->GetBuffer(available, &destination))) {
                return hr;
            }
            const auto bytes = qsizetype(available * wave.nBlockAlign);
            const auto copied = std::min(bytes, size);
            const auto first = std::min(copied, queue.size() - read);
            std::memcpy(destination, queue.constData() + read, size_t(first));
            std::memcpy(destination + first, queue.constData(), size_t(copied - first));
            std::memset(destination + copied, format.sampleFormat() == QAudioFormat::UInt8 ? 128 : 0,
                        size_t(bytes - copied));
            read = (read + copied) % queue.size();
            size -= copied;
            const float gain = volume.load();
            if (format.sampleFormat() == QAudioFormat::Float) {
                auto *samples = reinterpret_cast<float *>(destination);
                for (qsizetype i = 0; i < copied / 4; ++i) {
                    samples[i] *= gain;
                }
            } else if (format.sampleFormat() == QAudioFormat::Int32) {
                auto *samples = reinterpret_cast<qint32 *>(destination);
                if (gain != 1.f) {
                    for (qsizetype i = 0; i < copied / 4; ++i) {
                        samples[i] = qint32(double(samples[i]) * gain);
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
            consumed += quint64(copied / wave.nBlockAlign);
            if (copied) {
                lastWrite = std::chrono::steady_clock::now();
            }
            if (FAILED(hr = output->ReleaseBuffer(available, copied ? 0 : AUDCLNT_BUFFERFLAGS_SILENT))) {
                return hr;
            }
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
bool WindowsAudioOutput::open(const QByteArray &id, bool exclusive, const QAudioFormat &requested) {
    state->thread =
        std::thread([s = state.get(), id, exclusive, requested] { s->run(id, exclusive, requested); });
    std::unique_lock lock(state->mutex);
    state->initialized.wait(lock, [this] { return state->ready; });
    return state->failure == 0 && state->format.isValid();
}
QAudioFormat WindowsAudioOutput::format() const {
    return state->format;
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
    return state->size == 0 && std::chrono::steady_clock::now() - state->lastWrite >= state->drainDelay;
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
