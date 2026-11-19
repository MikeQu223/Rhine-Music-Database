#pragma once
#include <QJsonArray>
#include <QString>
#include <QStringList>
#include <QVector>
#include <array>
#include <functional>

namespace UiMotion {

// 时间与时长均为秒；位置、偏移和速度沿用界面逻辑坐标。
class ReelCurve {
  public:
    ReelCurve(double from = 0, double target = 0, double velocity = 0, double start = 0,
              double duration = 0.46);
    std::array<double, 2> sample(double time) const;
    double start = 0;
    double duration = 0.46;

  private:
    std::array<double, 49> m_points{};
};

class SurfaceMotion {
  public:
    void sample(double time);
    void set(bool shown, double time, bool reduced = false, double enterDuration = .3,
             double exitDuration = .2);
    bool finished() const {
        return duration == 0;
    }
    double opacity = 0;
    double offset = 12;
    double duration = 0;

  private:
    double m_fromOpacity = 0;
    double m_fromOffset = 12;
    double m_targetOpacity = 0;
    double m_targetOffset = 12;
    double m_start = 0;
    bool m_entering = true;
};

class RollingLabel {
  public:
    using Measure = std::function<double(const QString &, double, const QString &, double)>;
    bool active(double time) const;
    QJsonArray render(const QString &next, double x, double y, double size, const QString &weight,
                      double tracking, double time, bool animated, bool numeric, const QJsonArray &ink,
                      const Measure &measure);

  private:
    struct Slot {
        QStringList wheel;
        ReelCurve position;
        ReelCurve x;
        ReelCurve width;
        ReelCurve alpha;
    };
    QString m_value;
    QVector<Slot> m_slots;
    QVector<Slot> m_retired;
    bool m_initialized = false;
};

}
