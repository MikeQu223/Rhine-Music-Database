#include "DesktopLyricsSettings.h"
#include "DesktopLyricsLayout.h"
#include "Host.h"
#include <algorithm>

namespace {

constexpr const char *PreferenceKey = "desktop-lyrics";
constexpr const char *SizeKey = "desktop-lyrics-size";
constexpr const char *OpacityKey = "desktop-lyrics-opacity";
constexpr const char *On = "on";
constexpr const char *Off = "off";

int readInteger(const QString &value, int fallback, int minimum, int maximum) {
    bool ok = false;
    const int parsed = value.toInt(&ok);
    return ok ? std::clamp(parsed, minimum, maximum) : fallback;
}

}

DesktopLyricsSettings::DesktopLyricsSettings(Host *host, QObject *parent) : QObject(parent), m_host(host) {
    if (!m_host) {
        return;
    }
    m_enabled = m_host->preference(QLatin1String(PreferenceKey)) == QLatin1String(On);
    m_fontSize = readInteger(m_host->preference(QLatin1String(SizeKey)), DesktopLyrics::DefaultFontSize,
                             DesktopLyrics::MinimumFontSize, DesktopLyrics::MaximumFontSize);
    m_opacity = readInteger(m_host->preference(QLatin1String(OpacityKey)), DesktopLyrics::DefaultOpacity,
                            DesktopLyrics::MinimumOpacity, DesktopLyrics::MaximumOpacity);
    connect(m_host, &Host::preferenceChanged, this, &DesktopLyricsSettings::applyPreference);
}

bool DesktopLyricsSettings::enabled() const {
    return m_enabled;
}

int DesktopLyricsSettings::fontSize() const {
    return m_fontSize;
}

int DesktopLyricsSettings::opacity() const {
    return m_opacity;
}

void DesktopLyricsSettings::setEnabled(bool enabled) {
    if (enabled == m_enabled) {
        return;
    }
    m_enabled = enabled;
    emit enabledChanged(m_enabled);
    if (m_host) {
        m_host->setPreference(QLatin1String(PreferenceKey), QLatin1String(enabled ? On : Off));
        // 托盘与设置页共享同一个偏好；唤醒 HUD 让已打开的设置行立即重绘。
        m_host->invalidate();
    }
}

void DesktopLyricsSettings::applyPreference(const QString &key, const QString &value) {
    if (key == QLatin1String(PreferenceKey)) {
        const bool enabled = value == QLatin1String(On);
        if (enabled == m_enabled) {
            return;
        }
        m_enabled = enabled;
        emit enabledChanged(m_enabled);
        return;
    }
    if (key == QLatin1String(SizeKey)) {
        const int size =
            readInteger(value, m_fontSize, DesktopLyrics::MinimumFontSize, DesktopLyrics::MaximumFontSize);
        if (size != m_fontSize) {
            m_fontSize = size;
            emit appearanceChanged();
        }
        return;
    }
    if (key == QLatin1String(OpacityKey)) {
        const int opacity =
            readInteger(value, m_opacity, DesktopLyrics::MinimumOpacity, DesktopLyrics::MaximumOpacity);
        if (opacity != m_opacity) {
            m_opacity = opacity;
            emit appearanceChanged();
        }
    }
}
