#include "AudioSpectrum.h"
#include <algorithm>
#include <cmath>
#include <complex>
#include <numbers>

void AudioSpectrum::reset() {
    m_count = m_rate = m_channels = 0;
    m_levels.fill(0);
}

bool AudioSpectrum::consume(const QAudioBuffer &buffer) {
    const auto format = buffer.format();
    if (!buffer.isValid() || format.channelCount() < 1 || format.sampleRate() < 1) {
        return false;
    }
    if (format.sampleRate() != m_rate || std::min(2, format.channelCount()) != m_channels) {
        reset();
        m_rate = format.sampleRate();
        m_channels = std::min(2, format.channelCount());
    }
    bool produced = false;
    for (int frame = 0; frame < buffer.frameCount(); ++frame) {
        for (int channel = 0; channel < m_channels; ++channel) {
            const auto index = frame * format.channelCount() + channel;
            double value = 0;
            switch (format.sampleFormat()) {
            case QAudioFormat::UInt8:
                value = (buffer.constData<quint8>()[index] - 128.) / 128.;
                break;
            case QAudioFormat::Int16:
                value = buffer.constData<qint16>()[index] / 32768.;
                break;
            case QAudioFormat::Int32:
                value = buffer.constData<qint32>()[index] / 2147483648.;
                break;
            case QAudioFormat::Float:
                value = buffer.constData<float>()[index];
                break;
            default:
                return false;
            }
            m_samples[channel][m_count] = std::isfinite(value) ? std::clamp(value, -1., 1.) : 0;
        }
        if (++m_count == Size) {
            transform();
            produced = true;
            m_count = 0;
        }
    }
    return produced;
}

void AudioSpectrum::transform() {
    std::array<double, Size / 2> power{};
    for (int channel = 0; channel < m_channels; ++channel) {
        std::array<std::complex<double>, Size> data;
        for (int i = 0; i < Size; ++i) {
            data[i] = m_samples[channel][i] * (0.5 - 0.5 * std::cos(2 * std::numbers::pi * i / (Size - 1)));
        }
        for (int i = 1, j = 0; i < Size; ++i) {
            int bit = Size >> 1;
            for (; j & bit; bit >>= 1) {
                j ^= bit;
            }
            j ^= bit;
            if (i < j) {
                std::swap(data[i], data[j]);
            }
        }
        for (int length = 2; length <= Size; length <<= 1) {
            const auto step = std::polar(1., -2 * std::numbers::pi / length);
            for (int start = 0; start < Size; start += length) {
                std::complex<double> rotation = 1;
                for (int i = 0; i < length / 2; ++i) {
                    const auto even = data[start + i];
                    const auto odd = data[start + i + length / 2] * rotation;
                    data[start + i] = even + odd;
                    data[start + i + length / 2] = even - odd;
                    rotation *= step;
                }
            }
        }
        for (int i = 1; i < Size / 2; ++i) {
            power[i] += std::norm(data[i] * (4. / Size)) / m_channels;
        }
    }
    const auto upper = std::min(16000., m_rate / 2.);
    for (int band = 0; band < Bands; ++band) {
        const auto low = 35 * std::pow(upper / 35, double(band) / Bands);
        const auto high = 35 * std::pow(upper / 35, double(band + 1) / Bands);
        const int first = std::clamp(qRound(low * Size / m_rate), 1, Size / 2 - 1);
        const int last = std::clamp(std::max(first + 1, qRound(high * Size / m_rate)), first + 1, Size / 2);
        double energy = 0;
        for (int i = first; i < last; ++i) {
            energy += power[i];
        }
        const auto decibels = 10 * std::log10(std::max(1e-12, energy / (last - first)));
        m_levels[band] = std::clamp((decibels + 72) / 66, 0., 1.);
    }
}

QJsonArray AudioSpectrum::levels() const {
    QJsonArray result;
    for (double value : m_levels) {
        result.append(std::round(value * 1000) / 1000);
    }
    return result;
}
