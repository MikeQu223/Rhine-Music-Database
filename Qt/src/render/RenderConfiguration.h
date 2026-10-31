#pragma once

#include <QMutex>
#include <QMutexLocker>
#include <QSize>
#include <QString>
#include <QStringList>
#include <QList>
#include <QVariantMap>
#include <functional>

namespace RhineRender {

/** 每个 Engine 独立持有的渲染设置；渲染线程只读取加锁复制后的值。 */
struct Settings {
    QString modeName = QStringLiteral("off");
    int renderPercent = 100;
    int supersample = 1;
    bool interpolation = false;
    bool vsync = true;
    quint64 revision = 0;
    bool nativeTemporalAvailable = false;

    bool temporal() const {
        return modeName == QLatin1String("metalfx") && nativeTemporalAvailable &&
               supersample * renderPercent <= 100;
    }
    QSize renderSize(QSize display) const {
        const double scale = supersample * renderPercent / 100.0;
        return {qMax(1, qRound(display.width() * scale)), qMax(1, qRound(display.height() * scale))};
    }
};

class RenderTelemetry {
  public:
    void publish(QSize renderSize, QSize displaySize, int samples, const QString &implementation,
                 bool enhanced) {
        QMutexLocker lock(&m_mutex);
        m_value = {{"renderWidth", renderSize.width()},
                   {"renderHeight", renderSize.height()},
                   {"displayWidth", displaySize.width()},
                   {"displayHeight", displaySize.height()},
                   {"samples", samples},
                   {"implementation", implementation},
                   {"enhanced", enhanced}};
    }
    QVariantMap snapshot() const {
        QMutexLocker lock(&m_mutex);
        return m_value;
    }

  private:
    mutable QMutex m_mutex;
    QVariantMap m_value;
};

class RenderConfiguration {
  public:
    /** 启动环境只读取一次；之后的界面修改通过显式配置传递，不写进程环境。 */
    void initialize(const std::function<QString(const QString &)> &preference) {
        const QList<QPair<QString, QString>> keys{{"aa-mode", "RHINE_AA_MODE"},
                                                  {"render-scale", "RHINE_RENDER_SCALE"},
                                                  {"supersample", "RHINE_SUPERSAMPLE"},
                                                  {"fg", "RHINE_FG"},
                                                  {"vsync", "RHINE_VSYNC"}};
        for (const auto &entry : keys) {
            const auto environment = qgetenv(entry.second.toUtf8().constData());
            // FSR 插帧已从设置界面下线：配置文件里残留的 panel/fg=on 一律按"关"处理，
            // 只有显式环境变量（排障用）才能打开。
            const auto configured = entry.first == QLatin1String("fg") ? QStringLiteral("off")
                                                                       : preference(entry.first);
            const auto value = environment.isEmpty() ? configured : QString::fromUtf8(environment);
            if (!value.isEmpty()) {
                applyPreference(entry.first, value);
            }
        }
        if (qEnvironmentVariableIsEmpty("RHINE_VSYNC") && !qEnvironmentVariableIsEmpty("RHINE_FG_VSYNC")) {
            applyPreference("vsync", QString::fromUtf8(qgetenv("RHINE_FG_VSYNC")));
        }
    }

    Settings snapshot() const {
        QMutexLocker lock(&m_mutex);
        return m_settings;
    }

    void setNativeTemporalAvailable(bool available) {
        QMutexLocker lock(&m_mutex);
        m_settings.nativeTemporalAvailable = available;
    }

    bool applyPreference(const QString &key, const QString &value) {
        QMutexLocker lock(&m_mutex);
        if (key == QLatin1String("aa-mode")) {
            m_settings.modeName = value == "metalfx" ? QStringLiteral("metalfx") : QStringLiteral("off");
        } else if (key == QLatin1String("fg")) {
            m_settings.interpolation = QStringList{"on", "1", "true", "yes", "enable", "enabled"}.contains(
                value.trimmed().toLower());
        } else if (key == QLatin1String("vsync")) {
            m_settings.vsync = !QStringList{"off", "0", "false", "no", "disable", "disabled"}.contains(
                value.trimmed().toLower());
        } else {
            bool valid = false;
            const int number = value.toInt(&valid);
            if (!valid) {
                return false;
            }
            if (key == QLatin1String("render-scale")) {
                m_settings.renderPercent = qBound(50, number, 100);
            } else if (key == QLatin1String("supersample")) {
                m_settings.supersample = qBound(1, number, 2);
            } else {
                return false;
            }
        }
        ++m_settings.revision;
        return true;
    }

  private:
    mutable QMutex m_mutex;
    Settings m_settings;
};
} // namespace RhineRender
