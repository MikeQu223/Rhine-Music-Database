#include "AudioResampler.h"
#include <QCoreApplication>
#include <QDir>
#include <QLibrary>
#include <QLibraryInfo>
#include <algorithm>

namespace {
struct SwrContext;
struct Api {
    QLibrary swr, util;
    SwrContext *(*alloc)() = nullptr;
    void (*free)(SwrContext **) = nullptr;
    int (*init)(SwrContext *) = nullptr;
    int (*convert)(SwrContext *, unsigned char **, int, const unsigned char **, int) = nullptr;
    int (*count)(SwrContext *, int) = nullptr;
    int (*option)(void *, const char *, const char *, int) = nullptr;
    int (*integer)(void *, const char *, qint64, int) = nullptr;
    bool ready = false;

    Api() {
        const auto executable = QCoreApplication::applicationDirPath();
        const QStringList directories{executable,
                                      executable + "/Frameworks",
                                      executable + "/../Frameworks",
                                      executable + "/../../../Frameworks",
                                      executable + "/../lib",
                                      QLibraryInfo::path(QLibraryInfo::LibrariesPath),
                                      QLibraryInfo::path(QLibraryInfo::LibraryExecutablesPath)};
        // Resolve a matching pair in one deployment directory, never mix a random
        // system libavutil with the Qt-bundled libswresample. Qt 6.12 kits currently
        // ship FFmpeg 9; also accept the ABI pairs from FFmpeg 6/7/8.
        for (const auto &directory : directories) {
            for (int major = 7; major >= 4; --major) {
#ifdef Q_OS_IOS
                const auto swrName = QStringLiteral("libswresample.framework");
                const auto utilName = QStringLiteral("libavutil.framework");
#elif defined(Q_OS_WIN)
                const auto swrName = QStringLiteral("swresample-%1.dll").arg(major);
                const auto utilName = QStringLiteral("avutil-%1.dll").arg(major + 54);
#elif defined(Q_OS_DARWIN)
                const auto swrName = QStringLiteral("libswresample.%1*.dylib").arg(major);
                const auto utilName = QStringLiteral("libavutil.%1*.dylib").arg(major + 54);
#else
                const auto swrName = QStringLiteral("libswresample.so.%1*").arg(major);
                const auto utilName = QStringLiteral("libavutil.so.%1*").arg(major + 54);
#endif
                QDir dir(directory);
                const auto swrFiles =
                    dir.entryList({swrName}, QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot);
                const auto utilFiles =
                    dir.entryList({utilName}, QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot);
                if (swrFiles.isEmpty() || utilFiles.isEmpty()) {
                    continue;
                }
#ifdef Q_OS_IOS
                util.setFileName(dir.absoluteFilePath(utilFiles.first()) + "/libavutil");
                swr.setFileName(dir.absoluteFilePath(swrFiles.first()) + "/libswresample");
#else
                util.setFileName(dir.absoluteFilePath(utilFiles.first()));
                swr.setFileName(dir.absoluteFilePath(swrFiles.first()));
#endif
                if (!util.load() || !swr.load()) {
                    swr.unload();
                    util.unload();
                    continue;
                }
                const auto swrVersion = reinterpret_cast<unsigned (*)()>(swr.resolve("swresample_version"));
                const auto utilVersion = reinterpret_cast<unsigned (*)()>(util.resolve("avutil_version"));
                if (!swrVersion || !utilVersion || (swrVersion() >> 16) + 54 != (utilVersion() >> 16)) {
                    swr.unload();
                    util.unload();
                    continue;
                }
                alloc = reinterpret_cast<decltype(alloc)>(swr.resolve("swr_alloc"));
                free = reinterpret_cast<decltype(free)>(swr.resolve("swr_free"));
                init = reinterpret_cast<decltype(init)>(swr.resolve("swr_init"));
                convert = reinterpret_cast<decltype(convert)>(swr.resolve("swr_convert"));
                count = reinterpret_cast<decltype(count)>(swr.resolve("swr_get_out_samples"));
                option = reinterpret_cast<decltype(option)>(util.resolve("av_opt_set"));
                integer = reinterpret_cast<decltype(integer)>(util.resolve("av_opt_set_int"));
                ready = alloc && free && init && convert && count && option && integer;
                if (ready) {
                    return;
                }
                swr.unload();
                util.unload();
            }
        }
    }
};
Api &api() {
    static Api instance;
    return instance;
}

int sampleType(QAudioFormat::SampleFormat type) {
    // AV_SAMPLE_FMT_U8/S16/S32/FLT are stable public enum values, interleaved.
    switch (type) {
    case QAudioFormat::UInt8:
        return 0;
    case QAudioFormat::Int16:
        return 1;
    case QAudioFormat::Int32:
        return 2;
    case QAudioFormat::Float:
        return 3;
    default:
        return -1;
    }
}
QByteArray layout(const QAudioFormat &format) {
    // Qt positions (starting at bit 1) follow AV_CHAN order. Preserve known
    // speaker positions; unknown layouts use FFmpeg's default for N channels.
    const auto mask = quint32(format.channelConfig());
    quint64 native = 0;
    for (int position = 1; position < QAudioFormat::NChannelPositions; ++position) {
        const int avPosition = position <= 18 ? position - 1 : position + 16;
        if (mask & (1u << position)) {
            native |= quint64(1) << avPosition;
        }
    }
    return mask ? "0x" + QByteArray::number(native, 16) : QByteArray::number(format.channelCount()) + "c";
}
}

struct AudioResampler::Impl {
    QAudioFormat input, output;
    SwrContext *context = nullptr;
    bool direct = false, dither = false;
    ~Impl() {
        if (context) {
            api().free(&context);
        }
    }
    bool run(const unsigned char **data, int frames, QByteArray &result) {
        const int capacity = api().count(context, frames);
        if (capacity < 0 || qint64(capacity) * output.bytesPerFrame() > 16 * 1024 * 1024) {
            return false;
        }
        result.resize(capacity * output.bytesPerFrame());
        auto *destination = reinterpret_cast<unsigned char *>(result.data());
        const int written = api().convert(context, &destination, capacity, data, frames);
        if (written < 0) {
            return false;
        }
        result.resize(written * output.bytesPerFrame());
        return true;
    }
};

AudioResampler::AudioResampler() : d(std::make_unique<Impl>()) {
}
AudioResampler::~AudioResampler() = default;
bool AudioResampler::available() {
    return api().ready;
}
bool AudioResampler::bypass() const {
    return d->direct;
}
bool AudioResampler::dithering() const {
    return d->dither;
}
bool AudioResampler::configure(const QAudioFormat &input, const QAudioFormat &output) {
    if (!input.isValid() || !output.isValid() || input.channelCount() > 32 || output.channelCount() > 32) {
        return false;
    }
    auto next = std::make_unique<Impl>();
    next->input = input;
    next->output = output;
    next->direct = input == output;
    if (next->direct) {
        d = std::move(next);
        return true;
    }
    auto &lib = api();
    if (!lib.ready) {
        return false;
    }
    next->context = lib.alloc();
    if (!next->context) {
        return false;
    }
    auto *ctx = next->context;
    next->dither =
        (output.sampleFormat() == QAudioFormat::Int16 || output.sampleFormat() == QAudioFormat::UInt8) &&
        (input.sampleFormat() == QAudioFormat::Float || input.bytesPerSample() > output.bytesPerSample());
    if (lib.option(ctx, "in_chlayout", layout(input).constData(), 0) < 0 ||
        lib.option(ctx, "out_chlayout", layout(output).constData(), 0) < 0 ||
        lib.integer(ctx, "in_sample_rate", input.sampleRate(), 0) < 0 ||
        lib.integer(ctx, "out_sample_rate", output.sampleRate(), 0) < 0 ||
        lib.integer(ctx, "in_sample_fmt", sampleType(input.sampleFormat()), 0) < 0 ||
        lib.integer(ctx, "out_sample_fmt", sampleType(output.sampleFormat()), 0) < 0 ||
        lib.integer(ctx, "filter_size", 64, 0) < 0 ||
        lib.integer(ctx, "dither_method", next->dither ? 2 : 0, 0) < 0 || lib.init(ctx) < 0) {
        return false;
    }
    d = std::move(next);
    return true;
}
bool AudioResampler::convert(const QAudioBuffer &input, QByteArray &output) {
    output.clear();
    if (!input.isValid() || input.format() != d->input) {
        return false;
    }
    if (d->direct) {
        output = QByteArray(input.constData<char>(), input.byteCount());
        return true;
    }
    if (!d->context) {
        return false;
    }
    const auto *data = input.constData<unsigned char>();
    return d->run(&data, input.frameCount(), output);
}
bool AudioResampler::finish(QByteArray &output) {
    output.clear();
    if (d->direct) {
        return true;
    }
    if (!d->context) {
        return false;
    }
    // Null input flushes the FIR delay; include the last samples before EOF.
    QByteArray tail;
    for (int i = 0; i < 16; ++i) {
        if (!d->run(nullptr, 0, tail)) {
            return false;
        }
        if (tail.isEmpty()) {
            return true;
        }
        output += tail;
    }
    return false;
}
