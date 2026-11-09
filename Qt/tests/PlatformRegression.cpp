#include "AppStorage.h"
#include "AudioPlayer.h"
#include <QAudioBuffer>
#include <QJsonDocument>
#include <QJsonArray>
#include "ProcessMetrics.h"
#include <QCoreApplication>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QGuiApplication>
#include <QTemporaryDir>
#include <QThread>
#include <QtMultimedia/private/qaudiodevice_p.h>
#include <atomic>
#include <cstdio>
#include <functional>
#include <memory>
#include <thread>
#include <type_traits>
#ifdef Q_OS_LINUX
#include <sys/stat.h>
#endif
#if defined(Q_OS_WIN) || defined(Q_OS_LINUX)
#include "Host.h"
#endif

namespace {
bool check(bool result, const char *message) {
    if (!result) {
        // 部分发行版默认过滤 Qt 日志类别，CTest 只看得到标准错误，因此直接写入。
        std::fprintf(stderr, "%s\n", message);
    }
    return result;
}

bool waitFor(const std::function<bool()> &ready, int milliseconds = 5000) {
    QElapsedTimer clock;
    clock.start();
    while (!ready() && clock.elapsed() < milliseconds) {
        QCoreApplication::processEvents();
        QThread::msleep(1);
    }
    return ready();
}

bool processMetricsRegression() {
    const auto first = readProcessMetrics();
    const auto second = readProcessMetrics();
    bool ok = check(first.residentBytes > 0 && second.residentBytes > 0,
                    "Current process resident memory is available");
    ok &= check(first.cpuNanoseconds >= 0 && second.cpuNanoseconds >= first.cpuNanoseconds,
                "Cumulative process CPU time is available and monotonic");
    return ok;
}

// 测试只生成设备描述符，不创建硬件音频流；覆盖 Qt 6.8 和新版私有描述符结构。
template <typename DevicePrivate> QAudioDevice testDevice(const QByteArray &id) {
    if constexpr (std::is_constructible_v<DevicePrivate, QByteArray, QAudioDevice::Mode, QString>) {
        return (new DevicePrivate(id, QAudioDevice::Output, QString::fromUtf8(id)))->create();
    } else {
        typename DevicePrivate::AudioDeviceFormat format;
        return DevicePrivate::createQAudioDevice(
            std::make_unique<DevicePrivate>(id, QAudioDevice::Output, QString::fromUtf8(id), true, format));
    }
}

bool storageRegression(const QString &directory) {
    const auto first = directory + "/便携应用 A";
    bool ok = check(AppStorage::initializePortable(first).isEmpty(), "Portable directory initialization");
    ok &= check(AppStorage::dataDirectory() == first + "/data", "Data follows application directory");
    ok &= check(AppStorage::cacheDirectory() == first + "/data/cache", "Cache stays in portable data");
    ok &= check(AppStorage::temporaryDirectory() == first + "/data/temp", "Temporary files stay portable");
    ok &= check(qEnvironmentVariable("QML_DISK_CACHE_PATH") == first + "/data/cache/qml",
                "QML cache stays portable");
    ok &= check(QDir::fromNativeSeparators(qEnvironmentVariable("TEMP")) == first + "/data/temp",
                "Runtime temporary environment stays portable");
    {
        auto settings = AppStorage::settings();
        settings.setValue("panel/volume", "0.42");
        settings.setValue("panel/search-history", QStringLiteral("中文搜索"));
        settings.sync();
        ok &= check(settings.status() == QSettings::NoError, "Portable preferences saved");
        ok &=
            check(settings.format() == QSettings::IniFormat, "Preferences never use native registry format");
        ok &=
            check(settings.fileName() == first + "/data/settings.ini", "Preferences stay beside application");
    }
    ok &= check(AppStorage::settings().value("panel/volume").toString() == "0.42",
                "Preferences survive reopening");
    {
        QTemporaryDir worker(AppStorage::temporaryDirectory() + "/worker-XXXXXX");
        ok &= check(worker.isValid() && worker.path().startsWith(first + "/data/temp/"),
                    "Worker temporary directories stay portable");
    }
#ifdef Q_OS_WIN
    const QByteArray credential("offline-credential-fixture");
    ok &= check(platformSaveCredential(credential).isEmpty(), "DPAPI credential saved locally");
    ok &= check(QFile::exists(first + "/data/account.dpapi"), "Credential file stays portable");
    ok &= check(platformCredential() == credential, "DPAPI credential round trip");
    platformDeleteCredential();
    ok &= check(!QFile::exists(first + "/data/account.dpapi"), "Credential logout removes local file");
#elif defined(Q_OS_LINUX)
    const QByteArray credential("offline-credential-fixture");
    ok &= check(platformSaveCredential(credential).isEmpty(), "Linux credential saved locally");
    ok &= check(QFile::exists(first + "/data/account.credential"), "Credential file stays portable");
    // 登录态只允许当前用户读写，命令行与备份工具不会意外外泄。
    struct stat status{};
    ok &= check(::stat(QFile::encodeName(first + "/data/account.credential").constData(), &status) == 0 &&
                    (status.st_mode & 0777) == 0600,
                "Linux credential file is owner-only");
    ok &= check(platformCredential() == credential, "Linux credential round trip");
    platformDeleteCredential();
    ok &= check(!QFile::exists(first + "/data/account.credential"), "Credential logout removes local file");
#endif
    const auto second = directory + "/独立应用 B";
    ok &= check(AppStorage::initializePortable(second).isEmpty(), "Second portable application initialized");
    ok &=
        check(!AppStorage::settings().contains("panel/volume"), "Fresh extraction has independent settings");
    const auto relocated = directory + "/移动后的应用 C";
    ok &= check(QDir().mkpath(relocated + "/data") &&
                    QFile::copy(first + "/data/settings.ini", relocated + "/data/settings.ini"),
                "Portable settings move with application");
    ok &= check(AppStorage::initializePortable(relocated).isEmpty(), "Relocated application initialized");
    ok &= check(AppStorage::settings().value("panel/search-history").toString() == QStringLiteral("中文搜索"),
                "Relocated settings retain Unicode values");
    QFile blocked(directory + "/blocked");
    ok &= check(blocked.open(QIODevice::WriteOnly), "Unwritable location fixture created");
    blocked.close();
    ok &= check(!AppStorage::initializePortable(blocked.fileName()).isEmpty(),
                "Unwritable application fails instead of falling back to user directory");
    ok &= check(AppStorage::dataDirectory() == relocated + "/data",
                "Failed initialization never changes storage");
    return ok;
}
}

class AudioPlayerRegression {
  public:
    // 验证解码统计开关
    static bool diagnosticRegression() {
        AudioPlayer audio;
        audio.pcmEnabled = false;
        QJsonArray events;
        audio.diagnosticEvent = [&](const QString &, const QJsonObject &values) { events.append(values); };
        audio.enableDiagnostics(true);
        audio.player->errorOccurred(
            QMediaPlayer::NetworkError,
            QStringLiteral("HTTP error 403 https://PRIVATE_AUDIO_ERROR_URL/?token=secret"));
        QAudioFormat format;
        format.setSampleRate(48000);
        format.setChannelCount(2);
        format.setSampleFormat(QAudioFormat::Int16);
        const QAudioBuffer buffer(QByteArray(1920, '\0'), format, 0);
        audio.decodedOutput->audioBufferReceived(buffer);
        const auto state = audio.diagnosticState();
        bool ok = check(state["decodedBuffers"].toInt() == 1 && state["decodedFrames"].toInt() == 480 &&
                            state["sampleRateHz"].toInt() == 48000 && state["channels"].toInt() == 2,
                        "Diagnostic decoder counters report format and frames without PCM content");
        ok &= check(events.size() == 1 &&
                        events.first().toObject()["errorCode"].toInt() == int(QMediaPlayer::NetworkError) &&
                        events.first().toObject()["reportedHttpStatus"].toInt() == 403 &&
                        !QJsonDocument(events).toJson().contains("PRIVATE_AUDIO_ERROR_URL"),
                    "Diagnostic error events retain enum codes without raw errors");
        audio.enableDiagnostics(false);
        audio.decodedOutput->audioBufferReceived(buffer);
        ok &= check(audio.diagnosticState()["decodedBuffers"].toInt() == 1,
                    "Disabled diagnostics do not collect decoded buffers");
        audio.enableDiagnostics(true);
        audio.createPlayer();
        ok &= check(audio.player->audioBufferOutput() == audio.decodedOutput.get(),
                    "Rebuilt media sessions retain an independent live decoder observer");
        audio.enableDiagnostics(false);
        audio.enableDiagnostics(true);
        audio.createPlayer();

        return ok;
    }

    // 没有输出设备时不会访问网络，可验证真实 load 路径是否改写了上游地址。
    static bool sourceRegression() {
        AudioPlayer audio;
        audio.defaultOutput = [] { return QAudioDevice(); };
        audio.followDefaultOutput();
        const QString raw("http://fs.kugou.com/fixture.mp3?key=fixture&filename=a%20b");
        bool ok = check(audio.load(raw, false, false, "kugou") && audio.pendingSource == QUrl(raw),
                        "Kugou preserves upstream scheme and signed query");
        audio.control("stop");
        ok &= check(audio.load("http://music.126.net/fixture.mp3", false, false, "netease") &&
                        audio.pendingSource.scheme() == "https",
                    "NetEase keeps existing CDN compatibility");
        audio.control("stop");
        return ok;
    }

    static bool layoutRegression() {
#if defined(Q_OS_WIN) && QT_VERSION < QT_VERSION_CHECK(6, 9, 0)
        bool ok = true;
        for (const auto channels : {1, 2, 6, 8}) {
            const auto device = testDevice<QAudioDevicePrivate>("test-invalid-layout");
            auto *descriptor = const_cast<QAudioDevicePrivate *>(device.handle());
            descriptor->preferredFormat.setChannelCount(channels);
            descriptor->channelConfiguration = QAudioFormat::channelConfig(QAudioFormat::UnknownPosition);
            AudioPlayer::normalizeOutputLayout(device);
            ok &= check(device.handle() == descriptor, "Layout repair preserves concrete device identity");
            ok &= check(device.channelConfiguration() ==
                            QAudioFormat::defaultChannelConfigForChannelCount(channels),
                        "Unknown positions use actual mix channels instead of maximum channels");
            descriptor->preferredFormat.setChannelConfig(QAudioFormat::ChannelConfigStereo);
            const auto corrected = device.channelConfiguration();
            AudioPlayer::normalizeOutputLayout(device);
            ok &=
                check(device.channelConfiguration() == corrected, "Valid mono and surround layouts survive");
        }
        const auto device = testDevice<QAudioDevicePrivate>("test-mix-layout");
        auto *descriptor = const_cast<QAudioDevicePrivate *>(device.handle());
        const auto mix = QAudioFormat::channelConfig(QAudioFormat::FrontLeft, QAudioFormat::FrontRight,
                                                     QAudioFormat::SideLeft, QAudioFormat::SideRight);
        descriptor->preferredFormat.setChannelConfig(mix);
        descriptor->channelConfiguration = QAudioFormat::ChannelConfig(
            quint32(QAudioFormat::ChannelConfigStereo) | (1u << QAudioFormat::UnknownPosition));
        AudioPlayer::normalizeOutputLayout(device);
        ok &= check(device.channelConfiguration() == mix,
                    "Mixed unknown positions use exact WASAPI mix layout");
        descriptor->channelConfiguration = QAudioFormat::ChannelConfigUnknown;
        AudioPlayer::normalizeOutputLayout(device);
        ok &= check(device.channelConfiguration() == mix, "Missing layout uses exact WASAPI mix layout");
        return ok;
#else
        return true;
#endif
    }

    // 系统格式探测必须离开音频泵线程：只有设备 id 跨线程，结果回到主线程后才决定重建。
    static bool outputFormatProbeRegression() {
        std::atomic<int> probeCalls{0};
        QByteArray probedId;
        std::thread::id probeThread;
        const auto mainThread = std::this_thread::get_id();
        AudioOutputFormat::SystemFormat reported;
        AudioPlayer audio;
        const auto device = testDevice<QAudioDevicePrivate>("test-format-probe");
        audio.defaultOutput = [device] { return device; };
        audio.followDefaultOutput();
        const auto baseline = audio.pcm.snapshot();
        // 只有有效观测（status 非 0）才会触发重建；采样率与当前值不同即构成一次真实变化。
        reported.status = 1;
        reported.format.setSampleRate(qMax(1, baseline["outputSystemSampleRateHz"].toInt() + 1000));
        reported.format.setChannelCount(qMax(1, baseline["outputSystemChannels"].toInt()));
        reported.format.setSampleFormat(QAudioFormat::Float);
        int outputEvents = 0;
        audio.diagnosticEvent = [&](const QString &event, const QJsonObject &) {
            if (event == "output") {
                ++outputEvents;
            }
        };
        audio.readSystemOutputFormat = [&](const QByteArray &deviceId, bool) {
            probedId = deviceId;
            probeThread = std::this_thread::get_id();
            ++probeCalls;
            return reported;
        };
        audio.enableDiagnostics(true);
        // 观测值只消费一次；waitFor 结束前会再问一次谓词，不能让它把结果吃掉。
        bool applied = false;
        auto consume = [&] {
            if (!applied) {
                applied = audio.applyPendingOutputFormatObservation();
            }
            return applied;
        };
        audio.requestOutputFormatProbe();
        bool ok = waitFor(consume);
        ok &= check(probeCalls == 1 && probedId == device.id() && probeThread != mainThread,
                    "Format probe runs on a worker thread and only the device id crosses threads");
        ok &= check(outputEvents == 1, "A changed system format rebuilds the output once");
        const auto fresh = audio.pcm.snapshot();
        reported.status = fresh["outputSystemFormatStatus"].toInt();
        reported.format.setSampleRate(fresh["outputSystemSampleRateHz"].toInt());
        reported.format.setChannelCount(fresh["outputSystemChannels"].toInt());
        reported.format.setSampleFormat(
            QAudioFormat::SampleFormat(fresh["outputSystemSampleFormat"].toInt()));
        applied = false;
        audio.requestOutputFormatProbe();
        ok &= check(waitFor(consume) && outputEvents == 1 && probeCalls == 2,
                    "An unchanged system format produces no rebuild and no diagnostic event");
        audio.defaultOutput = [] { return QAudioDevice{}; };
        audio.followDefaultOutput();
        const auto before = probeCalls.load();
        audio.requestOutputFormatProbe();
        ok &= check(probeCalls.load() == before, "A missing output never schedules a probe");
        audio.enableDiagnostics(false);
        return ok;
    }

    static bool run() {
        AudioPlayer audio;
        const auto headphones = testDevice<QAudioDevicePrivate>("test-headphones");
        const auto speakers = testDevice<QAudioDevicePrivate>("test-speakers");
        auto selected = headphones;
        audio.defaultOutput = [&selected] { return selected; };
        auto notify = [&] {
            audio.devices.audioOutputsChanged();
            QCoreApplication::processEvents();
        };
        notify();
        bool ok = check(audio.output.device() == headphones, "Startup follows connected headphones");
        audio.control("volume", .42);
        selected = speakers;
        notify();
        ok &= check(audio.output.device() == speakers, "Disconnect switches to default speakers");
        selected = headphones;
        notify();
        ok &= check(audio.output.device() == headphones, "Connecting after startup switches output");
        selected = speakers;
        notify();
        ok &= check(audio.output.device() == speakers, "System selection switches away from headphones");
        ok &= check(qAbs(audio.output.volume() - .42f) < .001f, "Device changes preserve player volume");
        audio.control("pause");
        selected = {};
        notify();
        ok &= check(audio.outputUnavailable && audio.player->audioOutput() == nullptr,
                    "No output detaches the unavailable device");
        selected = speakers;
        notify();
        ok &= check(!audio.outputUnavailable && audio.player->audioOutput() == nullptr,
                    "Same device reconnects after disappearing");
        ok &= check(!audio.playbackRequested && !audio.player->isPlaying(),
                    "Reconnecting never cancels user pause");
        audio.control("resume");
        selected = {};
        notify();
        ok &= check(audio.playbackRequested, "Temporary device loss retains playback intent");
        audio.control("stop");
        selected = headphones;
        notify();
        ok &= check(!audio.playbackRequested && !audio.player->isPlaying(),
                    "Reconnecting never cancels user stop");
        selected = {};
        notify();
        const QString deferredSource("file:///offline-device-reconnect.wav");
        ok &= check(audio.load(deferredSource, true) && audio.pendingSource == QUrl(deferredSource) &&
                        audio.player->source().isEmpty() && audio.error.isEmpty(),
                    "No output defers decoding without reporting a source error");
        audio.control("stop");
        selected = headphones;
        notify();
        ok &= check(audio.pendingSource.isEmpty() && audio.player->source().isEmpty() &&
                        !audio.playbackRequested,
                    "Stop cancels a source deferred until output reconnects");
        int changes = 0;
        QObject::connect(&audio.output, &QAudioOutput::deviceChanged, audio.player.get(), [&] { ++changes; });
        selected = speakers;
        audio.devices.audioOutputsChanged();
        selected = headphones;
        audio.devices.audioOutputsChanged();
        QCoreApplication::processEvents();
        ok &= check(audio.output.device() == headphones && changes == 0,
                    "Queued changes resolve the newest default without obsolete device bindings");
        return ok;
    }
};

int main(int argc, char **argv) {
    QGuiApplication application(argc, argv);
    // 所有写入位于调用者指定的测试目录，测试可执行文件不进入正式部署包。
    const auto arguments = application.arguments();
    if (arguments.size() != 2) {
        qCritical() << "Provide a local writable regression directory";
        return 1;
    }
    const auto directory = QDir(arguments.at(1)).absolutePath();
    if (!QDir().mkpath(directory)) {
        qCritical() << "Cannot create local regression directory";
        return 1;
    }
    QTemporaryDir fixture(directory + "/run-XXXXXX");
    if (!fixture.isValid()) {
        qCritical() << "Cannot create isolated regression fixture";
        return 1;
    }
    const bool storage = storageRegression(fixture.path());
    const bool metrics = processMetricsRegression();
    const bool audio = AudioPlayerRegression::diagnosticRegression() && AudioPlayerRegression::run() &&
                       AudioPlayerRegression::layoutRegression() &&
                       AudioPlayerRegression::outputFormatProbeRegression() &&
                       AudioPlayerRegression::sourceRegression();
    qInfo() << "Portable storage, process metrics and default audio output regressions:"
            << (storage && metrics && audio ? "PASS" : "FAIL");
    return storage && metrics && audio ? 0 : 1;
}
