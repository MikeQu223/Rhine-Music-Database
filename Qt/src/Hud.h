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
    Engine *m_engine = nullptr;
#if defined(Q_OS_ANDROID)
    /// 待重绘区域（item 逻辑坐标）。为空且 m_fullRepaint 为假时表示整块都不用画。
    QRectF m_pendingDirty;
    bool m_fullRepaint = true;
#endif
};
