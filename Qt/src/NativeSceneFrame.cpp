#include "NativeScene.h"
#include "NativeViewer.h"
#include <QJsonArray>
#include <QElapsedTimer>
#include <algorithm>
#include <cmath>

QJsonObject NativeScene::sample(double time, bool advance) {
    if (!ready()) {
        return {};
    }
    QElapsedTimer clock;
    if (m_profileFrames) {
        clock.start();
    }
    advance = advance && !m_captureOnly;
    m_clock = time;
    const auto elapsed = m_freeze.value_or(time - m_bootStart);
    if (m_mode == "boot" && elapsed >= 35) {
        setMode("detail");
    }
    std::optional<Cinema> cinema;
    if (m_mode == "boot") {
        cinema = Cinema{elapsed, SceneMotion::ease((elapsed - 22) / 0.4),
                        0.55 * SceneMotion::ease((elapsed - 27.3) / 1.65) +
                            0.45 * SceneMotion::ease((elapsed - 29) / 5)};
    }
    if (advance && !m_sceneFreeze && (!cinema || elapsed >= 21.9)) {
        update(time, cinema);
    }
    if (advance) {
        m_viewer->update(time, m_theme.background(time));
    }
    const auto simulation = m_profileFrames ? clock.nsecsElapsed() : 0;
    emitFrame(elapsed);
    if (m_viewer->isOpen()) {
        frame = m_viewer->frame(frame, m_appearance, drawBuffers);
    }
    if (m_profileFrames) {
        timings.simulateMs = simulation / 1000000.0;
        timings.metadataMs = (clock.nsecsElapsed() - simulation) / 1000000.0;
    }
    m_changed = false;
    return frame;
}

/** 直接交付原生缓冲区；场景 JSON 只保存小型材质与相机参数，没有跨引擎数值转换。 */
void NativeScene::emitFrame(double time) {
    QSet<int> retained{1};
    const auto theme = m_theme.background(m_clock);
    QJsonArray draws;
    auto floor = m_appearance.floor(theme);
    // 地板矩阵与其他模型一样使用原生字节，诊断 JSON 不参与正式提交。
    drawBuffers[1] = {Matrix::compose({0, -4.63, 0}, {-3.14159265358979323846 / 2, 0, 0}).bytes(), {}};
    floor["matrices"] = QJsonArray{};
    draws.append(floor);
    const auto instanceBytes = drawBuffers.value(10);
    for (const auto &entry : m_appearance.instances) {
        auto draw = entry.toObject();
        const auto id = draw["id"].toInt();
        retained.insert(id);
        draw["count"] = m_drawnCells.size();
        draw["matrices"] = QJsonArray{};
        draw["themes"] = QJsonArray{};
        draw["matrixBuffer"] = -1;
        draw["themeBuffer"] = -1;
        draw["theme"] = theme;
        drawBuffers[id] = instanceBytes;
        draws.append(draw);
    }
    QJsonArray returningKeys;
    double returningAgeMax = 0;
    for (const auto &actor : m_returning) {
        if (!actor.musicKey.isEmpty()) {
            returningKeys.append(actor.musicKey);
        }
        returningAgeMax = std::max(returningAgeMax, actor.age);
    }
    frame = {{"pendingAnimations", m_viewer->pending()},
             {"pointerCursor", m_cursor},
             {"aoProjection", m_aoProjection.json()},
             {"reference", m_sceneFreeze.has_value()},
             {"near", 5},
             {"far", 300},
             {"viewer", false},
             {"viewerReady", false},
             {"viewerState", QJsonObject{}},
             {"mode", m_mode},
             {"selected", m_selected},
             {"culledCards", 0},
             {"shadowCards", 0},
             {"returningCards", m_returning.size()},
             {"returningPartNodes", 0},
             {"globalSubdued", 0},
             {"returningMusicKeys", returningKeys},
             {"returningAgeMax", returningAgeMax},
             {"time", time},
             {"draws", draws},
             {"view", m_view.json()},
             {"projection", m_projection.json()},
             {"eye", m_eye.json()},
             {"background", SceneAppearance::blend(SceneAppearance::color("#eae5e1"),
                                                   SceneAppearance::color("#11181b"), theme)},
             {"fogColor", SceneAppearance::blend(SceneAppearance::color("#eae5e1"),
                                                 SceneAppearance::color("#263136"), theme)},
             {"fogNear", m_fogNear},
             {"fogFar", m_fogFar},
             {"detail", SceneMotion::smooth((m_detail - 0.25) / 0.55)},
             {"boot", m_boot.sample(time)},
             {"focus", m_focus},
             {"aperture", m_aperture}};
    QJsonArray actors;
    QByteArray actorBytes;
    const SceneMath::Frustum cameraFrustum(m_projection * m_view);
    const auto lightView = Matrix::camera({-6, 14, -5}, {}).inverse();
    int culled = 0;
    int shadowOnly = 0;
    const auto add = [&](const Actor &actor, bool selected) {
        const auto matrix = Matrix::compose(actor.position, actor.rotation);
        bool shadow = false;
        if (!selected && m_drawCulling) {
            const auto center = matrix.point(m_appearance.boundsCenter);
            const auto radius = m_appearance.boundsRadius + 0.1;
            if (!cameraFrustum.intersectsSphere(center, radius)) {
                const auto light = lightView.point(center);
                if (std::abs(light.x) > 16.1 + radius || std::abs(light.y) > 15.1 + radius) {
                    ++culled;
                    return;
                }
                shadow = true;
                ++shadowOnly;
            }
        }
        std::array<double, 20> state;
        std::copy(matrix.values.begin(), matrix.values.end(), state.begin());
        state[16] = actor.quality;
        state[17] = actor.clarity;
        state[18] = actor.theme;
        state[19] = 0;
        actorBytes.append(reinterpret_cast<const char *>(state.data()), sizeof(state));
        actors.append(QJsonObject{{"id", actor.id},
                                  {"musicKey", actor.musicKey.isEmpty() ? QJsonValue(QJsonValue::Null)
                                                                        : QJsonValue(actor.musicKey)},
                                  {"selected", selected},
                                  {"shadowOnly", shadow}});
        for (const auto &part : m_appearance.actorTemplate) {
            retained.insert(-(actor.id * 256 + part.toObject()["partIndex"].toInt() + 1));
        }
    };
    add(m_actor, true);
    for (const auto &actor : m_returning) {
        add(actor, false);
    }
    frame["culledCards"] = culled;
    frame["shadowCards"] = shadowOnly;
    frame["actorTemplate"] = m_appearance.actorTemplate;
    frame["appearanceRevision"] = double(m_appearance.revision);
    frame["actors"] = actors;
    failure = m_cards.expand(frame, actorBytes, drawBuffers);
    for (auto entry = drawBuffers.begin(); entry != drawBuffers.end();) {
        if (!retained.contains(entry.key())) {
            entry = drawBuffers.erase(entry);
        } else {
            ++entry;
        }
    }
    auto decryption = m_decryption.frame;
    decryption["clarity"] = m_decryption.clarity;
    decryption["modelClarity"] = m_actor.clarity;
    const auto round = [](Vector value) {
        const auto rounded = [](double value) { return std::floor(value * 10000 + 0.5) / 10000; };
        return QJsonArray{rounded(value.x), rounded(value.y), rounded(value.z)};
    };
    const auto cell = [](Cell value) { return QJsonObject{{"lane", value.lane}, {"row", value.row}}; };
    QJsonArray pulses;
    for (const auto &pulse : m_pulses) {
        auto value = cell(pulse.cell);
        value["time"] = pulse.time;
        pulses.append(value);
    }
    const auto projection = m_projection * m_view * Matrix::compose(m_actor.position, m_actor.rotation);
    const auto project = [&](Vector point) {
        const auto value = projection.point(point);
        return QJsonArray{std::floor((value.x + 1) * m_width / 2 + 0.5),
                          std::floor((1 - value.y) * m_height / 2 + 0.5)};
    };
    frame["stats"] =
        QJsonObject{{"loaded", true},
                    {"fieldOfView", m_fov},
                    {"decryption", decryption},
                    {"topLeft", project({-2.5, 3.7, 0})},
                    {"topRight", project({2.5, 3.7, 0})},
                    {"labelTopLeft", project({-1.855, 3.27, 0.255})},
                    {"labelBottomLeft", project({-1.855, 2.81, 0.255})},
                    {"modelPosition", round(m_actor.position)},
                    {"cameraPosition", round(m_eye)},
                    {"selectedCell", cell(m_actor.cell)},
                    {"selectedSlot", fileLocation(m_selected).lane * 32 + fileLocation(m_selected).row},
                    {"archiveCount", m_drawnCells.size()},
                    {"archiveCandidates", m_cells.size()},
                    {"returningFiles", m_returning.size()},
                    {"pulses", pulses},
                    {"clearance", m_clearance},
                    {"coordinateOrigin", cell(m_origin)},
                    {"holdingArchive", m_holding}};
}
