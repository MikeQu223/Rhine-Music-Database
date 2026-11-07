#pragma once
#include <QRectF>
#include <QQuickPaintedItem>
class Engine;
class Hud : public QQuickPaintedItem {
    Q_OBJECT
    Q_PROPERTY(Engine *engine READ engine WRITE setEngine NOTIFY engineChanged)
  public:
    Hud(QQuickItem *parent = nullptr);
    Engine *engine() const {
        return m_engine;
    }
    void setEngine(Engine *engine);
    void paint(QPainter *painter) override;
  signals:
    void engineChanged();

#if defined(Q_OS_DARWIN) || defined(Q_OS_ANDROID)
  protected:
    QSGNode *updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *updateData) override;
#endif

  private:
    void scheduleUpdate();
    /// HUD 命令流变化后显式请求窗口出帧（见 Hud.cpp：item 标脏不等于有呈现帧）。
    void requestWindowFrame();
    Engine *m_engine = nullptr;
#if defined(Q_OS_ANDROID)
    /// 待重绘区域（item 逻辑坐标）。为空且 m_fullRepaint 为假时表示整块都不用画。
    QRectF m_pendingDirty;
    bool m_fullRepaint = true;
#endif
};
