#pragma once
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

#ifdef Q_OS_DARWIN
  protected:
    QSGNode *updatePaintNode(QSGNode *oldNode, UpdatePaintNodeData *updateData) override;
#endif

  private:
    Engine *m_engine = nullptr;
};
