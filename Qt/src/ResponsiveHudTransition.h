#pragma once
#include <QJsonArray>
#include <QJsonObject>
#include <algorithm>
#include <cmath>

/** 保存已显示页面的绘制快照；歌词用整页位移，歌曲取出跟随场景进度，普通 tab 不切换快照。 */
class ResponsiveHudTransition {
  public:
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
    void apply(QJsonArray &commands, QJsonArray &hits, QString key, double time, double height, bool reduced,
               double sceneProgress = -1) {
        const auto fullPage = [](const QString &value) {
            return value == "lyrics" || value == "comments";
        };
        if (reduced) {
            if (key != m_key || m_returning) {
                m_drag = 0;
            }
            m_key = key;
            m_last = commands;
            m_start = -1;
            m_sceneRunning = false;
            m_old = {};
            if (m_drag > 0) {
                QJsonArray moved{QJsonArray{"save"}, QJsonArray{"translate", 0, m_drag}};
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
            m_last = commands;
            return;
        }
        if (key != m_key) {
            m_enteringScene = m_key.startsWith(":archive") && key.startsWith(":detail:");
            m_followScene = sceneProgress >= 0 &&
                            (m_enteringScene || (m_key.startsWith(":detail:") && key.startsWith(":archive")));
            m_old = m_last;
            m_fromPage = fullPage(m_key);
            m_toPage = fullPage(key);
            m_fromDrag = m_drag;
            m_drag = 0;
            m_returning = false;
            m_key = key;
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
        if (m_followScene && sceneProgress >= 0) {
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
        const auto layer = [&](const QJsonArray &content, double opacity, double offset) {
            result.append(QJsonArray{"save"});
            result.append(QJsonArray{"alpha", opacity});
            result.append(QJsonArray{"translate", 0, offset});
            for (const auto &command : content) {
                result.append(command);
            }
            result.append(QJsonArray{"restore"});
        };
        if (progress < 1 && m_fromPage) {
            layer(commands, 1, 0);
            layer(m_old, 1, m_fromDrag + (height - m_fromDrag) * eased);
        } else if (progress < 1 && m_toPage) {
            layer(m_old, 1, 0);
            layer(commands, 1, height * (1 - eased));
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
    QString m_key;
    QJsonArray m_last;
    QJsonArray m_old;
    double m_start = -1;
    double m_drag = 0;
    double m_fromDrag = 0;
    double m_lastTime = 0;
    bool m_fromPage = false;
    bool m_toPage = false;
    bool m_returning = false;
    bool m_followScene = false;
    bool m_enteringScene = false;
    bool m_sceneRunning = false;
};
