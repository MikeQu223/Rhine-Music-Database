#pragma once
#include "NativeCards.h"
#include "SceneAppearance.h"
#include "SceneMotion.h"
#include <QPointF>
#include <optional>
#include <memory>

class NativeViewer {
  public:
    explicit NativeViewer(QString root);
    bool isOpen() const;
    bool targetVisible() const {
        return m_open && !m_closing;
    }
    bool pending() const;
    void open(double time);
    void action(QString action, double time);
    void key(QString key, double time);
    void pointer(QString type, double x, double y, double delta);
    void coverFront(bool front);
    void resize(double width, double height);
    void reduced(bool value);
    void update(double time, double theme);
    void trimMemory();
    QJsonObject frame(QJsonObject base, const SceneAppearance &appearance, SceneDrawBuffers &buffers);

  private:
    using Vector = SceneMath::Vector;
    using Matrix = SceneMath::Matrix;
    struct Spherical {
        double radius = 1;
        double phi = 0;
        double theta = 0;
    };
    QString m_root;
    QJsonArray m_meshes;
    NativeCards m_cards;
    bool m_open = false;
    bool m_closing = false;
    bool m_reduced = false;
    bool m_dragging = false;
    bool m_resetting = false;
    bool m_ready = false;
    QPointF m_previous;
    double m_width = 1920;
    double m_height = 1080;
    double m_last = 0;
    double m_time = 0;
    double m_pendingUntil = 0;
    double m_closeAt = 0;
    double m_resetElapsed = 0;
    double m_theme = 0;
    SceneMotion::Spring m_clarity{1, 0};
    SceneMotion::Spring m_spread;
    double m_targetClarity = 1;
    double m_targetSpread = 0;
    Vector m_eye{7.2, 3.8, 12};
    Vector m_focus;
    Vector m_target;
    Vector m_resetFocus;
    Spherical m_pose;
    Spherical m_goal;
    Spherical m_resetFrom;
    QString m_transition = "closed";
    QString m_surface = "clear";
    void reset(bool animated);
    void interrupt();
    static Spherical spherical(Vector vector);
    static Vector vector(Spherical spherical);
};
