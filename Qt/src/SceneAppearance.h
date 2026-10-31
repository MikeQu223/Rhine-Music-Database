#pragma once
#include "SceneMath.h"
#include <QJsonObject>
#include <QSet>

class SceneAppearance {
  public:
    explicit SceneAppearance(const QJsonObject &asset);
    QJsonArray actorTemplate;
    /// F02：模板代号。actorTemplate 只在构造期构建，每次 new SceneAppearance 取一个新代号，
    /// 下游（NativeCards）据此判断要不要重新预解码部件模板。
    quint64 revision = 0;
    QJsonArray instances;
    QVector<int> pickingMeshes;
    SceneMath::Vector boundsCenter{0, 1.85, 0};
    double boundsRadius = 3.3;
    QJsonObject floor(double theme) const;
    static QJsonArray color(QString hex);
    static QJsonArray blend(const QJsonArray &from, const QJsonArray &to, double amount);

  private:
    static QJsonObject material(const QJsonObject &source);
};
