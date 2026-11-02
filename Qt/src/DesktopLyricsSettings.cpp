#include "DesktopLyricsSettings.h"
#include "Host.h"

namespace {

constexpr const char *PreferenceKey = "desktop-lyrics";
constexpr const char *On = "on";
constexpr const char *Off = "off";

}

DesktopLyricsSettings::DesktopLyricsSettings(Host *host, QObject *parent)
    : QObject(parent), m_host(host),
      m_enabled(host && host->preference(QLatin1String(PreferenceKey)) == QLatin1String(On)) {
    if (!m_host) {
        return;
    }
    connect(m_host, &Host::preferenceChanged, this, &DesktopLyricsSettings::applyPreference);
}

bool DesktopLyricsSettings::enabled() const {
    return m_enabled;
}

void DesktopLyricsSettings::setEnabled(bool enabled) {
    if (enabled == m_enabled) {
        return;
    }
    m_enabled = enabled;
    emit enabledChanged(m_enabled);
    if (m_host) {
        m_host->setPreference(QLatin1String(PreferenceKey), QLatin1String(enabled ? On : Off));
        m_host->invalidate();
    }
}

void DesktopLyricsSettings::applyPreference(const QString &key, const QString &value) {
    if (key != QLatin1String(PreferenceKey)) {
        return;
    }
    const bool enabled = value == QLatin1String(On);
    if (enabled == m_enabled) {
        return;
    }
    m_enabled = enabled;
    emit enabledChanged(m_enabled);
}
