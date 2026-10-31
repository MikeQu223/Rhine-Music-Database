#include "NativeCards.h"
#include "render/HotPathProbe.h"
#include <QMatrix4x4>
#include <algorithm>
#include <cstring>

namespace {
double interpolate(double low, double high, double amount) {
    return (1 - amount) * low + amount * high;
}

QJsonArray interpolateColor(const QJsonArray &low, const QJsonArray &high, double amount) {
    QJsonArray result;
    for (int i = 0; i < 3; ++i) {
        const auto start = low[i].toDouble();
        result.append(start + (high[i].toDouble() - start) * amount);
    }
    return result;
}

QMatrix4x4 localMatrix(const QJsonArray &values) {
    QMatrix4x4 result;
    for (int i = 0; i < 16; ++i) {
        result(i % 4, i / 4) = float(values[i].toDouble());
    }
    return result;
}
}

/**
 * 共享卡片模板与紧凑根状态
 * 每张卡片只传一份根矩阵；局部偏移仅对标签等非单位部件计算。
 */
const QVector<NativeCards::Part> &NativeCards::decodeParts(quint64 revision, const QJsonArray &source) {
    // 模板不变就复用上次的解码结果；代号为 0（调用方没提供，例如 viewer 的临时模板）时每次都重解。
    if (revision != 0 && revision == decodedRevision) {
        return decoded;
    }
    decoded.clear();
    decoded.reserve(source.size());
    for (const auto &entry : source) {
        const auto part = entry.toObject();
        Part item;
        item.base = part["base"].toObject();
        item.high = part["high"].toObject();
        item.low = part["low"].toObject();
        item.localValues = part["localMatrix"].toArray();
        item.mesh = part["mesh"];
        item.asset = part["asset"];
        item.label = part["label"];
        item.name = part["name"];
        item.transparent = part["transparent"];
        item.depthWrite = part["depthWrite"];
        item.order = part["order"];
        item.side = part["side"];
        item.castShadow = part["castShadow"];
        item.partIndex = part["partIndex"].toInt();
        item.hasMap = part["hasMap"].toBool();
        item.interpolateAttenuation = part["interpolateAttenuation"].toBool();
        item.localIdentity = localMatrix(item.localValues).isIdentity();
        item.frosted = part["name"].toString() == "Frosted_Polymer";
        decoded.append(item);
    }
    decodedRevision = revision;
    return decoded;
}

QString NativeCards::expand(QJsonObject &frame, const QByteArray &bytes, SceneDrawBuffers &buffers) {
    RhineRender::HotPathTimer cardTimer(RhineRender::hotPathWindow().cardNs);
    if (frame.contains("actorTemplate")) {
        parts = frame["actorTemplate"].toArray();
    }
    const auto cards = frame["actors"].toArray();
    const auto partList = decodeParts(quint64(frame["appearanceRevision"].toDouble()), parts);
    constexpr qsizetype stride = 20;
    if (parts.isEmpty() || bytes.size() != cards.size() * stride * qsizetype(sizeof(double))) {
        return QStringLiteral("Invalid native card packet");
    }
    auto draws = frame["draws"].toArray();
    const qsizetype initialDraws = draws.size();
    for (qsizetype index = 0; index < cards.size(); ++index) {
        double state[stride];
        memcpy(state, bytes.constData() + index * stride * sizeof(double), sizeof(state));
        const auto card = cards[index].toObject();
        const auto quality = state[16];
        const auto clarity = std::clamp(state[17], 0., 1.);
        const auto theme = state[18];
        const auto subdued = std::clamp(state[19], 0., 1.);
        float matrixValues[16];
        for (int i = 0; i < 16; ++i) {
            matrixValues[i] = float(state[i]);
        }
        const QByteArray rootBytes(reinterpret_cast<const char *>(matrixValues), sizeof(matrixValues));
        // 卡片 draw 各自只含一个实例（count=1），但被选中的主体每帧都在移动：
        // 补上稳定 id 之后运动矢量能按 id 取到上一帧矩阵，而不再因为平移列变了就退回当前矩阵、
        // 把速度算成 0。同一 draw 内实例唯一，用卡片 id 即可（部件差异已经体现在 draw id 里）。
        const QVector<quint32> ids{quint32(card["id"].toInt())};
        for (const auto &part : partList) {
            const bool shadowOnly = card["shadowOnly"].toBool();
            if (shadowOnly && !part.castShadow.toBool()) {
                continue;
            }
            auto draw = part.base;
            const auto &high = part.high;
            const auto &low = part.low;
            if (!high.isEmpty() && !low.isEmpty()) {
                draw["color"] = interpolateColor(low["color"].toArray(), high["color"].toArray(), quality);
                draw["attenuation"] =
                    interpolateColor(low["attenuation"].toArray(), high["attenuation"].toArray(), quality);
                draw["attenuationDistance"] =
                    part.interpolateAttenuation
                        ? interpolate(low["attenuationDistance"].toDouble(),
                                      high["attenuationDistance"].toDouble(), quality)
                        : high["attenuationDistance"].toDouble();
                for (const auto &key : {"roughness", "metalness", "transmission", "thickness", "clearcoat",
                                        "clearcoatRoughness"}) {
                    draw[key] = interpolate(low[key].toDouble(), high[key].toDouble(), quality);
                }
                if (high["transmission"].toDouble() > 0) {
                    draw["transmission"] = std::max(0.000001, draw["transmission"].toDouble());
                }
            } else if (high.isEmpty()) {
                draw["opacity"] = quality;
            }
            if (part.frosted) {
                for (const auto &key : {"thickness", "transmission", "attenuationDistance"}) {
                    const auto baseline =
                        interpolate(low.isEmpty() ? high[key].toDouble() : low[key].toDouble(),
                                    high[key].toDouble(), quality);
                    double target = 8;
                    if (std::strcmp(key, "thickness") == 0) {
                        target = .018;
                    } else if (std::strcmp(key, "transmission") == 0) {
                        target = .985;
                    }
                    draw[key] = interpolate(baseline, target, clarity);
                }
            }
            const auto id = -(card["id"].toInt() * 256 + part.partIndex + 1);
            draw["id"] = id;
            draw["mesh"] = part.mesh;
            draw["asset"] = part.asset;
            draw["label"] = part.label;
            draw["name"] = part.name;
            draw["transparent"] = part.transparent;
            draw["depthWrite"] = part.depthWrite;
            draw["order"] = part.order;
            draw["side"] = part.side;
            draw["castShadow"] = part.castShadow;
            draw["musicKey"] = card["musicKey"];
            draw["musicSelected"] = card["selected"];
            draw["shadowOnly"] = shadowOnly;
            draw["instanced"] = false;
            draw["floor"] = false;
            draw["count"] = 1;
            if (high.isEmpty()) {
                draw["quality"] = part.hasMap ? 1 : 0;
            } else {
                draw["quality"] = quality;
            }
            // 没有 high 材质变体的部件也要跟随清晰/磨砂状态；
            // 原先缺省为 0 会让这些部件永远处于磨砂，初始状态就不清晰。
            draw["clarity"] = clarity;
            draw["theme"] = theme;
            draw["subdued"] = high.isEmpty() ? frame["globalSubdued"] : QJsonValue(subdued);
            draw["matrices"] = QJsonArray();
            draw["themes"] = QJsonArray();
            draw["matrixBuffer"] = -1;
            draw["themeBuffer"] = -1;
            QByteArray matrixBytes = rootBytes;
            if (!part.localIdentity) {
                // 使用双精度执行原脚本的矩阵乘法，再压成 GPU Float32，保持同帧数值一致。
                const auto &values = part.localValues;
                for (int column = 0; column < 4; ++column) {
                    for (int row = 0; row < 4; ++row) {
                        double value = 0;
                        for (int k = 0; k < 4; ++k) {
                            value += state[k * 4 + row] * values[column * 4 + k].toDouble();
                        }
                        matrixValues[column * 4 + row] = float(value);
                    }
                }
                matrixBytes = QByteArray(reinterpret_cast<const char *>(matrixValues), sizeof(matrixValues));
            }
            buffers.insert(id, {matrixBytes, {}, ids});
            draws.append(draw);
        }
    }
    auto &hotPath = RhineRender::hotPathWindow();
    hotPath.cardCalls.fetch_add(1);
    hotPath.cards.fetch_add(quint64(cards.size()));
    hotPath.cardParts.fetch_add(quint64(partList.size()));
    hotPath.cardDraws.fetch_add(quint64(draws.size() - initialDraws));
    frame["draws"] = draws;
    frame.remove("actorTemplate");
    frame.remove("actors");
    return {};
}
