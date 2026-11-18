#pragma once
#include <QJsonArray>
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
    /// 把一段命令流画进当前 painter（已缩放到 1080 舞台坐标系）。分层时两层各用一段。
    void paintCommands(QPainter *painter, const QJsonArray &commands);
    void scheduleUpdate();
    /// HUD 命令流变化后显式请求窗口出帧（见 Hud.cpp：item 标脏不等于有呈现帧）。
    void requestWindowFrame();
    Engine *m_engine = nullptr;
#if defined(Q_OS_ANDROID)
    /// 待重绘区域（item 逻辑坐标）。分层后动态层用 m_pendingDirty、静态层用
    /// m_pendingStatic；对应的 *Full 为假且待绘区域为空时表示这一层不用画。
    QRectF m_pendingDirty;
    QRectF m_pendingStatic;
    /// 这一层是否有待画的改动（scheduleUpdate 置位、updatePaintNode 消费）。
    bool m_dynamicDirty = true;
    bool m_staticDirty = true;
    bool m_fullRepaint = true;
    bool m_staticFullRepaint = true;
    /// 上一次 updatePaintNode 建的节点形态：true = 容器节点下两个纹理节点（静态在前），
    /// false = 单个纹理节点。形态切换时必须重建整棵树，不能拿旧节点强转。
    bool m_layeredNode = false;
#endif
};
