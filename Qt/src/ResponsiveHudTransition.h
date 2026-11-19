#pragma once
#include <QJsonArray>
#include <QJsonObject>
#include <algorithm>
#include <cmath>

/** 保存已显示页面的绘制快照；歌词用整页位移，歌曲取出跟随场景进度，普通 tab 不切换快照。 */
class ResponsiveHudTransition {
  public:
    enum class ScenePage { Other, Archive, Song };

    void drag(double distance) {
        m_drag = std::max(0., distance);
        m_returning = false;
    }
    bool release() {
        m_returning = true;
        return m_drag >= 90;
    }
    bool active(double time) const {
        return time < m_start + .46 || m_sceneRunning || (m_returning && m_drag > .5);
    }
    bool needsBackground(const QString &key) const {
        return isFullPage(key) || isFullPage(m_key);
    }
    void apply(QJsonArray &commands, QJsonArray &hits, QString key, double time, double height, bool reduced,
               ScenePage scenePage = ScenePage::Other, double sceneProgress = 0,
               const QJsonArray &background = {}) {
        if (reduced) {
            if (key != m_key || m_returning) {
                m_drag = 0;
            }
            m_key = key;
            m_scenePage = scenePage;
            m_last = commands;
            m_start = -1;
            m_sceneRunning = false;
            m_followScene = false;
            m_old = {};
            if (m_drag > 0) {
                QJsonArray moved;
                if (!background.isEmpty()) {
                    moved.append(background);
                }
                moved.append(QJsonArray{"save"});
                moved.append(QJsonArray{"translate", 0, m_drag});
                for (const auto &command : commands) {
                    moved.append(command);
                }
                moved.append(QJsonArray{"restore"});
                commands = moved;
                hits = {};
            }
            return;
        }
        if (m_key.isEmpty()) {
            m_key = key;
            m_scenePage = scenePage;
            m_last = commands;
            return;
        }
        if (key != m_key || scenePage != m_scenePage) {
            // 只有资料库与歌曲详情之间有可跟随的 3D 动画。歌手、专辑和歌单共用详情模式，
            // 但它们的竖屏场景会隐藏，不能以该模式下的镜头进度阻塞页面切换。
            m_enteringScene = m_scenePage == ScenePage::Archive && scenePage == ScenePage::Song;
            m_followScene = m_enteringScene || (m_scenePage == ScenePage::Song && scenePage == ScenePage::Archive);
            m_old = m_last;
            m_fromPage = isFullPage(m_key);
            m_toPage = isFullPage(key);
            m_drag = 0;
            m_returning = false;
            m_key = key;
            m_scenePage = scenePage;
            m_start = time;
            // 标签切换直接更新内容，不复用整页快照或移动整个 HUD。
            if (!m_followScene && !m_fromPage && !m_toPage) {
                m_start = -1;
                m_old = {};
                m_sceneRunning = false;
            }
        }
        m_last = commands;
        if (m_returning) {
            m_drag *= std::exp(-std::max(0., time - m_lastTime) * 16);
            if (m_drag < .5) {
                m_drag = 0;
            }
        }
        m_lastTime = time;
        double progress = std::clamp((time - m_start) / .46, 0., 1.);
        if (m_followScene) {
            progress = std::clamp(m_enteringScene ? sceneProgress : 1 - sceneProgress, 0., 1.);
            if (progress > .995) {
                progress = 1;
                m_followScene = false;
            }
        }
        m_sceneRunning = m_followScene && progress < 1;
        if (progress >= 1 && m_drag == 0) {
            // 稳态保留原数组的隐式共享，不逐条复制或添加无效变换。
            m_old = {};
            return;
        }
        const double eased = 1 - std::pow(1 - progress, 3);
        QJsonArray result;
        // 整页切换和拖动时先铺固定纸色底，避免页面位移后露出下层 3D 场景。
        if (!background.isEmpty()) {
            result.append(background);
        }
        const auto layer = [&](const QJsonArray &content, double opacity, double offset) {
            result.append(QJsonArray{"save"});
            result.append(QJsonArray{"alpha", opacity});
            result.append(QJsonArray{"translate", 0, offset});
            for (const auto &command : content) {
                result.append(command);
            }
            result.append(QJsonArray{"restore"});
        };
        if (progress < 1 && (m_fromPage || m_toPage)) {
            // 评论整页只动画目标页，静态纸色底仍固定在下方。
            layer(commands, eased, m_toPage ? height * (1 - eased) : 18 * (1 - eased));
        } else if (progress < 1) {
            layer(m_old, 1 - eased, -18 * eased);
            layer(commands, eased, 24 * (1 - eased));
        } else {
            layer(commands, 1, m_drag);
            m_old = {};
        }
        commands = result;
        // 过渡中的内容尚未抵达目标位置，禁止点中其最终位置的按钮。
        if (progress < 1 || m_drag > 0) {
            hits = {};
        }
    }

  private:
    static bool isFullPage(const QString &key) {
        return key == "comments";
    }

    QString m_key;
    ScenePage m_scenePage = ScenePage::Other;
    QJsonArray m_last;
    QJsonArray m_old;
    double m_start = -1;
    double m_drag = 0;
    double m_lastTime = 0;
    bool m_fromPage = false;
    bool m_toPage = false;
    bool m_returning = false;
    bool m_followScene = false;
    bool m_enteringScene = false;
    bool m_sceneRunning = false;
};
