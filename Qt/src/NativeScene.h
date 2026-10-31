#pragma once
#include "NativeCards.h"
#include "NativePicking.h"
#include "SceneAppearance.h"
#include "SceneDrag.h"
#include "SceneMath.h"
#include "SceneMotion.h"
#include "SceneTypes.h"
#include <QJsonObject>
#include <QPointF>
#include <array>
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
    QString mode() const {
        return m_mode;
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
