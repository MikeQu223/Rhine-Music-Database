#pragma once
#include "NativeHud.h"
#include "GlobalShortcuts.h"
#include "NativeScene.h"

class NativeApplication : public QObject {
  public:
    NativeApplication(Host *host, Glyphs *glyphs, NativeScene *scene, QJsonObject content,
                      QObject *parent = nullptr);
    void initialize();
    QJsonObject sessionState() const;
    bool restoreSessionState(const QJsonObject &saved);
    void saveSession();
    QJsonObject step(double time, double width, bool reuseScene = false);
    void poll(double time, bool force = false);
    void mediaAction(QString action);
    void pointer(QString type, double x, double y);
    MusicLibrary music;
    GlobalShortcuts shortcuts;
    NativeHud hud;

  private:
    Host *m_host;
    NativeScene *m_scene;
    bool m_dragging = false;
    bool m_hudPointerSequence = false;
    bool m_moved = false;
    QPointF m_down;
    static HudSceneActions sceneActions(NativeScene *scene);
};
