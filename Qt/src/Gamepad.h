#pragma once
#include <QElapsedTimer>
#include <QObject>
#include <QString>
#include <QTimer>

class Gamepad : public QObject {
    Q_OBJECT
  public:
    explicit Gamepad(QObject *parent = nullptr);
    void setEnabled(bool enabled);

  signals:
    void pressed(const QString &button);

  private:
    enum Button { Up, Down, Left, Right, A, B, Select, Start, LB, RB, LT, RT, LS, RS, ButtonCount };
    void poll();
    void update(Button button, bool down, qint64 now, qint64 initialDelay, qint64 repeatInterval);
    void reset();
    static QString name(Button button);
    QTimer m_timer;
    QElapsedTimer m_clock;
    bool m_enabled = true;
    bool m_connected = false;
    bool m_foreground = false;
    int m_slot = -1;
    bool m_held[ButtonCount] = {};
    qint64 m_nextRepeat[ButtonCount] = {};
};
