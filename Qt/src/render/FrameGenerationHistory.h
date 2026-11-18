#pragma once

#include <QJsonArray>
#include <QJsonObject>

namespace RhineRender {

/** 按实际提交的场景隔离插帧历史，不依赖可能被呈现节拍跳过的一次性引擎标记。 */
class FrameGenerationHistory {
  public:
    bool update(const QJsonObject &frame, const QJsonObject &item, qint64 coverRevision) {
        const bool mobile = frame["mobileHud"].toBool();
        const QJsonArray next = mobile ? QJsonArray{frame["stats"].toObject()["coordinateOrigin"],
                                                    frame["mode"],
                                                    frame["viewer"],
                                                    frame["mobileHud"],
                                                    frame["songPanelTop"],
                                                    item["provider"],
                                                    item["key"],
                                                    item["id"],
                                                    QString::number(coverRevision)}
                                       : QJsonArray{};
        const bool changed = next != m_context;
        m_context = next;
        return changed;
    }

  private:
    QJsonArray m_context;
};

} // namespace RhineRender
