#pragma once
#include "fg/FgStats.h"

#include <QElapsedTimer>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QMutex>
#include <QObject>
#include <QPointer>
#include <QTextStream>
#include <QTimer>
#include <QVariantMap>
#include <atomic>

class Engine;
class QQuickWindow;

class FrameProfiler : public QObject {
    Q_OBJECT
    // 每个属性各自 NOTIFY：`changed` 是聚合信号，QML 里没有任何属性绑它。
    // 拆开的原因见 PerformancePanel：`details` 是一段几百行的长文本，Text 每次重排
    // 都要重新布局 + 重建字形，而 `headline` 只有一行。原先两者共用一个 NOTIFY，
    // 于是每 500 ms 采样一次就必然重排整段详情——面板一打开，观测本身就在拖帧。
    Q_PROPERTY(bool visible READ visible NOTIFY visibleChanged)
    Q_PROPERTY(bool recording READ recording NOTIFY recordingChanged)
    Q_PROPERTY(QString headline READ headline NOTIFY headlineChanged)
    Q_PROPERTY(QString details READ details NOTIFY detailsChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString recordingAction READ recordingAction NOTIFY recordingChanged)
    Q_PROPERTY(QVariantMap metrics READ metrics NOTIFY metricsChanged)
    /// 面板收起（精简模式）时置 false：完全不重建 details，长文本连布局都不做。
    Q_PROPERTY(bool detailsEnabled READ detailsEnabled WRITE setDetailsEnabled NOTIFY detailsEnabledChanged)
  public:
    explicit FrameProfiler(Engine *engine, const QString &path = {}, QObject *parent = nullptr);
    ~FrameProfiler() override;
    void attach(QQuickWindow *window);
    bool visible() const {
        return m_visible;
    }
    bool recording() const {
        return m_recording;
    }
    bool detailsEnabled() const {
        return m_detailsEnabled;
    }
    void setDetailsEnabled(bool enabled);
    QString headline() const {
        return m_headline;
    }
    QString details() const {
        return m_details;
    }
    QString status() const {
        return m_status;
    }
    QString recordingAction() const {
        if (m_recording) {
            return QStringLiteral("■ 停止并导出");
        }
        return m_samples.isEmpty() ? QStringLiteral("开始收集") : QStringLiteral("重试导出");
    }
    QVariantMap metrics() const {
        return m_metrics;
    }
    Q_INVOKABLE void toggleVisible();
    Q_INVOKABLE void toggleRecording();
    Q_INVOKABLE void openReportFolder();
    bool startRecording();
    bool saveRecording();
    // 测试和原生命令行入口可指定目录；正常界面使用文稿目录。
    void setReportDirectory(const QString &directory);
  signals:
    /// 聚合信号：只在 C++ 侧或旧测试用。QML 的属性已各自绑到下面更细的信号，
    /// 不要再用它驱动 `details`——那会把长文本重排带回到每次采样。
    void changed();
    void visibleChanged();
    void recordingChanged();
    void headlineChanged();
    void detailsChanged();
    void statusChanged();
    void metricsChanged();
    void detailsEnabledChanged();

  private:
    void updateSampling();
    /// 窗口是否处于可见状态：FG 呈现层接管时没有 QQuickWindow，改看呈现层统计。
    bool windowShown() const;
    void sample();
    void collectStep();
    /// `withDetails` 为假时只更新 headline，跳过整段详情构建（面板收起或未到刷新间隔）。
    void formatMetrics(bool withDetails);
    QJsonObject environment() const;
    Engine *m_engine;
    QPointer<QQuickWindow> m_window;
    bool m_visible = false;
    bool m_recording = false;
    bool m_saving = false;
    bool m_previousProfiling = false;
    struct FrameEvent {
        qint64 timestampNs;
        qint64 gapNs;
        qint64 syncCpuNs;
        qint64 submitCpuNs;
    };
    QList<FrameEvent> m_trace;
    quint64 m_omittedTraceFrames = 0;
    QString m_adapterName;
    QString m_backendName;
    std::atomic<bool> m_capture{false};
    QString m_headline = QStringLiteral("等待采样");
    QString m_details;
    QString m_status;
    /// 面板收起时为 false：`details` 不重建，长文本不参与布局。
    bool m_detailsEnabled = true;
    /// 详情最近一次重建的时刻（`clock` 毫秒）；降频用，见 `m_detailsIntervalMs`。
    qint64 m_detailsBuiltMs = 0;
    /// 详情刷新间隔。headline 仍是每 500 ms 一次，详情默认 1 s——数字够看，
    /// 而长文本重排的次数直接减半。`RHINE_PROFILER_DETAILS_MS` 可改，0 = 每次都刷。
    int m_detailsIntervalMs = 1000;
    QString m_directory;
    QVariantMap m_metrics;
    QJsonArray m_samples;
    QJsonObject m_audioReport;
    QTimer m_sampleTimer;
    qint64 m_recordStartedMs = 0;
    qint64 m_recordStoppedMs = 0;
    qint64 m_previousSampleNs = 0;
    qint64 m_previousCpuNs = -1;
    quint64 m_previousPresents = 0;
    quint64 m_previousSceneFrames = 0;
    // 帧生成呈现层自己做 present，Qt 侧收不到 frameSwapped，所以它的累计计数在这里取差值。
    quint64 m_previousFgPresented = 0;
    quint64 m_previousFgInterpolated = 0;
    quint64 m_previousFgRendered = 0;
    quint64 m_stepCount = 0;
    double m_stepTotalMs = 0;
    double m_stepMaxMs = 0;
    QFile file;
    QTextStream stream;
    QElapsedTimer clock;
    QElapsedTimer syncTimer;
    QElapsedTimer renderTimer;
    std::atomic<bool> m_enabled{false};
    std::atomic<qint64> syncNs{0};
    std::atomic<qint64> submitNs{0};
    std::atomic<qint64> presentNs{0};
    std::atomic<qint64> presentGapNs{0};
    std::atomic<quint64> presents{0};
    QMutex m_gapMutex;
    QList<double> m_gapsMs;
    qint64 epochMs = 0;
};
