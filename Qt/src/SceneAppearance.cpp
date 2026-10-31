#include "SceneAppearance.h"
#include <QColor>
#include <atomic>
#include <cmath>
#include <numbers>

namespace {
// Optical_Film 是包在唱片外的那层透明光学包裹，不能隐藏：隐藏后画面会少一层，
// 详情页与查看封面页的玻璃包裹感也随之消失。
const QSet<QString> hidden{"Internal_Ceramic",    "Optical_Edges", "Subsurface_Optics", "Optical_Film_Edge",
                           "Amber_Optical_Inlay", "Champagne_Index", "Printed_Label"};
// 实例化只保留构成卡片轮廓的部件。螺丝与贴片在远景卡片上不足一个像素，
// 随 251 份实例绘制会占掉一半几何预算，因此只随焦点卡片绘制。
const QSet<QString> arrays{"Frosted_Polymer", "Ivory_Edges", "Optical_Diffuser"};
}

QJsonArray SceneAppearance::color(QString hex) {
    const auto value = QColor(hex);
    const auto linear = [](double component) {
        return component < 0.04045 ? component * 0.0773993808
                                   : std::pow(component * 0.9478672986 + 0.0521327014, 2.4);
    };
    return {linear(value.red() / 255.0), linear(value.green() / 255.0), linear(value.blue() / 255.0)};
}
QJsonArray SceneAppearance::blend(const QJsonArray &from, const QJsonArray &to, double amount) {
    QJsonArray result;
    for (int index = 0; index < 3; ++index) {
        const auto start = from.at(index).toDouble();
        result.append(start + (to.at(index).toDouble() - start) * amount);
    }
    return result;
}
QJsonObject SceneAppearance::material(const QJsonObject &source) {
    const auto physical = source["pbrMetallicRoughness"].toObject();
    const auto extensions = source["extensions"].toObject();
    auto base = physical["baseColorFactor"].toArray();
    if (base.isEmpty()) {
        base = {1, 1, 1, 1};
    }
    return {{"color", QJsonArray{base.at(0), base.at(1), base.at(2)}},
            {"roughness", physical["roughnessFactor"].toDouble(1)},
            {"metalness", physical["metallicFactor"].toDouble(1)},
            {"transmission",
             extensions["KHR_materials_transmission"].toObject()["transmissionFactor"].toDouble()},
            {"thickness", extensions["KHR_materials_volume"].toObject()["thicknessFactor"].toDouble()},
            {"ior", extensions["KHR_materials_ior"].toObject()["ior"].toDouble(1.5)},
            {"attenuation", QJsonArray{1, 1, 1}},
            {"attenuationDistance", 1e9},
            {"opacity", base.at(3)},
            {"clearcoat", 0},
            {"clearcoatRoughness", 0}};
}

/** 从 glTF 参数建立一次共享材质模板；实例与抽出卡片共用几何索引，不创建部件对象树。 */
SceneAppearance::SceneAppearance(const QJsonObject &asset) {
    // 每次重建模板都取一个新代号（进程内单调），避免不同实例的模板共用一份解码缓存。
    static std::atomic<quint64> nextRevision{1};
    revision = nextRevision.fetch_add(1);
    const auto meshes = asset["meshes"].toArray();
    int partIndex = 0;
    SceneMath::Vector minimum{1e100, 1e100, 1e100};
    SceneMath::Vector maximum{-1e100, -1e100, -1e100};
    for (int mesh = 0; mesh < meshes.size(); ++mesh) {
        const auto entry = meshes.at(mesh).toObject();
        const auto name = entry["name"].toString();
        if (name == "Carbon_Ink") {
            continue;
        }
        const auto lowBounds = entry["minimum"].toArray();
        const auto highBounds = entry["maximum"].toArray();
        if (lowBounds.size() == 3 && highBounds.size() == 3) {
            minimum = {std::min(minimum.x, lowBounds.at(0).toDouble()),
                       std::min(minimum.y, lowBounds.at(1).toDouble()),
                       std::min(minimum.z, lowBounds.at(2).toDouble())};
            maximum = {std::max(maximum.x, highBounds.at(0).toDouble()),
                       std::max(maximum.y, highBounds.at(1).toDouble()),
                       std::max(maximum.z, highBounds.at(2).toDouble())};
        }
        pickingMeshes.append(mesh);
        const auto index = partIndex++;
        if (hidden.contains(name)) {
            continue;
        }
        const auto source = entry["material"].toObject();
        auto high = material(source);
        if (name == "Frosted_Polymer") {
            high["color"] = color("#fffdfa");
            high["transmission"] = 0.9;
            high["thickness"] = 0.12;
            high["roughness"] = 0.21;
            high["ior"] = 1.46;
            high["attenuation"] = color("#eee6df");
            high["attenuationDistance"] = 2;
        } else if (name == "Ivory_Edges") {
            high["color"] = color("#f0e7df");
            high["roughness"] = 0.31;
            high["transmission"] = 0.65;
            high["thickness"] = 0.04;
        } else if (name == "Optical_Diffuser") {
            high["color"] = color("#e2dad4");
            high["transmission"] = 0;
            high["roughness"] = 0.7;
        }
        QJsonObject low;
        if (arrays.contains(name)) {
            low = high;
            if (name == "Frosted_Polymer") {
                low["transmission"] = 0.78;
                low["color"] = color("#fff7ed");
                low["roughness"] = 0.28;
                low["clearcoat"] = 0.3;
                low["clearcoatRoughness"] = 0.25;
            } else if (name == "Optical_Diffuser") {
                low["color"] = color("#806447");
            } else if (name == "Ivory_Edges") {
                low["transmission"] = 0;
                low["color"] = color("#fff5e9");
                low["roughness"] = 0.38;
            } else if (name == "Index_Inlay") {
                low["color"] = color("#e4d6c5");
                low["metalness"] = 0.05;
            }
        }
        QJsonObject definition{
            {"partIndex", index},
            {"mesh", mesh},
            {"asset", "cassette"},
            {"label", false},
            {"name", name},
            {"transparent", source["alphaMode"] == "BLEND"},
            {"depthWrite", true},
            {"order", 0},
            // 闭合且不参与透射的部件背面被正面完全遮挡，关闭双面渲染省下一整轮几何。
            // 透射材质仍需双面，背面由 backs 通道提供内部反射。
            {"side", entry["closed"].toBool(false) && high["transmission"].toDouble() <= 0.0
                         ? 0
                         : (source["doubleSided"].toBool() ? 2 : 0)},
            {"castShadow", name == "Optical_Diffuser"},
            {"localMatrix", SceneMath::Matrix().json()},
            {"base", high},
            {"high", high},
            {"low", low.isEmpty() ? QJsonValue(QJsonValue::Null) : QJsonValue(low)},
            {"hasMap", false},
            {"interpolateAttenuation", !low.isEmpty() && high["attenuationDistance"].toDouble() < 1e9}};
        actorTemplate.append(definition);
        if (!low.isEmpty()) {
            auto draw = low;
            draw["id"] = mesh + 10;
            draw["mesh"] = mesh;
            draw["asset"] = "cassette";
            draw["instanced"] = true;
            draw["label"] = false;
            draw["floor"] = false;
            draw["transparent"] = false;
            draw["depthWrite"] = true;
            draw["order"] = 0;
            draw["side"] = definition["side"];
            draw["name"] = name;
            draw["castShadow"] = false;
            draw["musicKey"] = QJsonValue::Null;
            draw["musicSelected"] = false;
            draw["shadowOnly"] = false;
            draw["quality"] = 0;
            draw["clarity"] = 0;
            draw["subdued"] = 0;
            draw["theme"] = 0;
            instances.append(draw);
        }
    }
    if (maximum.x >= minimum.x) {
        boundsCenter = (minimum + maximum) * 0.5;
        boundsRadius = (maximum - minimum).length() * 0.5;
    }
    QJsonObject label{{"color", QJsonArray{1, 1, 1}},
                      {"roughness", 1},
                      {"metalness", 0},
                      {"transmission", 0},
                      {"thickness", 0},
                      {"ior", 1.5},
                      {"attenuation", QJsonArray{1, 1, 1}},
                      {"attenuationDistance", 1e9},
                      {"opacity", 0},
                      {"clearcoat", 0},
                      {"clearcoatRoughness", 0}};
    // 卡片正面的装饰文字单独成片：8 倍密度，几何已按卡片局部坐标定位，这里不再施加变换。
    const auto letteringPart = [&](int mesh, const QString &name) {
        actorTemplate.append(QJsonObject{{"partIndex", partIndex++},
                                         {"mesh", mesh},
                                         {"asset", "cassette"},
                                         {"label", false},
                                         {"name", name},
                                         {"transparent", true},
                                         {"depthWrite", false},
                                         {"order", 0},
                                         {"side", 2},
                                         {"castShadow", false},
                                         {"localMatrix", SceneMath::Matrix().json()},
                                         {"base", label},
                                         {"high", QJsonValue::Null},
                                         {"low", QJsonValue::Null},
                                         {"hasMap", true},
                                         {"interpolateAttenuation", false}});
    };
    letteringPart(-6, "Case_Lettering_Front");
    letteringPart(-7, "Case_Lettering_Spine");
    actorTemplate.append(
        QJsonObject{{"partIndex", partIndex},
                    {"mesh", -1},
                    {"asset", "cassette"},
                    {"label", true},
                    {"name", ""},
                    {"transparent", true},
                    {"depthWrite", false},
                    {"order", 0},
                    {"side", 0},
                    {"castShadow", false},
                    {"localMatrix", SceneMath::Matrix::compose({-1.36, 3.04, 0.255}, {}).json()},
                    {"base", label},
                    {"high", QJsonValue::Null},
                    {"low", QJsonValue::Null},
                    {"hasMap", true},
                    {"interpolateAttenuation", false}});
}

QJsonObject SceneAppearance::floor(double theme) const {
    auto result =
        material({{"pbrMetallicRoughness", QJsonObject{{"roughnessFactor", 0.95}, {"metallicFactor", 0}}}});
    result["color"] = blend(color("#d8c9b9"), color("#192125"), theme);
    const QJsonObject fields{
        {"id", 1},
        {"mesh", -1},
        {"asset", "cassette"},
        {"instanced", false},
        {"label", false},
        {"floor", true},
        {"transparent", false},
        {"depthWrite", true},
        {"order", 0},
        {"side", 0},
        {"name", ""},
        {"castShadow", false},
        {"musicKey", QJsonValue::Null},
        {"musicSelected", false},
        {"shadowOnly", false},
        {"count", 1},
        {"matrixBuffer", -1},
        {"themeBuffer", -1},
        {"matrices", SceneMath::Matrix::compose({0, -4.63, 0}, {-std::numbers::pi / 2, 0, 0}).json()},
        {"themes", QJsonArray{}},
        {"quality", 0},
        {"clarity", 0},
        {"subdued", 0},
        {"theme", theme}};
    for (auto entry = fields.begin(); entry != fields.end(); ++entry) {
        result[entry.key()] = entry.value();
    }
    return result;
}
