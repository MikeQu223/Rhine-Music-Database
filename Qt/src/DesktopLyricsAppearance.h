#pragma once
#include "DesktopLyricsLayout.h"

class Host;

namespace DesktopLyrics {
// 从偏好读取并规范化外观
Appearance readAppearance(Host *host);
// 恢复字号、颜色、描边、字重与透明度默认值
void resetAppearance(Host *host);
bool isAppearanceKey(const QString &key);
}
