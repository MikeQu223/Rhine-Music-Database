#include "AppIdentity.h"
#include "AppStorage.h"
#include "Host.h"
#include "qrcodegen.hpp"
#include <QPainter>

QImage platformQR(const QString &text) {
    const auto utf8 = text.toUtf8();
    // 两端使用同一字节模式、M 级纠错和模块比例，登录协议载荷保持不变。
    const std::vector<uint8_t> bytes(utf8.begin(), utf8.end());
    const auto qr = qrcodegen::QrCode::encodeSegments({qrcodegen::QrSegment::makeBytes(bytes)},
                                                      qrcodegen::QrCode::Ecc::MEDIUM, 1, 40, -1, false);
    constexpr int border = 4, scale = 8;
    QImage image((qr.getSize() + 2 * border) * scale, (qr.getSize() + 2 * border) * scale,
                 QImage::Format_RGB32);
    image.fill(Qt::white);
    QPainter painter(&image);
    for (int y = 0; y < qr.getSize(); ++y) {
        for (int x = 0; x < qr.getSize(); ++x) {
            if (qr.getModule(x, y)) {
                painter.fillRect((x + border) * scale, (y + border) * scale, scale, scale, Qt::black);
            }
        }
    }
    return image;
}
#ifndef Q_OS_MACOS
bool platformActivates() {
    return AppStorage::settings().value(AppIdentity::PlayerPreference, false).toBool();
}
void platformSetActivates(bool value) {
    AppStorage::settings().setValue(AppIdentity::PlayerPreference, value);
}
#endif

// 空桩只留给既没有原生媒体集成、也没有专用实现的平台。Android 的凭据与播放交付
// 在 PlatformAndroid.cpp 里，不能在这里再定义一份。
#if !defined(Q_OS_MACOS) && !defined(Q_OS_WIN) && !defined(Q_OS_IOS) && !defined(Q_OS_ANDROID)
void platformMediaCommands(std::function<void(QString)>) {
}
void platformMediaInfo(QString, QString, QString, QVariantMap, const QString &) {
}
#endif
