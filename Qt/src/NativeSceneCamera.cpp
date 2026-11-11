#include "NativeScene.h"
#include <algorithm>
#include <cmath>
#include <numbers>

namespace {
double lerp(double from, double to, double amount) {
    return (1 - amount) * from + amount * to;
}
}

/** 镜头保持原长焦、抽取锚点与响应式构图；所有计算使用双精度，再写入 GPU 矩阵。 */
void NativeScene::updateCamera(double seconds, std::optional<Cinema> cinema) {
    const auto aspect = m_width / m_height;
    const bool portrait = aspect < 1.05;
    const bool mobile = aspect < 1;
    // 竖屏播放页沿唱片正面法线观察，抽取过程仍沿用原有的详情过渡权重。
    const Vector detailDirection = mobile
                                       ? Vector{std::sin(m_actor.rotation.y), 0, std::cos(m_actor.rotation.y)}
                                       : Vector{-0.277, 0.238, 0.931};
    const auto shot = cinema ? cinema->time : 29.1;
    const auto orbit = SceneMotion::smooth((shot - 22.6) / 1.6);
    const auto settle = SceneMotion::smooth((shot - 24.25) / 2.25);
    constexpr auto rad = std::numbers::pi / 180;
    const auto yaw = (89 - 22 * orbit - 8 * settle) * rad;
    const auto elevation =
        (3 + 40 * SceneMotion::smooth((shot - 21.96) / 0.22) - 8 * orbit - 16 * settle) * rad;
    const auto span = lerp(lerp(10.8, 10.3, orbit), 7.33, settle);
    const auto distance = lerp(lerp(28 + 7 * orbit, 140, settle), 72, m_detail);
    Vector cameraAim{-1.091, lerp(-2.55 + 0.4 * orbit, -0.045, settle), lerp(2.48, 0.481, settle)};
    Vector direction{-std::sin(yaw) * std::cos(elevation), std::sin(elevation),
                     std::cos(yaw) * std::cos(elevation)};
    if (cinema) {
        const auto earlyTurn = SceneMotion::smooth((shot - 27.3) / 1.3);
        const auto finalTurn = SceneMotion::smooth((shot - 28.6) / 5.4);
        const auto shotYaw = yaw - (9 * earlyTurn + 32 * finalTurn) * rad;
        const auto shotElevation = elevation - (1.5 * earlyTurn + 3.7 * finalTurn) * rad;
        direction = {-std::sin(shotYaw) * std::cos(shotElevation), std::sin(shotElevation),
                     std::cos(shotYaw) * std::cos(shotElevation)};
    } else {
        direction = direction.lerp(detailDirection, m_detail).normalized();
    }
    // 抽取时逐步采用详情页视线，让模型进入右侧遮罩之前先向左收束。
    const auto detailHandoff = cinema ? SceneMotion::smooth((shot - 27.3) / 1.55) : 0.0;
    if (cinema) {
        direction = direction.lerp(detailDirection.normalized(), detailHandoff).normalized();
    }
    const auto right = Vector{0, 1, 0}.cross(direction).normalized();
    const auto up = direction.cross(right).normalized();
    if (cinema) {
        const auto pan = SceneMotion::smooth((shot - 25.4) / 0.95);
        cameraAim = cameraAim + right * (-2.05 * (1 - pan) * SceneMotion::smooth((shot - 24.2) / 0.8));
    }
    if (cinema && shot >= 25.05) {
        const auto pan = SceneMotion::smooth((shot - 25.4) / 1.05);
        const auto pixelScale = 1080 / span;
        auto anchorAim = m_actor.position + Vector{-2.5, 3.7, 0};
        anchorAim = anchorAim + right * (-(lerp(840, 518, pan) - 960) / pixelScale);
        anchorAim = anchorAim + up * (-(540 - lerp(340, 288, pan)) / pixelScale);
        cameraAim = cameraAim.lerp(anchorAim, SceneMotion::smooth((shot - 25.05) / 0.35));
    }
    const bool compact = !portrait && m_width < 1100;
    const auto baseSpan = lerp(span, 5.9, m_detail);
    const auto portraitDetail =
        std::max(6.3 / aspect, 3.7 * m_height / std::max(100.0, 0.54 * m_height - 156));
    double viewSpan = std::max(baseSpan, baseSpan * (16.0 / 9) / aspect);
    double anchorX = 550.0 / 1920;
    double anchorY = 560.0 / 1080;
    if (portrait) {
        viewSpan = std::max(baseSpan, lerp(8.4 / aspect, portraitDetail, m_detail));
        anchorX = 0.5;
        anchorY = 0.27 + 34 / m_height;
    } else if (compact) {
        anchorX = 0.27;
        anchorY = 0.49;
    }
    if (!cinema || detailHandoff > 0) {
        const auto pixelScale = m_height / viewSpan;
        if (!cinema && portrait) {
            const auto baseline = SceneMotion::cinematicField(12, 2, 26.56);
            // 竖屏主界面的 tab 列表占住下部，唱片锚点相应上移，避免被列表遮住。
            cameraAim = Vector{0, -4.6 + baseline + 0.4 + 1.85, -2.17} +
                        up * (((mobile ? 0.26 : 0.36) - 0.5) * m_height / pixelScale);
        }
        auto detailAim = m_actor.position + Vector{0, 1.85, 0};
        detailAim = detailAim + right * ((0.5 - anchorX) * m_width / pixelScale);
        detailAim = detailAim + up * ((anchorY - 0.5) * m_height / pixelScale);
        cameraAim = cameraAim.lerp(detailAim, cinema ? detailHandoff : m_detail);
    }
    auto position = cameraAim + direction * distance;
    if (!cinema && !m_reduced) {
        // 详情停稳后消除鼠标视差，确保竖屏正视角不会随指针再次倾斜。
        const double parallax = mobile ? 1 - m_detail : 1;
        position.x += m_pointer.x() * 0.12 * parallax;
        position.y -= m_pointer.y() * 0.12 * parallax;
    }
    const auto blend = cinema || m_reduced ? 1 : 1 - std::exp(-seconds * 5);
    m_eye = m_eye.lerp(position, blend);
    m_aim = m_aim.lerp(cameraAim, blend);
    const auto desiredSpan = cinema ? lerp(baseSpan, viewSpan, detailHandoff) : viewSpan;
    m_fov = lerp(m_fov, 2 * std::atan(desiredSpan / (2 * distance)) / rad, blend);
    const auto renderedDistance = (m_eye - m_aim).length();
    const auto theme = m_theme.background(m_clock);
    m_fogNear = renderedDistance + lerp(5 - 4 * theme, -1, m_detail);
    m_fogFar = renderedDistance + lerp(25 - 9 * theme, 12, m_detail);
    m_projection = Matrix::perspective(m_fov, aspect, 5, 300);
    // 浏览构图
    const auto detailProgress = SceneMotion::smooth((m_detail - 0.25) / 0.55);
    const auto archiveOffset = cinema || m_mode == "boot" ? 0.0 : 1 - detailProgress;
    m_projection.values[8] += 0.16 * archiveOffset;
    m_projection.values[9] += 0.20 * archiveOffset;
    m_aoProjection.values[8] = m_projection.values[8];
    m_aoProjection.values[9] = m_projection.values[9];
    m_view = Matrix::camera(m_eye, m_aim).inverse();
}

bool NativeScene::intersectsCard(const SceneMath::Frustum &frustum, Vector position) const {
    return frustum.intersects(position + Vector{-2.8, -0.3, -1.2}, position + Vector{2.8, 4.1, 1.2});
}

QVector<NativeScene::Cell> NativeScene::visibleCells(double trackX, double trackZ) const {
    auto projection =
        Matrix::perspective(m_fov, m_width / m_height, 5, std::min(300.0, std::max(6.0, m_fogFar + 8)));
    projection.values[0] /= 1.18;
    projection.values[5] /= 1.18;
    // 裁剪范围复用实际投影偏移，确保默认构图下的可见区域与拾取一致。
    projection.values[8] = m_projection.values[8];
    projection.values[9] = m_projection.values[9];
    const auto matrix = projection * m_view;
    const SceneMath::Frustum frustum(matrix);
    const auto inverse = matrix.inverse();
    std::array<Vector, 8> vertices;
    for (int index = 0; index < 8; ++index) {
        vertices[index] = inverse.point({index & 1 ? 1.0 : -1, index & 2 ? 1.0 : -1, index & 4 ? 1.0 : -1});
    }
    Vector minimum{1e100, 1e100, 1e100};
    Vector maximum{-1e100, -1e100, -1e100};
    const auto include = [&](Vector point) {
        minimum = {std::min(minimum.x, point.x), std::min(minimum.y, point.y), std::min(minimum.z, point.z)};
        maximum = {std::max(maximum.x, point.x), std::max(maximum.y, point.y), std::max(maximum.z, point.z)};
    };
    for (const auto vertex : vertices) {
        if (vertex.y >= -6.5 && vertex.y <= 6.5) {
            include(vertex);
        }
    }
    const std::array<std::array<int, 2>, 12> edges{
        {{0, 1}, {0, 2}, {0, 4}, {1, 3}, {1, 5}, {2, 3}, {2, 6}, {3, 7}, {4, 5}, {4, 6}, {5, 7}, {6, 7}}};
    for (const auto edge : edges) {
        const auto start = vertices[edge[0]];
        const auto end = vertices[edge[1]];
        const auto dy = end.y - start.y;
        if (std::abs(dy) < 1e-9) {
            continue;
        }
        for (const auto height : {-6.5, 6.5}) {
            const auto amount = (height - start.y) / dy;
            if (amount >= 0 && amount <= 1) {
                include(start.lerp(end, amount));
            }
        }
    }
    QVector<Cell> result;
    if (maximum.x < minimum.x) {
        return result;
    }
    const auto minLane = int(std::floor((minimum.x - 2.8 + trackX) / 5.2 + 2)) - 1;
    const auto maxLane = int(std::ceil((maximum.x + 2.8 + trackX) / 5.2 + 2)) + 1;
    const auto minRow = int(std::floor((minimum.z - 0.6 - trackZ) / 0.62 + 15.5)) - 2;
    const auto maxRow = int(std::ceil((maximum.z + 0.6 - trackZ) / 0.62 + 15.5)) + 2;
    for (int lane = minLane; lane <= maxLane; ++lane) {
        for (int row = minRow; row <= maxRow; ++row) {
            const auto x = (lane - 2) * 5.2 - trackX;
            const auto z = (row - 15.5) * 0.62 + trackZ;
            if (frustum.intersects({x - 2.8, -6.5, z - 1.2}, {x + 2.8, 6.5, z + 1.2})) {
                result.append({lane, row});
            }
        }
    }
    return result;
}
