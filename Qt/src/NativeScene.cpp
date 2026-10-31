#include "NativeScene.h"
#include "SceneLifetimePolicy.h"
#include "NativeViewer.h"
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <algorithm>
#include <cmath>

namespace {
int wrap(int value, int count) {
    return count > 0 ? (value % count + count) % count : 0;
}
int nearest(int value, int center, int period) {
    return value + int(std::floor(double(center - value + period / 2.0) / period)) * period;
}
}

QJsonObject NativeScene::read(QString path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }
    return QJsonDocument::fromJson(file.readAll()).object();
}

/** 原生场景只读取模型元数据与测量关键帧；几何由 QRhi 和拾取器按需加载。 */
NativeScene::NativeScene(QString root)
    : m_root(root), m_appearance(read(root + "/archive-cassette.json")),
      m_boot(read(":/animation/boot-tracks.json")), m_picking(root) {
    const auto content = read(root + "/slots.json");
    const auto columns = content["columns"].toArray();
    const auto records = content["records"].toArray();
    for (int lane = 0; lane < std::min(5, int(columns.size())); ++lane) {
        for (int index = 0; index < records.size(); ++index) {
            if (records.at(index).toObject()["category"] == columns.at(lane)) {
                m_columns[lane].append(index);
            }
        }
        if (!m_columns[lane].isEmpty()) {
            m_memories[lane] = m_columns[lane].first();
        }
    }
    if (m_appearance.actorTemplate.isEmpty() || m_columns[0].isEmpty()) {
        failure = "Missing native scene assets";
        return;
    }
    m_viewer = std::make_unique<NativeViewer>(root);
    m_actor.position = cellPosition(m_actor.cell);
    m_view = Matrix::camera(m_eye, m_aim).inverse();
    m_projection = Matrix::perspective(m_fov, m_width / m_height, 5, 300);
    m_aoProjection = Matrix::perspective(34, m_width / m_height, 5, 300);
    select(0);
    setMode("boot");
}
NativeScene::~NativeScene() = default;
bool NativeScene::ready() const {
    return failure.isEmpty();
}
int NativeScene::selection() const {
    return m_selected;
}
NativeScene::Cell NativeScene::fileLocation(int index) const {
    for (int lane = 0; lane < 5; ++lane) {
        const auto row = m_columns[lane].indexOf(index);
        if (row >= 0) {
            return {lane, 12 + int(row)};
        }
    }
    return {2, 12};
}
int NativeScene::fileAt(Cell cell) const {
    const auto &files = m_columns[wrap(cell.lane, 5)];
    return files.value(wrap(cell.row - 12, files.size()));
}
NativeScene::Vector NativeScene::cellPosition(Cell cell) const {
    return {(cell.lane - 2) * 5.2, -4.6, (cell.row - 15.5) * 0.62};
}
void NativeScene::pulse(Cell cell) {
    m_pulses.append({cell, m_clock});
    if (m_pulses.size() > 6) {
        m_pulses.remove(0, m_pulses.size() - 6);
    }
}

/** 切换只复制活动卡片根状态；反向选中尚在归位的卡片时继续其真实速度与角度。 */
void NativeScene::select(int index, QJsonObject navigation) {
    m_changed = true;
    if (index < 0 || index >= 40) {
        return;
    }
    if (!m_navigating) {
        resetPointer();
    }
    m_hover.reset();
    m_lastInteraction = m_clock;
    const auto canonical = fileLocation(index);
    auto cell = canonical;
    if (m_looping) {
        const auto explicitCell = navigation["cell"].toObject();
        if (!explicitCell.isEmpty()) {
            cell = {explicitCell["lane"].toInt(), explicitCell["row"].toInt()};
        } else {
            const auto &files = m_columns[canonical.lane];
            cell.row = nearest(canonical.row, m_actor.cell.row, files.size());
            const auto axis = navigation["axis"].toString();
            if (axis == "row") {
                cell.lane = m_actor.cell.lane;
                cell.row = m_actor.cell.row + navigation["direction"].toInt();
            } else {
                cell.lane = axis == "lane" ? m_actor.cell.lane + navigation["direction"].toInt()
                                           : nearest(canonical.lane, m_actor.cell.lane, 5);
            }
        }
    }
    const bool changed = cell != m_actor.cell;
    if (m_looping && changed && m_actor.lift.value > 0.0001) {
        auto old = m_actor;
        old.id = m_nextActor++;
        old.returnY = old.rotation.y != 0 ? std::optional<double>(old.position.y) : std::nullopt;
        old.quality = SceneMotion::smooth(old.lift.value / 0.4);
        old.clarity = m_reduced ? m_targetDetail : m_decryption.clarity;
        old.theme = m_theme.sample(old.cell, m_clock);
        old.age = 0;
        // E04：同一格只留一份归位。快速来回时同一张卡会被复制多次，它们位置完全重合，
        // 却各自建标签/封面、各自展开部件——这是"活跃资源"被放大的直接来源。
        for (int index = m_returning.size() - 1; index >= 0; --index) {
            if (m_returning[index].cell == old.cell) {
                m_returning.removeAt(index);
            }
        }
        m_returning.append(old);
        m_actor.lift = {};
    }
    m_selected = index;
    m_memories[canonical.lane] = index;
    m_actor.cell = cell;
    if (changed) {
        m_decryption.select();
        m_rotation = 0;
        m_actor.returnY.reset();
    }
    const auto returning = std::find_if(m_returning.begin(), m_returning.end(),
                                        [cell](const Actor &actor) { return actor.cell == cell; });
    if (returning != m_returning.end()) {
        m_actor.lift = returning->lift;
        m_rotation = returning->rotation.y;
        m_actor.returnY = returning->returnY;
        m_decryption.select(returning->clarity);
        m_returning.erase(returning);
    }
    pulse(cell);
    m_targetRotation = 0;
}
void NativeScene::navigate(QString axis, int direction) {
    const auto location = fileLocation(m_selected);
    if (axis == "lane") {
        select(m_memories[wrap(location.lane + direction, 5)], {{"axis", axis}, {"direction", direction}});
    } else {
        const auto &files = m_columns[location.lane];
        const auto index = wrap(files.indexOf(m_selected) + direction, files.size());
        select(files.at(index), {{"axis", "row"}, {"direction", direction}});
    }
}
void NativeScene::setMode(QString mode) {
    m_changed = true;
    m_sceneFreeze.reset();
    m_mode = mode;
    resetPointer();
    m_hover.reset();
    if (mode == "detail") {
        m_decryption.enter(m_scanBlend > 0.9 && m_decryption.clarity > 0.999);
    } else {
        m_decryption.leave();
    }
    if (mode == "boot") {
        m_decryption.select();
        m_bootStart = m_clock - 1.76;
    }
    m_looping = mode != "boot";
    if (!m_looping) {
        m_actor.cell = fileLocation(m_selected);
        m_origin = {};
        m_returning.clear();
    }
    m_lastInteraction = m_clock;
    m_targetReveal = mode == "boot" ? 0 : 1;
    m_targetDetail = mode == "detail" ? 1 : 0;
    m_dragging = false;
    if (mode != "detail") {
        m_targetRotation = 0;
        if (m_rotation != 0) {
            m_actor.returnY = m_actor.position.y;
        }
    } else {
        m_actor.returnY.reset();
    }
}
void NativeScene::theme(bool dark) {
    m_changed = true;
    m_theme.set(dark, m_clock, m_actor.cell);
}
void NativeScene::reduced(bool value) {
    m_changed = true;
    if (value && !m_reduced) {
        resetPointer();
        m_pointer = {};
        m_pulses.clear();
        m_idleGain = 0;
        for (auto &actor : m_returning) {
            actor.clarity = 0;
        }
    }
    m_reduced = value;
    m_viewer->reduced(value);
}
void NativeScene::resize(double width, double height) {
    m_changed = true;
    m_width = std::max(1.0, width);
    m_height = std::max(1.0, height);
    m_aoProjection = m_projection;
    m_projection = Matrix::perspective(m_fov, m_width / m_height, 5, 300);
    m_viewer->resize(m_width, m_height);
}
void NativeScene::energyIdle(bool value) {
    m_energyIdle = value;
}
void NativeScene::musicIdentity(QString key) {
    m_changed = true;
    m_actor.musicKey = key;
}
void NativeScene::musicClear() {
    m_changed = true;
    m_actor.musicKey.clear();
    for (auto &actor : m_returning) {
        actor.musicKey.clear();
    }
}
void NativeScene::freeze(std::optional<double> time) {
    m_changed = true;
    m_freeze = time;
}
void NativeScene::trimMemory() {
    m_fieldCache.squeeze();
    m_hoverLifts.squeeze();
    m_returning.squeeze();
    m_viewer->trimMemory();
    m_picking.trimMemory();
}
bool NativeScene::review(QString mode) {
    m_last = 0;
    m_clock = 0;
    m_actor = {};
    m_actor.position = cellPosition(m_actor.cell);
    m_returning.clear();
    m_pulses.clear();
    m_rail = {};
    m_shoulder = {12, 0};
    m_laneFocus = {2, 0};
    m_columnCamera = {};
    m_reveal = 0;
    m_detail = 0;
    m_rotation = 0;
    m_eye = {-62.26, 35.98, 43.28};
    m_aim = {-0.5, 1.1, 0.4};
    m_fov = 6.15;
    m_aoProjection = Matrix::perspective(34, m_width / m_height, 5, 300);
    m_decryption = {};
    m_theme = {};
    m_scanTime = 29.1;
    m_scanBlend = 0;
    m_looping = false;
    select(0);
    if (mode == "viewer" || mode == "viewer-back") {
        // 查看封面页叠在详情页之上：先进详情，再打开装配视图，离线验收才能截到封面。
        setMode("detail");
        m_viewer->open(m_clock);
        if (mode == "viewer-back") {
            // 展开并把装配体转到背面，用来验收封面纸背的渲染结果。
            m_viewer->action("explode", m_clock);
            m_viewer->pointer("pointerdown", 0, 0, 0);
            m_viewer->pointer("pointermove", -m_height / 1.3, 0, 0);
            m_viewer->pointer("pointerup", 0, 0, 0);
        }
    } else {
        setMode(mode);
    }
    for (int index = 1; index <= 120; ++index) {
        update(index / 60.0, std::nullopt);
    }
    update(2.1, std::nullopt);
    update(2.101, std::nullopt);
    m_sceneFreeze = 2.101;
    return ready();
}
