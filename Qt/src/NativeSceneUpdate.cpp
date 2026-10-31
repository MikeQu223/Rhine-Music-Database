#include "NativeScene.h"
#include "SceneLifetimePolicy.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <numeric>
#include <vector>

namespace {
double lerp(double from, double to, double amount) {
    return (1 - amount) * from + amount * to;
}

// 实例身份取网格坐标而不是列表下标：按距离重排、可见集合增删都不会改变"这块卡片是谁"。
// lane 与 row 各自落在 int16 内（只有超过 2048 才会 rebase 平移坐标系），
// 因此 16+16 位编码在同一帧内不碰撞，跨帧也只跟格子本身绑定。
quint32 cellInstanceId(SceneMotion::Cell cell) {
    return quint32(quint16(cell.lane)) << 16 | quint16(cell.row);
}
}

double NativeScene::field(double row, double lane) const {
    const auto key = qint64(quint64(quint32(qint32(lane))) << 32 | quint32(qint32(row * 2)));
    const auto found = m_fieldCache.constFind(key);
    if (found != m_fieldCache.cend()) {
        return *found;
    }
    auto value = m_field.sample(row, lane);
    if (m_cinema) {
        const auto cinematic =
            SceneMotion::cinematicField(row, lane, m_cinema->time, m_shoulder.value, m_laneFocus.value);
        // 抽取完成后连同周围档案一起收束到常态场景，避免高度基准在模式切换时变化。
        value = lerp(cinematic, value, SceneMotion::smooth((m_cinema->time - 29) / 5));
    }
    m_fieldCache.insert(key, value);
    return value;
}
double NativeScene::hoverLift(Cell cell) const {
    return m_hoverLifts.value(cell.key());
}

/** 一次推进原生根状态、相机与可见实例；归位卡片保留物理状态，不分配几何或材质树。 */
void NativeScene::update(double time, std::optional<Cinema> cinema) {
    auto elapsed = std::max(0.0, time - m_last);
    if (time == m_last) {
        elapsed = 0.016;
    }
    const auto seconds = std::min(elapsed, 0.05);
    m_last = time;
    m_clock = time;
    m_cinema = cinema;
    if (m_pendingHover) {
        if (canBrowse() && !m_momentum) {
            const auto point = *m_pendingHover;
            m_pointer = {point.x() / m_width - 0.5, point.y() / m_height - 0.5};
            m_hover = pick(point.x(), point.y());
            m_cursor = m_hover ? "pointer" : "grab";
        }
        m_pendingHover.reset();
    }
    m_theme.beginFrame();
    const auto blend = 1 - std::exp(-seconds * (m_reduced ? 35 : 2.8));
    m_reveal = cinema ? cinema->reveal : lerp(m_reveal, m_targetReveal, blend);
    m_rotation = m_targetDetail != 0 ? lerp(m_rotation, m_targetRotation, blend)
                                     : SceneMotion::returnStep(m_rotation, seconds, m_reduced);
    const auto shot = cinema ? cinema->time : 29.1;
    if (cinema) {
        m_scanTime = shot;
        m_scanBlend = 1;
    } else {
        m_scanTime += seconds;
        m_scanBlend *= std::exp(-seconds * 3);
    }
    if (!canBrowse()) {
        m_hover.reset();
        if (m_holding || m_momentum) {
            resetPointer();
        }
    }
    if (m_looping && !cinema && !m_holding && !m_momentum) {
        rebase();
    }
    if (!cinema && m_momentum) {
        m_momentum->step(std::clamp(time - m_momentumTime, 0.0, 0.25));
        m_momentumTime = time;
        navigatePlane(m_momentum->value());
        m_lastInteraction = time;
    }
    const auto hoverKey = !cinema && m_hover ? m_hover->key() : QString();
    if (!hoverKey.isEmpty() && !m_hoverLifts.contains(hoverKey)) {
        m_hoverLifts.insert(hoverKey, 0);
    }
    for (auto entry = m_hoverLifts.begin(); entry != m_hoverLifts.end();) {
        const auto target = entry.key() == hoverKey ? 0.28 : 0;
        auto next = cinema ? 0 : lerp(entry.value(), target, 1 - std::exp(-seconds * 14));
        if (!cinema && m_reduced) {
            next = target;
        }
        if (target == 0 && next < 0.0001) {
            entry = m_hoverLifts.erase(entry);
        } else {
            entry.value() = next;
            ++entry;
        }
    }
    const auto chosen = cellPosition(m_actor.cell);
    const auto selectedRow = m_actor.cell.row;
    const auto selectedLane = m_actor.cell.lane;
    m_shoulder.damp(selectedRow, m_reduced ? 35 : 5, seconds);
    m_laneFocus.damp(selectedLane, m_reduced ? 35 : 4, seconds);
    if (!m_holding && !m_momentum) {
        m_columnCamera.damp(chosen.x, m_reduced ? 35 : 3.7, seconds);
        m_rail.damp(cinema ? 0 : -2.17 - chosen.z, m_reduced ? 35 : 3.7, seconds);
    }
    if (!cinema && m_momentum) {
        const auto value = m_momentum->value();
        const auto velocity = m_momentum->velocity();
        m_columnCamera.value = (value.lane - 2) * 5.2;
        m_rail.value = -2.17 - (value.row - 15.5) * 0.62;
        m_columnCamera.velocity = velocity.lane * 5.2;
        m_rail.velocity = -velocity.row * 0.62;
        if (m_momentum->phase() == SceneMotion::ArchiveMomentum::Phase::Idle) {
            m_momentum.reset();
        }
    }
    if (m_dragTrack && !cinema) {
        m_columnCamera = {m_dragTrack->lane, 0};
        m_rail = {m_dragTrack->row, 0};
    }
    if (cinema) {
        // 在仍由镜头跟随主体时完成世界坐标归中，切换后不再横向滑入或沿轨道跳动。
        const auto archiveHandoff = SceneMotion::smooth((shot - 29) / 5);
        m_rail = {(-2.17 - chosen.z) * archiveHandoff, 0};
        m_actor.lift = {SceneMotion::extraction(shot), 0};
        m_shoulder.value = selectedRow;
        m_laneFocus = {double(selectedLane), 0};
        m_columnCamera = {chosen.x * archiveHandoff, 0};
    }
    const auto trackX = m_columnCamera.value;
    m_pulses.removeIf([time](const Pulse &pulse) { return time - pulse.time >= 3.2; });
    const bool aligningCopy = std::any_of(m_returning.cbegin(), m_returning.cend(),
                                          [](const Actor &actor) { return actor.returnY.has_value(); });
    const bool idle = !cinema && !m_reduced && !m_energyIdle && m_targetReveal > 0 && m_targetDetail == 0 &&
                      m_detail < 0.01 && !m_actor.returnY && !aligningCopy && time - m_lastInteraction > 2.5;
    m_idleGain = cinema ? 0 : lerp(m_idleGain, idle ? 1 : 0, 1 - std::exp(-seconds * (idle ? 0.8 : 4)));
    m_pulseGain = lerp(m_pulseGain, m_targetDetail != 0 || m_actor.returnY || aligningCopy ? 0 : 1,
                       1 - std::exp(-seconds * 8));
    m_field.origin = m_origin;
    m_field.scanTime = m_scanTime;
    m_field.scanBlend = m_scanBlend;
    m_field.shoulder = m_shoulder.value;
    m_field.laneFocus = m_laneFocus.value;
    m_field.idleGain = m_idleGain;
    m_field.time = time;
    m_field.pulseGain = m_pulseGain;
    m_field.selectionWave = !m_reduced;
    m_field.pulses = m_pulses;
    m_fieldCache.clear();
    const auto selectedBase = chosen.y + field(selectedRow, selectedLane);
    if (!cinema) {
        if (m_actor.returnY && m_rotation != 0) {
            m_actor.lift = {*m_actor.returnY - selectedBase, 0};
        } else {
            m_actor.returnY.reset();
            double target = 0.4 * m_targetReveal;
            if (m_targetDetail != 0) {
                target = 4.05;
            } else if (std::any_of(m_returning.cbegin(), m_returning.cend(),
                                   [selectedLane, selectedRow](const Actor &actor) {
                                       return actor.returnY && actor.cell.lane == selectedLane &&
                                              std::abs(actor.cell.row - selectedRow) < 5;
                                   })) {
                target = 0;
            }
            m_actor.lift.damp(target, m_reduced ? 35 : 4.2, seconds);
        }
    }
    double cameraTarget;
    if (m_targetDetail != 0) {
        cameraTarget = SceneMotion::smooth((m_actor.lift.value - 0.8) / 2.4);
    } else if (m_actor.returnY) {
        cameraTarget = m_detail;
    } else {
        cameraTarget = SceneMotion::smooth((m_actor.lift.value - 0.4) / (4.05 - 0.4));
    }
    m_detail = cinema ? cinema->zoom : lerp(m_detail, cameraTarget, blend);
    m_decryption.update(seconds, m_detail > 0.78 && m_actor.lift.value > 3.3, false,
                        cinema ? std::optional<double>(shot + 5) : std::nullopt);
    m_actor.quality = SceneMotion::smooth(m_actor.lift.value / 0.4);
    m_actor.clarity = m_reduced && !cinema ? m_targetDetail : m_decryption.clarity;
    const auto entry = cinema ? SceneMotion::smooth((shot - 21.9) / 0.86) : m_reveal;
    const auto entranceTime = std::clamp((shot - 21.92) / 0.75, 0.0, 1.0);
    const auto entryZ = cinema ? -23 * std::pow(1 - entranceTime, 2) : -28 * (1 - entry);
    for (int index = m_returning.size() - 1; index >= 0; --index) {
        auto &actor = m_returning[index];
        actor.age += seconds;
        const auto position = cellPosition(actor.cell);
        const auto baseY = position.y + field(actor.cell.row, actor.cell.lane);
        actor.rotation.y = SceneMotion::returnStep(actor.rotation.y, seconds, m_reduced);
        if (actor.returnY) {
            actor.lift = {*actor.returnY - baseY, 0};
            if (actor.rotation.y == 0) {
                actor.returnY.reset();
            }
        } else {
            // E04：改用与帧率无关的指数衰减；`Spring::damp` 的每步乘子会让 60 fps 下
            // 的实际时间常数落到约 6 秒，归位卡片因此滞留近一分钟。
            actor.lift.value = SceneLifetime::returningLiftStep(actor.lift.value, seconds, m_reduced);
            actor.lift.velocity = 0;
        }
        actor.position = {position.x - trackX, baseY + actor.lift.value + hoverLift(actor.cell),
                          position.z + entryZ + m_rail.value};
        actor.quality = SceneMotion::smooth(actor.lift.value / 0.4);
        actor.clarity = m_reduced ? 0 : actor.clarity * std::exp(-seconds * 9);
        actor.theme = m_theme.sample(actor.cell, time);
        actor.rotation.x =
            (field(actor.cell.row + 0.5, actor.cell.lane) - field(actor.cell.row - 0.5, actor.cell.lane)) *
            0.024 * (1 - m_detail) * (1 - actor.quality);
        if (actor.lift.value < 0.0001 && std::abs(actor.rotation.y) < 0.0001) {
            m_returning.removeAt(index);
        }
    }
    m_actor.theme = m_theme.sample(m_actor.cell, time);
    m_actor.position = {chosen.x - trackX, selectedBase + m_actor.lift.value + hoverLift(m_actor.cell),
                        chosen.z + entryZ + m_rail.value};
    m_actor.rotation = {(field(selectedRow + 0.5, selectedLane) - field(selectedRow - 0.5, selectedLane)) *
                            0.024 * (1 - m_detail) * (1 - m_actor.quality),
                        cinema ? 0 : m_rotation, 0};
    updateCamera(seconds, cinema);
    const bool fixed = cinema.has_value() || !m_looping;
    if (fixed) {
        m_cells.clear();
        for (int index = 0; index < 160; ++index) {
            m_cells.append({index / 32, index % 32});
        }
    } else {
        m_cells = visibleCells(trackX, entryZ + m_rail.value);
    }
    const SceneMath::Frustum coverage(m_projection * m_view);
    QByteArray visibleMatrices;
    QByteArray themes;
    // 与 visibleMatrices 同步增长的逐实例 id，条数必须严格对齐，运动矢量才敢按下标配对。
    QVector<quint32> instanceIds;
    m_drawnCells.clear();
    m_drawnMatrices.clear();
    auto candidateProjection =
        Matrix::perspective(m_fov, m_width / m_height, 5, std::min(300.0, std::max(6.0, m_fogFar + 8)));
    candidateProjection.values[0] /= 1.18;
    candidateProjection.values[5] /= 1.18;
    const SceneMath::Frustum candidates(candidateProjection * m_view);
    for (const auto cell : m_cells) {
        if (cell == m_actor.cell || std::any_of(m_returning.cbegin(), m_returning.cend(),
                                                [cell](const Actor &actor) { return actor.cell == cell; })) {
            continue;
        }
        const Vector position{(cell.lane - 2) * 5.2 - trackX,
                              -4.6 + field(cell.row, cell.lane) + hoverLift(cell),
                              (cell.row - 15.5) * 0.62 + entryZ + m_rail.value};
        // 候选范围的视锥比颜色覆盖更宽，保留屏幕外的投影物体。
        if (!fixed && !intersectsCard(candidates, position)) {
            continue;
        }
        const auto slope = field(cell.row + 0.5, cell.lane) - field(cell.row - 0.5, cell.lane);
        const auto matrix = Matrix::compose(position, {slope * 0.024 * (1 - m_detail), 0, 0});
        if (!intersectsCard(coverage, position)) {
            continue;
        }
        m_drawnCells.append(cell);
        m_drawnMatrices.append(matrix);
        visibleMatrices.append(matrix.bytes());
        instanceIds.append(cellInstanceId(cell));
        const auto theme = float(m_theme.sample(cell, time));
        themes.append(reinterpret_cast<const char *>(&theme), sizeof(theme));
    }
    // 不透明实例按相机距离前到后重排：early-z 能提前拒绝被遮挡片元，
    // 避免 251 层卡片把昂贵的表面着色重复执行十余次。顺序不影响不透明结果。
    if (m_drawnCells.size() > 1) {
        std::vector<int> order(size_t(m_drawnCells.size()));
        std::iota(order.begin(), order.end(), 0);
        const auto distance = [&](int index) {
            const auto &value = m_drawnMatrices[index].values;
            const auto dx = value[12] - m_eye.x;
            const auto dy = value[13] - m_eye.y;
            const auto dz = value[14] - m_eye.z;
            return dx * dx + dy * dy + dz * dz;
        };
        std::stable_sort(order.begin(), order.end(),
                         [&](int left, int right) { return distance(left) < distance(right); });
        // 视角与批次不变时顺序已经是从近到远，跳过重建，静止画面下每帧零分配。
        bool reordered = false;
        for (size_t index = 0; index < order.size(); ++index) {
            if (order[index] != int(index)) {
                reordered = true;
                break;
            }
        }
        if (reordered) {
            QVector<Cell> cells;
            QVector<Matrix> matrices;
            QByteArray sortedMatrices;
            QByteArray sortedThemes;
            QVector<quint32> sortedIds;
            cells.reserve(m_drawnCells.size());
            matrices.reserve(m_drawnMatrices.size());
            sortedMatrices.reserve(visibleMatrices.size());
            sortedThemes.reserve(themes.size());
            sortedIds.reserve(instanceIds.size());
            for (const auto index : order) {
                cells.append(m_drawnCells[index]);
                matrices.append(m_drawnMatrices[index]);
                sortedMatrices.append(m_drawnMatrices[index].bytes());
                sortedThemes.append(themes.constData() + index * int(sizeof(float)), sizeof(float));
                sortedIds.append(instanceIds[index]);
            }
            m_drawnCells = cells;
            m_drawnMatrices = matrices;
            visibleMatrices = sortedMatrices;
            themes = sortedThemes;
            instanceIds = sortedIds;
        }
    }
    drawBuffers[10] = {visibleMatrices, themes, instanceIds};
    double neighborTop = -1e100;
    for (int row = selectedRow - 5; row <= selectedRow + 5; ++row) {
        if (row != selectedRow) {
            neighborTop = std::max(neighborTop, -4.6 + field(row, selectedLane) + 3.76);
        }
    }
    for (const auto &actor : m_returning) {
        if (actor.cell.lane == selectedLane && std::abs(actor.cell.row - selectedRow) <= 5) {
            neighborTop = std::max(neighborTop, actor.position.y + 3.76);
        }
    }
    m_clearance = m_actor.position.y - neighborTop;
    m_canInspect =
        !cinema && m_targetDetail != 0 && m_detail > 0.9 && m_pulseGain < 0.01 && m_clearance > 0.3;
    const auto focal = m_view.point(m_actor.position + Vector{0, 2, 0});
    m_focus = -focal.z;
    m_aperture = lerp(0.0003, 0.0008, m_detail);
}
