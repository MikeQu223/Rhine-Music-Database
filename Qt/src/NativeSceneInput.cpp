#include "NativeScene.h"
#include "NativeViewer.h"
#include <algorithm>
#include <cmath>

bool NativeScene::canBrowse() const {
    return m_looping && m_targetDetail == 0 && m_detail < 0.2 && m_reveal >= 0.8;
}
void NativeScene::resetPointer(bool stopMomentum) {
    m_pendingHover.reset();
    m_captured = false;
    m_dragging = false;
    m_dragTrack.reset();
    m_holding = false;
    m_browsing = false;
    m_hover.reset();
    if (stopMomentum && m_momentum) {
        m_columnCamera.velocity = 0;
        m_rail.velocity = 0;
        m_momentum.reset();
    }
    m_cursor = canBrowse() ? "grab" : "default";
}
SceneMotion::DragProjection NativeScene::dragProjection() const {
    const auto center = Matrix::compose(m_actor.position, m_actor.rotation).point({0, 1.85, 0});
    const auto projection = m_projection * m_view;
    const auto project = [&](Vector motion) {
        const auto from = projection.point(center + motion * -0.5);
        const auto to = projection.point(center + motion * 0.5);
        return QPointF((to.x - from.x) * m_width / 2, -(to.y - from.y) * m_height / 2);
    };
    return {project({-5.2, 0, 0}), project({0, 0, -0.62})};
}

/** 用同一批可见实例做拾取；先检查卡片边界，再访问原生 BVH，不遍历部件对象树。 */
std::optional<NativeScene::Cell> NativeScene::pick(double x, double y) {
    const auto inverse = (m_projection * m_view).inverse();
    const auto direction =
        (inverse.point({x / m_width * 2 - 1, -y / m_height * 2 + 1, 0.5}) - m_eye).normalized();
    double nearest = 1e100;
    std::optional<Cell> result;
    const auto card = [&](const Matrix &matrix, Cell cell, bool allMeshes) {
        const auto inverse = matrix.inverse();
        const auto origin = inverse.point(m_eye);
        const auto localDirection = inverse.direction(direction);
        // 保守边界包含原壳体、印刷与倾斜；只排除射线不可能到达的卡片。
        const double starts[]{origin.x, origin.y, origin.z};
        const double directions[]{localDirection.x, localDirection.y, localDirection.z};
        const double minimum[]{-2.8, -0.3, -1.2};
        const double maximum[]{2.8, 4.1, 1.2};
        double low = -1e100;
        double high = 1e100;
        for (int axis = 0; axis < 3; ++axis) {
            if (directions[axis] == 0) {
                if (starts[axis] < minimum[axis] || starts[axis] > maximum[axis]) {
                    return;
                }
                continue;
            }
            auto first = (minimum[axis] - starts[axis]) / directions[axis];
            auto last = (maximum[axis] - starts[axis]) / directions[axis];
            if (first > last) {
                std::swap(first, last);
            }
            low = std::max(low, first);
            high = std::min(high, last);
        }
        if (low > high || high < 0 || low > nearest) {
            return;
        }
        const QVariantList originValues{origin.x, origin.y, origin.z};
        const QVariantList directionValues{localDirection.x, localDirection.y, localDirection.z};
        for (const auto mesh : m_appearance.pickingMeshes) {
            if (!allMeshes && mesh != 0) {
                continue;
            }
            const auto hit = m_picking.raycast(mesh, originValues, directionValues, 2);
            if (hit.isEmpty()) {
                continue;
            }
            const auto point = matrix.point({hit["x"].toDouble(), hit["y"].toDouble(), hit["z"].toDouble()});
            const auto distance = (point - m_eye).length();
            if (distance >= 5 && distance <= 300 && distance < nearest) {
                nearest = distance;
                result = cell;
            }
        }
    };
    for (int index = 0; index < m_drawnCells.size(); ++index) {
        card(m_drawnMatrices.at(index), m_drawnCells.at(index), false);
    }
    card(Matrix::compose(m_actor.position, m_actor.rotation), m_actor.cell, true);
    for (const auto &actor : m_returning) {
        card(Matrix::compose(actor.position, actor.rotation), actor.cell, true);
    }
    return result;
}

void NativeScene::navigatePlane(SceneMotion::DragPosition coordinate) {
    const Cell goal{int(std::floor(coordinate.lane + 0.5)), int(std::floor(coordinate.row + 0.5))};
    const auto from = m_actor.cell;
    if (goal == from) {
        return;
    }
    const auto steps = std::min(64, std::max(std::abs(goal.lane - from.lane), std::abs(goal.row - from.row)));
    m_navigating = true;
    for (int index = 1; index <= steps; ++index) {
        const Cell cell{int(std::floor(from.lane + double(goal.lane - from.lane) * index / steps + 0.5)),
                        int(std::floor(from.row + double(goal.row - from.row) * index / steps + 0.5))};
        if (cell != m_actor.cell) {
            select(fileAt(cell), {{"cell", QJsonObject{{"lane", cell.lane}, {"row", cell.row}}}});
        }
    }
    m_navigating = false;
}
void NativeScene::moveArchive(double x, double y) {
    const bool pending = !m_drag.active;
    m_drag.move(x, y, m_clock * 1000);
    m_moved = m_moved || m_drag.moved;
    if (!m_drag.active) {
        return;
    }
    if (pending) {
        m_startTrack = {m_columnCamera.value, m_rail.value};
    }
    m_hover.reset();
    m_lastInteraction = m_clock;
    m_cursor = "grabbing";
    // 档案页拖动的**所属锁**（真人 m01597：禁止通过滑动 3D 层切换档案库所属，只能滚动列表）。
    // 原版把横向漂移也吃进来（m_startTrack.lane + m_drag.value.lane * 5.2），横滑/斜滑就会
    // 把当前列换掉 —— 那是"所属"级别的操作，只能由 HUD 的显式分类控件发起。这里只保留
    // 纵向轨道：lane 恒等于手势起点的 lane，navigatePlane 的 goal.lane 因此不动，物理格子
    // 只会沿当前列滚动，Flutter 侧 _selectedLane 也就不会被 3D 手势改掉。
    m_dragTrack = SceneMotion::DragPosition{m_startTrack.lane,
                                            m_startTrack.row - m_drag.value.row * 0.62};
    m_columnCamera = {m_dragTrack->lane, 0};
    m_rail = {m_dragTrack->row, 0};
    navigatePlane({m_columnCamera.value / 5.2 + 2, (-m_rail.value - 2.17) / 0.62 + 15.5});
}
void NativeScene::pointer(QString type, double x, double y, double delta) {
    m_changed = true;
    if (m_viewer->isOpen()) {
        m_viewer->pointer(type, x, y, delta);
        return;
    }
    if (type == "pointercancel" || type == "lostpointercapture") {
        resetPointer(false);
    } else if (type == "pointerleave") {
        m_pendingHover.reset();
        m_pointer = {};
        m_hover.reset();
    } else if (type == "pointerdown") {
        if (!canBrowse() && !m_canInspect) {
            return;
        }
        m_pendingHover.reset();
        m_captured = true;
        m_moved = m_momentum.has_value();
        m_down = {x, y};
        m_previous = {x, y};
        m_browsing = canBrowse();
        m_momentum.reset();
        if (m_browsing) {
            m_columnCamera.velocity = 0;
            m_rail.velocity = 0;
        }
        m_holding = m_browsing;
        m_dragging = !m_browsing && m_canInspect;
        m_startTrack = {m_columnCamera.value, m_rail.value};
        m_drag.start(x, y, dragProjection(), m_clock * 1000);
        m_hover.reset();
    } else if (type == "pointermove") {
        if (!m_captured) {
            m_pendingHover = QPointF(x, y);
            return;
        }
        m_moved = m_moved || std::hypot(x - m_down.x(), y - m_down.y()) > 7;
        if (m_browsing) {
            if (!canBrowse()) {
                resetPointer();
                return;
            }
            moveArchive(x, y);
        } else if (m_dragging && m_canInspect) {
            m_targetRotation = std::clamp(m_targetRotation + (x - m_previous.x()) * 0.004, -0.8, 0.8);
            m_previous = {x, y};
        }
    } else if (type == "pointerup" && m_captured) {
        if (m_browsing && canBrowse()) {
            moveArchive(x, y);
            if (m_drag.active && !m_reduced) {
                m_momentum.emplace(SceneMotion::DragPosition{m_columnCamera.value / 5.2 + 2,
                                                             (-m_rail.value - 2.17) / 0.62 + 15.5},
                                   m_drag.releaseVelocity(m_clock * 1000, false));
                m_momentumTime = m_clock;
            } else if (!m_drag.active && !m_moved) {
                const auto cell = pick(x, y);
                if (cell) {
                    select(fileAt(*cell), {{"cell", QJsonObject{{"lane", cell->lane}, {"row", cell->row}}}});
                }
            }
        }
        resetPointer(false);
    }
}
void NativeScene::rebase() {
    Cell shift;
    if (std::abs(m_actor.cell.lane) > 2048) {
        shift.lane = int(std::floor((m_actor.cell.lane - 2) / 5.0 + 0.5)) * 5;
    }
    if (std::abs(m_actor.cell.row) > 2048) {
        shift.row = int(std::floor((m_actor.cell.row - 12) / 8.0)) * 8;
    }
    if (shift == Cell{}) {
        return;
    }
    m_hover.reset();
    m_hoverLifts.clear();
    m_actor.cell.lane -= shift.lane;
    m_actor.cell.row -= shift.row;
    m_origin.lane += shift.lane;
    m_origin.row += shift.row;
    m_laneFocus.value -= shift.lane;
    m_shoulder.value -= shift.row;
    m_columnCamera.value -= shift.lane * 5.2;
    m_rail.value += shift.row * 0.62;
    for (auto &actor : m_returning) {
        actor.cell.lane -= shift.lane;
        actor.cell.row -= shift.row;
    }
    for (auto &pulse : m_pulses) {
        pulse.cell.lane -= shift.lane;
        pulse.cell.row -= shift.row;
    }
}
void NativeScene::openViewer() {
    m_changed = true;
    m_viewer->open(m_clock);
}
void NativeScene::coverFront(bool front) {
    m_changed = true;
    m_viewer->coverFront(front);
}
void NativeScene::viewerAction(QString action) {
    m_changed = true;
    m_viewer->action(action, m_clock);
}
void NativeScene::viewerKey(QString key) {
    m_changed = true;
    m_viewer->key(key, m_clock);
}
