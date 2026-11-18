#pragma once

#include <QStandardPaths>
#include <QString>

// 性能报告与崩溃报告共用同一目录，不依赖性能面板是否创建。
inline QString diagnosticsDirectory() {
    return QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation) + "/RHINE Diagnostics";
}
