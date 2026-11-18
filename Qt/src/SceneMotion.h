#pragma once
#include <QHash>
#include <QJsonObject>
#include <QPair>
#include <QPointF>
#include <QVector>
#include <optional>

namespace SceneMotion {
using Curve = QVector<QPair<double, double>>;
double track(const Curve &keys, double time, bool stationaryEnds = false);
double smooth(double value);
double ease(double value);
double extraction(double time);
double cinematicField(double row, double lane, double time, double center = 12, double focus = 2);
double returnStep(double angle, double seconds, bool reduced = false);
struct Spring {
    double value = 0;
    double velocity = 0;
    void damp(double target, double rate, double seconds);
};
struct Cell {
    int lane = 0;
    int row = 0;
    bool operator==(const Cell &) const = default;
    QString key() const;
};

struct FieldPulse {
    Cell cell;
    double time = 0;
};
struct ArchiveField {
    Cell origin;
    double scanTime = 29.1;
    double scanBlend = 0;
    double shoulder = 12;
    double laneFocus = 2;
    double idleGain = 0;
    double time = 0;
    double pulseGain = 1;
    bool selectionWave = true;
    QVector<FieldPulse> pulses;
    double sample(double row, double lane) const;
};

class ThemeWave {
  public:
    void set(bool dark, double time, Cell origin, bool immediate = false);
    bool settled(double time) const;
    double background(double time) const;
    void beginFrame();
    double sample(Cell cell, double time);
    double target = 0;

  private:
    double m_start = -10;
    Cell m_origin{2, 12};
    QHash<QString, double> m_from;
    QHash<QString, double> m_latest;
    double m_backgroundFrom = 0;
};

class Decryption {
  public:
    static constexpr double START = 34.12;
    static constexpr double END = 39.56;
    static QJsonObject sample(double time);
    void enter(bool alreadyClear = false);
    void leave();
    void select(double clarity = 0);
    void finish();
    void update(double seconds, bool ready, bool reduced, std::optional<double> reference = std::nullopt);
    bool settled() const {
        return !m_active || (m_elapsed && *m_elapsed >= (END - START) / 1.5);
    }
    double clarity = 0;
    QJsonObject frame = sample(-1);

  private:
    bool m_active = false;
    std::optional<double> m_elapsed;
};

class BootTimeline {
  public:
    explicit BootTimeline(const QJsonObject &tracks);
    QJsonObject sample(double appTime) const;

  private:
    QHash<QString, Curve> m_tracks;
    double value(const QString &key, double frame) const;
    QJsonObject logo(double frame) const;
    QJsonObject scan(double frame) const;
    QJsonObject orbit(double frame) const;
};
}
