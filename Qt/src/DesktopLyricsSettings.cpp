#include "DesktopLyricsSettings.h"
#include "DesktopLyricsAppearance.h"
#include "Host.h"

DesktopLyricsSettings::DesktopLyricsSettings(Host *host, QObject *parent) : QObject(parent), m_host(host) {
    if (!m_host) {
        return;
    }
    m_enabled = m_host->preference(QLatin1String(DesktopLyrics::EnabledKey)) == QLatin1String("on");
    m_appearance = DesktopLyrics::readAppearance(m_host);
    connect(m_host, &Host::preferenceChanged, this, &DesktopLyricsSettings::applyPreference);
}

bool DesktopLyricsSettings::enabled() const {
    return m_enabled;
}

DesktopLyrics::Style DesktopLyricsSettings::style() const {
    return DesktopLyrics::styleFor(m_appearance);
}

void DesktopLyricsSettings::setEnabled(bool enabled) {
    if (enabled == m_enabled) {
        return;
    }
    m_enabled = enabled;
    emit enabledChanged(m_enabled);
    if (m_host) {
        m_host->setPreference(QLatin1String(DesktopLyrics::EnabledKey),
                              QLatin1String(enabled ? "on" : "off"));
        // 托盘与设置页共享同一个偏好；唤醒 HUD 让已打开的设置行立即重绘。
        m_host->invalidate();
    }
}

void DesktopLyricsSettings::applyPreference(const QString &key, const QString &value) {
    if (key == QLatin1String(DesktopLyrics::EnabledKey)) {
        const bool enabled = value == QLatin1String("on");
        if (enabled == m_enabled) {
            return;
        }
        m_enabled = enabled;
        emit enabledChanged(m_enabled);
        return;
    }
    if (!DesktopLyrics::isAppearanceKey(key)) {
        return;
    }
    const auto appearance = DesktopLyrics::readAppearance(m_host);
    if (appearance != m_appearance) {
        m_appearance = appearance;
        emit appearanceChanged();
    }
}
