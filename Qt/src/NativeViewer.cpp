#include "NativeViewer.h"
#include <QFile>
#include <QJsonDocument>
#include <algorithm>
#include <cmath>
#include <numbers>

namespace {
const QVector<QPair<QString, double>> parts{{"fasteners", 2.75},      {"cover", 1.85},
                                            {"optical-lenses", 0.75}, {"optical-core", -0.15},
                                            {"substrate", -1.1},      {"carrier", -2.05}};
double lerp(double from, double to, double amount) {
    return (1 - amount) * from + amount * to;
}
}
NativeViewer::NativeViewer(QString root) : m_root(root) {
    m_pose = spherical(m_eye);
    m_goal = m_pose;
}
bool NativeViewer::isOpen() const {
    return m_open;
}
bool NativeViewer::pending() const {
    return m_open && (m_closing || m_time < m_pendingUntil);
}
NativeViewer::Spherical NativeViewer::spherical(Vector value) {
    const auto radius = value.length();
    if (radius == 0) {
        return {0, 0, 0};
    }
    return {radius, std::acos(std::clamp(value.y / radius, -1.0, 1.0)), std::atan2(value.x, value.z)};
}
NativeViewer::Vector NativeViewer::vector(Spherical value) {
    const auto sine = std::sin(value.phi) * value.radius;
    return {sine * std::sin(value.theta), std::cos(value.phi) * value.radius, sine * std::cos(value.theta)};
}

/** 查看器只在打开时读取装配元数据，关闭后保留小型参数并释放模板。 */
void NativeViewer::open(double time) {
    if (m_open) {
        return;
    }
    m_open = true;
    m_closing = false;
    m_transition = "opening";
    m_time = time;
    m_pendingUntil = m_reduced ? time : time + 0.38;
    m_spread = {};
    m_targetSpread = 0;
    m_clarity = {1, 0};
    m_targetClarity = 1;
    m_surface = "clear";
    m_last = 0;
    reset(false);
    if (m_meshes.isEmpty()) {
        QFile source(m_root + "/archive-assembly.json");
        if (source.open(QIODevice::ReadOnly)) {
            m_meshes = QJsonDocument::fromJson(source.readAll()).object()["meshes"].toArray();
        }
    }
    m_ready = !m_meshes.isEmpty();
    update(0, m_theme);
    m_time = time;
}
void NativeViewer::resize(double width, double height) {
    m_width = width;
    m_height = height;
}
void NativeViewer::reduced(bool value) {
    m_reduced = value;
    if (value) {
        m_pendingUntil = m_time;
        m_clarity = {m_targetClarity, 0};
        m_spread = {m_targetSpread, 0};
    }
}
void NativeViewer::reset(bool animated) {
    m_target = {};
    m_goal = spherical({7.2, 3.8, 12});
    if (animated && !m_reduced) {
        m_resetFrom = m_pose;
        m_resetFocus = m_focus;
        m_resetElapsed = 0;
        m_resetting = true;
    } else {
        m_pose = m_goal;
        m_focus = m_target;
        m_eye = vector(m_pose) + m_focus;
        m_resetting = false;
    }
}
void NativeViewer::interrupt() {
    if (m_resetting) {
        m_resetting = false;
        m_goal = m_pose;
        m_target = m_focus;
    }
}
void NativeViewer::coverFront(bool front) {
    interrupt();
    const auto distance = Vector{7.2, 3.8, 12}.length();
    m_goal = spherical({0, 0, front ? distance : -distance});
    m_target = {};
    m_pose = m_goal;
    m_focus = {};
    m_eye = vector(m_pose);
}
void NativeViewer::action(QString action, double time) {
    if (!m_open || m_closing) {
        return;
    }
    if (action == "close") {
        m_closing = true;
        m_dragging = false;
        m_transition = "closing";
        m_closeAt = m_reduced ? time : time + 0.22;
        return;
    }
    if (!m_ready) {
        return;
    }
    if (action == "clear" || action == "frosted") {
        m_targetClarity = action == "clear" ? 1 : 0;
        m_surface = action;
    } else if (action == "explode" || action == "assemble") {
        m_targetSpread = action == "explode" ? 1 : 0;
    } else if (action == "reset") {
        reset(true);
    }
}
void NativeViewer::key(QString key, double time) {
    if (key == "Escape") {
        action("close", time);
        return;
    }
    if (!m_ready || m_closing) {
        return;
    }
    if (key == "Home") {
        reset(true);
        return;
    }
    interrupt();
    if (QStringList{"+", "=", "-"}.contains(key)) {
        m_goal.radius = std::clamp(m_goal.radius * (key == "-" ? 1.12 : 1 / 1.12), 5.0, 28.0);
        return;
    }
    const auto camera = Matrix::camera(m_eye, m_focus);
    const Vector right{camera.values[0], camera.values[1], camera.values[2]};
    const Vector up{camera.values[4], camera.values[5], camera.values[6]};
    Vector delta;
    const auto step = m_goal.radius * 0.025;
    if (key == "ArrowLeft") {
        delta = right * -step;
    } else if (key == "ArrowRight") {
        delta = right * step;
    } else if (key == "ArrowUp") {
        delta = up * step;
    } else if (key == "ArrowDown") {
        delta = up * -step;
    }
    m_target = m_target + delta;
    if (m_target.length() > 5) {
        m_target = m_target.normalized() * 5;
    }
}
void NativeViewer::pointer(QString type, double x, double y, double delta) {
    if (!m_ready || m_closing) {
        return;
    }
    if (type == "pointerdown") {
        interrupt();
        m_dragging = true;
        m_previous = {x, y};
    } else if (type == "pointermove" && m_dragging) {
        m_goal.theta -= 2 * std::numbers::pi * (x - m_previous.x()) * 0.65 / m_height;
        m_goal.phi = std::clamp(m_goal.phi - 2 * std::numbers::pi * (y - m_previous.y()) * 0.65 / m_height,
                                0.000001, std::numbers::pi - 0.000001);
        m_previous = {x, y};
    } else if (type == "pointerup" || type == "pointercancel") {
        m_dragging = false;
    } else if (type == "wheel") {
        interrupt();
        const auto scale = std::pow(0.95, 0.7 * std::abs(delta) * 0.01);
        m_goal.radius = std::clamp(m_goal.radius * (delta < 0 ? scale : 1 / scale), 5.0, 28.0);
    } else if (type == "pan") {
        // 双指拖动平移（Overlay.qml 的 PinchHandler 转发）：x/y 是舞台像素增量。
        // 沿相机右/上向量**一次合成**移动注视点——dx 与 dy 同时生效，任意斜向
        // 平移都是一条直线；不做轴向吸附，也不拆成两步（两步会被焦点弹簧插成折线）。
        // 语义是「拖动内容」：手指右移（dx>0）→ 内容右移 → 注视点沿 -right；
        // 手指下移（dy>0，屏幕 y 向下为正）→ 内容下移 → 注视点沿 +up。
        // 焦点平面的世界尺寸 = 2*radius*tan(fov/2)，与 frame() 的 perspective(34°)
        // 一致，保证手指位移与画面位移约 1:1 跟手；灵敏度随缩放半径自适应。
        interrupt();
        const auto camera = Matrix::camera(m_eye, m_focus);
        const Vector right{camera.values[0], camera.values[1], camera.values[2]};
        const Vector up{camera.values[4], camera.values[5], camera.values[6]};
        const auto span = 2 * m_goal.radius * std::tan(34.0 * std::numbers::pi / 360.0);
        const auto worldPerPixel = span / m_height;
        m_target = m_target + right * (-x * worldPerPixel) + up * (y * worldPerPixel);
        if (m_target.length() > 5) {
            m_target = m_target.normalized() * 5;
        }
    }
}

/** 请求姿态与实际相机分离；球面和对数半径插值保留旋转、缩放及复位时的连续运动。 */
void NativeViewer::update(double time, double theme) {
    if (!m_open) {
        return;
    }
    m_time = time;
    m_theme = theme;
    if (m_closing && time >= m_closeAt) {
        m_open = false;
        m_closing = false;
        m_ready = false;
        m_meshes = {};
        m_transition = "closed";
        return;
    }
    if (!m_closing && time >= m_pendingUntil) {
        m_transition = "open";
    }
    const auto seconds = std::min(m_last != 0 ? time - m_last : 1.0 / 60, 0.05);
    m_last = time;
    if (m_reduced) {
        m_clarity = {m_targetClarity, 0};
        m_spread = {m_targetSpread, 0};
    } else {
        m_clarity.damp(m_targetClarity, 8, seconds);
        m_spread.damp(m_targetSpread, 5.5, seconds);
    }
    if (std::abs(m_clarity.value - m_targetClarity) < 0.0001 && std::abs(m_clarity.velocity) < 0.001) {
        m_clarity = {m_targetClarity, 0};
    }
    if (std::abs(m_spread.value - m_targetSpread) < 0.0001 && std::abs(m_spread.velocity) < 0.001) {
        m_spread = {m_targetSpread, 0};
    }
    const auto interpolate = [this](Spherical from, Spherical to, double angle, double radius) {
        m_pose.radius = std::exp(lerp(std::log(from.radius), std::log(to.radius), radius));
        m_pose.phi = std::clamp(lerp(from.phi, to.phi, angle), 0.000001, std::numbers::pi - 0.000001);
        m_pose.theta =
            from.theta + std::atan2(std::sin(to.theta - from.theta), std::cos(to.theta - from.theta)) * angle;
    };
    if (m_reduced) {
        m_pose = m_goal;
        m_focus = m_target;
    } else if (m_resetting) {
        m_resetElapsed += std::max(0.0, seconds);
        const auto time = std::min(1.0, m_resetElapsed / 0.56);
        const auto amount = 1 - std::pow(1 - time, 3);
        m_focus = m_resetFocus.lerp(m_target, amount);
        interpolate(m_resetFrom, m_goal, amount, amount);
        if (time == 1) {
            m_resetting = false;
        }
    } else {
        const auto pan = 1 - std::exp(-13 * std::max(0.0, seconds));
        m_focus = m_focus.lerp(m_target, pan);
        interpolate(m_pose, m_goal, 1 - std::exp(-9 * std::max(0.0, seconds)),
                    1 - std::exp(-15 * std::max(0.0, seconds)));
        const auto delta = m_focus - m_target;
        if (delta.dot(delta) < 1e-10) {
            m_focus = m_target;
        }
    }
    m_eye = vector(m_pose) + m_focus;
}
void NativeViewer::trimMemory() {
    if (!m_open) {
        m_meshes = {};
    }
}

QJsonObject NativeViewer::frame(QJsonObject base, const SceneAppearance &appearance,
                                SceneDrawBuffers &buffers) {
    if (!m_open) {
        return base;
    }
    base["viewer"] = true;
    base["viewerReady"] = m_ready;
    base["near"] = 0.3;
    base["far"] = 120;
    base["view"] = Matrix::camera(m_eye, m_focus).inverse().json();
    base["eye"] = m_eye.json();
    auto projection = Matrix::perspective(34, m_width / m_height, 0.3, 120);
    if (m_width / m_height < 1.05) {
        const auto zoom = std::min(1.15, m_width / m_height / 0.85) / (1 + 0.08 * m_spread.value);
        projection.values[0] *= zoom;
        projection.values[5] *= zoom;
    }
    base["projection"] = projection.json();
    base["fogNear"] = std::max(0.0, m_eye.length() - 1);
    base["fogFar"] = m_eye.length() + 12;
    QJsonArray templateParts;
    for (const auto &[partName, depth] : parts) {
        for (int mesh = 0; mesh <= m_meshes.size(); ++mesh) {
            const bool label = mesh == m_meshes.size();
            const auto entry =
                label ? QJsonObject{{"name", ""}, {"assemblyPart", "cover"}} : m_meshes.at(mesh).toObject();
            if (entry["assemblyPart"] != partName) {
                continue;
            }
            for (const auto &value : appearance.actorTemplate) {
                auto part = value.toObject();
                if (part["label"].toBool() != label || (!label && part["name"] != entry["name"])) {
                    continue;
                }
                part["partIndex"] = templateParts.size();
                part["mesh"] = label ? -1 : mesh;
                part["asset"] = label ? "cassette" : "assembly";
                // 封面纸片在装配视图里会转到背面：双面渲染，背面由着色器画成素面封底。
                part["side"] = label ? 2 : part["side"].toInt();
                part["castShadow"] = false;
                auto position = label ? Vector{-1.36, 3.04, 0.255} : Vector{};
                position.z += depth * m_spread.value;
                part["localMatrix"] = Matrix::compose(position, {}).json();
                templateParts.append(part);
                break;
            }
        }
    }
    base["draws"] = QJsonArray{};
    base["actorTemplate"] = templateParts;
    base["actors"] = QJsonArray{QJsonObject{
        {"id", 100000}, {"musicKey", QJsonValue::Null}, {"selected", true}, {"shadowOnly", false}}};
    std::array<double, 20> state;
    const auto root = Matrix::compose({0, -1.85, 0}, {});
    std::copy(root.values.begin(), root.values.end(), state.begin());
    state[16] = 1;
    state[17] = m_clarity.value;
    state[18] = m_theme;
    state[19] = 0;
    m_cards.expand(base, QByteArray(reinterpret_cast<const char *>(state.data()), sizeof(state)), buffers);
    QJsonObject stats{{"ready", m_ready},
                      {"clarity", m_clarity.value},
                      {"targetClarity", m_targetClarity},
                      {"spread", m_spread.value},
                      {"target", m_targetSpread},
                      {"distance", m_pose.radius},
                      {"targetPosition", m_focus.json()},
                      {"requestedTarget", m_target.json()},
                      {"requestedDistance", m_goal.radius},
                      {"cameraPosition", m_eye.json()},
                      {"resetting", m_resetting},
                      {"azimuth", m_goal.theta},
                      {"polar", m_goal.phi}};
    base["viewerState"] =
        QJsonObject{{"transition", m_transition},
                    {"surface", m_surface},
                    {"exploded", m_targetSpread == 1 ? "true" : "false"},
                    {"stats", QString::fromUtf8(QJsonDocument(stats).toJson(QJsonDocument::Compact))}};
    return base;
}
