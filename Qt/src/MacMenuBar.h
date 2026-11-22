#pragma once
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QVector>
#include <functional>

namespace MacMenuBar {
inline constexpr auto LayoutPreference = "menu-bar-layout";

enum class Component { Lyrics, Controls, Favorite, Icon };
using Layout = QVector<Component>;

Layout defaultLayout();
Layout parseLayout(const QString &preference);
Layout effectiveLayout(Layout layout, bool enabled, const QString &controlsPreference,
                       const QString &iconPreference);
QString serializeLayout(const Layout &layout);
QString lyricText(const QJsonObject &document, int index);
}

class Engine;

class MacMenuBarController : public QObject {
  public:
    using Action = std::function<void()>;

    MacMenuBarController(Engine *engine, Action activate, Action contextMenu, QObject *parent = nullptr);
    ~MacMenuBarController() override;

    bool available() const;
    void refresh();
    void activate();
    void showContextMenu();
    void previous();
    void togglePlayback();
    void next();
    void toggleFavorite();

  private:
    void scheduleRefresh();
    void applyPreferences();
    void removeStatusItem();

    Engine *m_engine;
    Action m_activate;
    Action m_contextMenu;
    struct Impl;
    Impl *m_impl;
};
