#include "DesktopLyricsAppearance.h"
#include "Host.h"
#include <QColor>
#include <QStringList>
#include <algorithm>
#include <cmath>

namespace {

int readInteger(const QString &value, int fallback, int minimum, int maximum) {
    bool ok = false;
    const int parsed = value.toInt(&ok);
    return ok ? std::clamp(parsed, minimum, maximum) : fallback;
}

double readOutline(const QString &value, double fallback) {
    bool ok = false;
    const double parsed = value.toDouble(&ok);
    const double clamped = std::clamp(ok ? parsed : fallback, 0.0, DesktopLyrics::MaximumOutline);
    return std::round(clamped / DesktopLyrics::OutlineStep) * DesktopLyrics::OutlineStep;
}

QString readColor(const QString &value, const char *fallback) {
    const QColor color(value);
    if (color.isValid()) {
        return color.name(QColor::HexRgb).toLower();
    }
    return QString::fromLatin1(fallback).toLower();
}

QString readWeight(const QString &value, const char *fallback) {
    static const QStringList weights{QStringLiteral("light"), QStringLiteral("regular"),
                                     QStringLiteral("demibold"), QStringLiteral("bold")};
    return weights.contains(value) ? value : QString::fromLatin1(fallback);
}

QString preference(Host *host, const char *key) {
    return host ? host->preference(QString::fromLatin1(key)) : QString();
}

void write(Host *host, const char *key, const QString &value) {
    host->setPreference(QString::fromLatin1(key), value);
}

}

namespace DesktopLyrics {

Appearance readAppearance(Host *host) {
    Appearance appearance;
    if (!host) {
        return appearance;
    }
    appearance.lineSize =
        readInteger(preference(host, LineSizeKey), DefaultLineSize, MinimumLineSize, MaximumLineSize);
    appearance.translationSize = readInteger(preference(host, TranslationSizeKey), DefaultTranslationSize,
                                             MinimumTranslationSize, MaximumTranslationSize);
    appearance.opacity =
        readInteger(preference(host, OpacityKey), DefaultOpacity, MinimumOpacity, MaximumOpacity);
    appearance.lineColor = readColor(preference(host, LineColorKey), DefaultLineColor);
    appearance.translationColor = readColor(preference(host, TranslationColorKey), DefaultTranslationColor);
    appearance.lineWeight = readWeight(preference(host, LineWeightKey), DefaultLineWeight);
    appearance.translationWeight =
        readWeight(preference(host, TranslationWeightKey), DefaultTranslationWeight);
    appearance.lineOutline = readOutline(preference(host, LineOutlineKey), DefaultLineOutline);
    appearance.translationOutline =
        readOutline(preference(host, TranslationOutlineKey), DefaultTranslationOutline);
    appearance.lineOutlineColor = readColor(preference(host, LineOutlineColorKey), DefaultOutlineColor);
    appearance.translationOutlineColor =
        readColor(preference(host, TranslationOutlineColorKey), DefaultOutlineColor);
    return appearance;
}

void resetAppearance(Host *host) {
    if (!host) {
        return;
    }
    write(host, LineSizeKey, QString::number(DefaultLineSize));
    write(host, TranslationSizeKey, QString::number(DefaultTranslationSize));
    write(host, OpacityKey, QString::number(DefaultOpacity));
    write(host, LineColorKey, QString::fromLatin1(DefaultLineColor));
    write(host, TranslationColorKey, QString::fromLatin1(DefaultTranslationColor));
    write(host, LineWeightKey, QString::fromLatin1(DefaultLineWeight));
    write(host, TranslationWeightKey, QString::fromLatin1(DefaultTranslationWeight));
    write(host, LineOutlineKey, QString::number(DefaultLineOutline, 'f', 1));
    write(host, TranslationOutlineKey, QString::number(DefaultTranslationOutline, 'f', 1));
    write(host, LineOutlineColorKey, QString::fromLatin1(DefaultOutlineColor));
    write(host, TranslationOutlineColorKey, QString::fromLatin1(DefaultOutlineColor));
}

bool isAppearanceKey(const QString &key) {
    static const QStringList keys{
        QString::fromLatin1(TranslationSizeKey),  QString::fromLatin1(OpacityKey),
        QString::fromLatin1(LineColorKey),        QString::fromLatin1(TranslationColorKey),
        QString::fromLatin1(LineWeightKey),       QString::fromLatin1(TranslationWeightKey),
        QString::fromLatin1(LineOutlineKey),      QString::fromLatin1(TranslationOutlineKey),
        QString::fromLatin1(LineOutlineColorKey), QString::fromLatin1(TranslationOutlineColorKey),
    };
    // 正文字号沿用旧键，但和其余外观项一样需要触发重排。
    return key == QLatin1String(LineSizeKey) || keys.contains(key);
}

}
