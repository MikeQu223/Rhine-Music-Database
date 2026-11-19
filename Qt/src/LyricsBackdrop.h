#pragma once

#include <QElapsedTimer>
#include <QImage>
#include <QMetaObject>
#include <QPointer>
#include <QQuickRhiItem>
#include <QTimer>
#include <QVector4D>
#include <array>

class Engine;
class QQuickWindow;

/** 竖屏歌词页的低功耗封面色彩背景；只在 QML 可见且实际播放时推进。 */
class LyricsBackdrop : public QQuickRhiItem {
    Q_OBJECT
    Q_PROPERTY(Engine *engine READ engine WRITE setEngine NOTIFY engineChanged)
    Q_PROPERTY(bool playbackActive READ playbackActive WRITE setPlaybackActive NOTIFY playbackActiveChanged)
    Q_PROPERTY(bool reducedMotion READ reducedMotion WRITE setReducedMotion NOTIFY reducedMotionChanged)
    Q_PROPERTY(bool darkTheme READ darkTheme WRITE setDarkTheme NOTIFY darkThemeChanged)
    Q_PROPERTY(
        double controlsOpacity READ controlsOpacity WRITE setControlsOpacity NOTIFY controlsOpacityChanged)
    Q_PROPERTY(double controlsTop READ controlsTop WRITE setControlsTop NOTIFY controlsTopChanged)
  public:
    explicit LyricsBackdrop(QQuickItem *parent = nullptr);

    Engine *engine() const {
        return m_engine;
    }
    void setEngine(Engine *engine);
    bool playbackActive() const {
        return m_playbackActive;
    }
    void setPlaybackActive(bool value);
    bool reducedMotion() const {
        return m_reducedMotion;
    }
    void setReducedMotion(bool value);
    bool darkTheme() const {
        return m_darkTheme;
    }
    void setDarkTheme(bool value);
    double controlsOpacity() const {
        return m_controlsOpacity;
    }
    void setControlsOpacity(double value);
    double controlsTop() const {
        return m_controlsTop;
    }
    void setControlsTop(double value);

    QImage coverImage() const {
        return m_coverImage;
    }
    qint64 coverRevision() const {
        return m_coverRevision;
    }
    std::array<QVector4D, 4> palette() const {
        return m_palette;
    }
    double phase() const {
        return m_phase;
    }

  signals:
    void engineChanged();
    void playbackActiveChanged();
    void reducedMotionChanged();
    void darkThemeChanged();
    void controlsOpacityChanged();
    void controlsTopChanged();

  protected:
    QQuickRhiItemRenderer *createRenderer() override;
    void geometryChange(const QRectF &newGeometry, const QRectF &oldGeometry) override;

  private:
    void observeWindow(QQuickWindow *window);
    void refreshCover();
    void refreshTimer();
    bool shouldAnimate() const;
    void tick();
    void requestWindowFrame();
    void updateColorBufferSize();

    Engine *m_engine = nullptr;
    QPointer<QQuickWindow> m_observedWindow;
    QMetaObject::Connection m_windowActiveConnection;
    QMetaObject::Connection m_windowVisibilityConnection;
    QImage m_coverImage;
    qint64 m_coverRevision = 0;
    std::array<QVector4D, 4> m_palette{};
    QElapsedTimer m_phaseClock;
    double m_phase = 0;
    QTimer m_timer;
    bool m_playbackActive = false;
    bool m_reducedMotion = false;
    bool m_darkTheme = false;
    double m_controlsOpacity = 0;
    double m_controlsTop = .68;
};
