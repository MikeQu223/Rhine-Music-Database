#pragma once
#include "SceneTypes.h"
#include <QJsonObject>
#include <QJsonArray>
#include <QMatrix4x4>
#ifdef Q_OS_DARWIN
#include <array>
#endif

// 卡片共用静态部件模板；每个活动根只携带矩阵与外观状态。
class NativeCards {
  public:
    QString expand(QJsonObject &frame, const QByteArray &bytes, SceneDrawBuffers &buffers);

  private:
    /// F02：预解码后的部件模板。字段与 actorTemplate 的 JSON 一一对应，
    /// 按外观代号缓存一次，之后每张卡片每个部件不再做 toObject／toArray 解析。
    struct Part {
        QJsonObject base;
        QJsonObject high;
        QJsonObject low;
        QJsonArray localValues;
        QJsonValue mesh;
        QJsonValue asset;
        QJsonValue label;
        QJsonValue name;
        QJsonValue transparent;
        QJsonValue depthWrite;
        QJsonValue order;
        QJsonValue side;
        QJsonValue castShadow;
        int partIndex = 0;
        bool hasMap = false;
        bool interpolateAttenuation = false;
        bool localIdentity = true;
        bool frosted = false;
    };
    QJsonObject makeDraw(const Part &part, const QJsonObject &card, const double *state,
                         const QJsonValue &globalSubdued);
#ifdef Q_OS_DARWIN
    struct CachedActor {
        QJsonObject card;
        std::array<double, 4> appearance{};
        QJsonValue globalSubdued;
        QVector<QJsonObject> draws;
    };
    QHash<int, CachedActor> cachedActors;
    QString expandMetal(QJsonObject &frame, const QByteArray &bytes, SceneDrawBuffers &buffers);

#endif
    const QVector<Part> &decodeParts(quint64 revision, const QJsonArray &source);

    QJsonArray parts;
    QVector<Part> decoded;
    quint64 decodedRevision = ~quint64(0);
};
