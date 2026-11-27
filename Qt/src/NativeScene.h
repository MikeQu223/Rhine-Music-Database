#pragma once
#include "NativeCards.h"
#include "NativePicking.h"
#include "SceneAppearance.h"
#include "SceneDrag.h"
#include "SceneMath.h"
#include "SceneMotion.h"
#include "SceneTypes.h"
#include <QHash>
#include <QJsonObject>
#include <QPointF>
#include <array>
#include <cmath>
#include <functional>
#include <memory>
#include <optional>

class NativeViewer;

class NativeScene {
  public:
    explicit NativeScene(QString root);
    ~NativeScene();
    bool ready() const;
    QJsonObject sample(double time, bool advance = true);
    void setMode(QString mode);
    void select(int index, QJsonObject navigation = {});
    void navigate(QString axis, int direction);
    int selection() const;
    // 详情页唱片被拖到的相对角度（-0.8..0.8）；翻哪张由 Flutter 的列表真值决定。
    // 引擎自己的点选判据：无按压拖动且位移未过 7px。横滑锁在同一列，
    // 轨道几乎不动，宿主必须问引擎而不能只看轨道位移。
    bool tapLike() const { return !m_moved && !m_drag.active; }

    double rotationTarget() const { return m_targetRotation; }
    void resetRotation() { m_targetRotation = 0; }
    // 归档轨道当前的**条目位置**（0 = 本列第一条；小数 = 两条之间）。
    // Flutter 的 state.listPosition 与它是同一件事的两种写法：Flutter 侧是列表窗口真值，
    // 这里只是把 Qt 的连续轨道折算回条目，供 pointer/wheel 结束后把增量回写给 Flutter。
    double archiveTrackItem() const;
    // 反向投影：把 Flutter 的窗口位置/所属列落到 Qt 的连续轨道上（只改位置，不动
    // 指针/惯性以外的状态）。echo 判定在调用方（EmbeddedSceneHost）做。
    void projectArchiveScroll(double item, int lane);
    QString mode() const {
        return m_mode;
    }
    bool viewerOpen() const;
    bool viewerTargetVisible() const;
    bool detailSettled() const;
    bool themeSettled() const {
        return m_theme.settled(m_clock);
    }
    bool isSelectedCell(SceneMotion::Cell cell) const {
        return cell == m_actor.cell;
    }
    void resize(double width, double height);
    void theme(bool dark);
    void reduced(bool value);
    void energyIdle(bool value);
    void musicIdentity(QString key);
    void musicClear();
    // 把每一格真实的业务 key 绑到它自己的位置上。键是 cellInstanceId(lane,row)，
    // 值是 siren:<kind>:<id>。只影响"这一格画不画封面/标签"，不动矩阵、实例缓冲与选中态。
    // 传空表即恢复纯占位档案壳。
    void projectEmbeddedCellKeys(const QHash<quint32, QString> &keys);
    int embeddedCellCount() const {
        return int(m_embeddedCellKeys.size());
    }
    // 归档轨道此刻是否在"快速移动"（拖动中、有惯性、或有可观测速度）。可见格的封面/标签
    // 准入会与调用方传来的 scrolling 取并集：滚动期间一个都不新建，热资源照常显示。
    bool archiveScrolling() const {
        return m_dragging || m_drag.active || m_momentum.has_value() ||
               std::abs(m_rail.velocity) > 0.25 || std::abs(m_columnCamera.velocity) > 0.25;
    }
    void pointer(QString type, double x, double y, double delta = 0);
    std::optional<SceneMotion::Cell> pick(double x, double y);
    void openViewer();
    void coverFront(bool front = true);
    void viewerAction(QString action);
    void viewerKey(QString key);
    void trimMemory();
    void freeze(std::optional<double> time);
    bool review(QString mode);
    struct FrameTimings {
        double simulateMs = 0;
        double metadataMs = 0;
        double buffersMs = 0;
        double engineMs = 0;
    };
    FrameTimings timings;
    void profileFrames(bool enabled) {
        m_profileFrames = enabled;
    }
    bool isProfiling() const {
        return m_profileFrames;
    }
    bool changed() const {
        return m_changed;
    }
    void diagnostics(bool enabled) {
        m_diagnostics = enabled;
    }
    void captureOnly(bool enabled) {
        m_captureOnly = enabled;
    }
    void drawCulling(bool enabled) {
        m_drawCulling = enabled;
        m_changed = true;
    }
    QJsonObject frame;
    SceneDrawBuffers drawBuffers;
    QString failure;

  private:
    using Vector = SceneMath::Vector;
    using Matrix = SceneMath::Matrix;
    using Cell = SceneMotion::Cell;
    struct Actor {
        int id = 2;
        Cell cell{2, 12};
        Vector position;
        Vector rotation;
        SceneMotion::Spring lift;
        std::optional<double> returnY;
        double quality = 0;
        double clarity = 0;
        double theme = 0;
        QString musicKey;
        /// E04：归位已存在多久（秒）。用来丢弃"最老的一份"，也用来观察积压年龄。
        double age = 0;
    };
    struct Cinema {
        double time;
        double reveal;
        double zoom;
    };
    using Pulse = SceneMotion::FieldPulse;
    QString m_root;
    SceneAppearance m_appearance;
    SceneMotion::BootTimeline m_boot;
    NativeCards m_cards;
    NativePicking m_picking;
    std::unique_ptr<NativeViewer> m_viewer;
    std::array<QVector<int>, 5> m_columns;
    std::array<int, 5> m_memories{};
    Actor m_actor;
    QVector<Actor> m_returning;
    QVector<Cell> m_cells;
    QVector<Cell> m_drawnCells;
    QVector<Matrix> m_drawnMatrices;
    SceneMotion::ThemeWave m_theme;
    SceneMotion::Decryption m_decryption;
    SceneMotion::Spring m_rail;
    SceneMotion::Spring m_shoulder{12, 0};
    SceneMotion::Spring m_laneFocus{2, 0};
    SceneMotion::Spring m_columnCamera;
    Cell m_origin;
    Vector m_eye{-62.26, 35.98, 43.28};
    Vector m_aim{-0.5, 1.1, 0.4};
    Matrix m_view;
    Matrix m_projection;
    Matrix m_aoProjection;
    double m_fov = 6.15;
    double m_width = 1920;
    double m_height = 1080;
    double m_fogNear = 22;
    double m_fogFar = 47;
    double m_focus = 1;
    double m_aperture = 0;
    double m_clock = 0;
    double m_last = 0;
    double m_bootStart = -1.76;
    double m_reveal = 0;
    double m_targetReveal = 0;
    double m_detail = 0;
    double m_targetDetail = 0;
    double m_rotation = 0;
    double m_targetRotation = 0;
    double m_scanTime = 29.1;
    double m_scanBlend = 0;
    double m_lastInteraction = 0;
    double m_idleGain = 0;
    double m_pulseGain = 1;
    double m_clearance = 0;
    bool m_canInspect = false;
    bool m_looping = false;
    bool m_profileFrames = false;
    bool m_diagnostics = false;
    bool m_captureOnly = false;
    bool m_drawCulling = true;
    bool m_changed = true;
    bool m_reduced = false;
    bool m_energyIdle = false;
    int m_selected = 0;
    int m_nextActor = 3;
    QString m_mode = "boot";
    QString m_cursor = "default";
    QVector<Pulse> m_pulses;
    SceneMotion::ArchiveField m_field;
    std::optional<Cinema> m_cinema;
    mutable QHash<qint64, double> m_fieldCache;
    std::optional<double> m_freeze;
    std::optional<double> m_sceneFreeze;
    std::optional<Cell> m_hover;
    QHash<QString, double> m_hoverLifts;
    // cellInstanceId → 业务 key。只有解析出真实身份的格才在这里；其余格保持纯占位壳。
    QHash<quint32, QString> m_embeddedCellKeys;
    std::optional<QPointF> m_pendingHover;
    QPointF m_pointer;
    QPointF m_down;
    QPointF m_previous;
    bool m_captured = false;
    bool m_moved = false;
    bool m_browsing = false;
    bool m_dragging = false;
    bool m_holding = false;
    bool m_navigating = false;
    SceneMotion::ArchiveDrag m_drag;
    std::optional<SceneMotion::DragPosition> m_dragTrack;
    SceneMotion::DragPosition m_startTrack;
    std::optional<SceneMotion::ArchivePlaneMomentum> m_momentum;
    // 外部窗口（Flutter 列表真值）刚投影过的时间戳；有效期内不要再把轨道
    // damp 回选中卡，否则"列表推到第 300 行、3D 停在选中行"。
    double m_externalUntil = -1;
    double m_momentumTime = 0;
    void update(double time, std::optional<Cinema> cinema);
    void updateCamera(double seconds, std::optional<Cinema> cinema);
    void emitFrame(double time);
    void rebase();
    void resetPointer(bool stopMomentum = true);
    void moveArchive(double x, double y);
    void navigatePlane(SceneMotion::DragPosition coordinate);
    SceneMotion::DragProjection dragProjection() const;
    bool canBrowse() const;
    int fileAt(Cell cell) const;
    Cell fileLocation(int index) const;
    Vector cellPosition(Cell cell) const;
    void pulse(Cell cell);
    double field(double row, double lane) const;
    double hoverLift(Cell cell) const;
    QVector<Cell> visibleCells(double trackX, double trackZ) const;
    bool intersectsCard(const SceneMath::Frustum &frustum, Vector position) const;
    static QJsonObject read(QString path);
};
