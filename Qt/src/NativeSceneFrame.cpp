#include "NativeScene.h"
#include "NativeViewer.h"
#include "render/EmbeddedCellResources.h"
#include <QJsonArray>
#include <QElapsedTimer>
#include <QSet>
#include <QStringList>
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
    // 详情 HUD 的整块内容被 alpha(frame["detail"]) 包着，而 frame["detail"] 由
    // m_detail 推出，只在 update() 里按帧收敛。这里若无条件清掉 changed，引擎会在
    // 淡入完成前判定「场景稳定」并休眠，m_detail 冻结在 0 —— 详情整页透明，
    // 但 hits 已经注册，于是「按钮能点、画面空白、点一下（wake）才显示」。
    // 开唱片旋转能绕过，正是因为 m_discRotating 让 workPending 恒真、引擎不休眠。
    // 把「详情淡入未收敛」也算作场景有变化，让所有依赖 scene.changed() 的判据
    // （reuse / workPending / m_sceneSleeping）自动保持工作，不另设定时器。
    const bool detailFading = m_mode == "detail" && frame.value("detail").toDouble() < 0.99;
    m_changed = detailFading;
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
    // 这一格有真实业务身份时，给它加两条「只属于这一格」的覆盖绘制——封面板与标签面。
    // 底下的档案壳仍然是上面那条共享实例缓冲：几何、材质、机位、惯性、数量一律不动，
    // 这里只往同一格的世界矩阵上加薄薄一层贴面，所以不会变成 40 个 detail actor。
    QSet<quint32> embeddedCells;
    QStringList embeddedKeys;
    for (int index = 0; index < m_drawnCells.size() && index < m_drawnMatrices.size(); ++index) {
        const auto cell = m_drawnCells.at(index);
        const auto cellId = RhineRender::embeddedCellId(cell.lane, cell.row);
        if (embeddedCells.contains(cellId)) {
            continue;
        }
        const auto key = m_embeddedCellKeys.value(cellId);
        if (key.isEmpty()) {
            // 没有身份就保持纯占位壳：宁可空着，也不拿别的格的内容顶上。
            continue;
        }
        embeddedCells.insert(cellId);
        embeddedKeys.append(key);
        const auto root = m_drawnMatrices.at(index);
        const auto cellTheme = float(m_theme.sample(cell, time));
        QByteArray themeBytes;
        themeBytes.append(reinterpret_cast<const char *>(&cellTheme), sizeof(cellTheme));
        // 封面板：正面方形画心（1:1，不被拉扁），落在档案纸之前（z=0.25）。
        auto plate = QJsonObject{{"mesh", -8},
                                 {"asset", "cassette"},
                                 {"label", false},
                                 {"name", "Embedded_Cell_Print"},
                                 // instanced=true 只为让 isFocusedSceneCard()/SceneTransformHistory
                                 // 不把可见格误认成"详情焦点主体"（那会切到 hero 的背板与主光分支）。
                                 // 实例数据仍来自本 draw 自己的 drawBuffers 条目，不走共享实例缓冲。
                                 {"instanced", true},
                                 {"floor", false},
                                 {"transparent", false},
                                 {"depthWrite", true},
                                 {"order", 0},
                                 {"side", 2},
                                 {"castShadow", false},
                                 {"musicKey", key},
                                 {"musicSelected", false},
                                 {"shadowOnly", false},
                                 {"count", 1},
                                 {"quality", 1},
                                 // clarity=1 让封面直接采样（片元着色器里 blur=1-clarity），不做唱片模糊。
                                 {"clarity", 1},
                                 {"theme", double(cellTheme)},
                                 {"matrices", QJsonArray{}},
                                 {"themes", QJsonArray{}},
                                 {"matrixBuffer", -1},
                                 {"themeBuffer", -1}};
        plate["id"] = RhineRender::embeddedCellDrawId(cellId, 0);
        const auto plateId = plate["id"].toInt();
        retained.insert(plateId);
        drawBuffers[plateId] = {root.bytes(), themeBytes, {cellId}};
        draws.append(plate);
        // 标签面：与详情卡同一张平面、同一条本地偏移（印刷标签的位置），只是身份换成这一格。
        auto label = plate;
        label["id"] = RhineRender::embeddedCellDrawId(cellId, 1);
        label["mesh"] = -1;
        label["label"] = true;
        label["name"] = "Embedded_Cell_Label";
        label["transparent"] = true;
        label["depthWrite"] = false;
        label["order"] = 1;
        const auto labelId = label["id"].toInt();
        retained.insert(labelId);
        drawBuffers[labelId] = {(root * Matrix::compose({-1.36, 3.04, 0.255}, {})).bytes(), themeBytes, {cellId}};
        draws.append(label);
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
             // 名字与 Engine 发布的摘要帧字段（embeddedCells）区分开：一个是"这一帧画了几格"，
             // 一个是"这一帧几格真实/几格占位"，同名字段会被后者覆盖，看起来像被清零。
             {"embeddedCellDraws", embeddedKeys.size()},
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
