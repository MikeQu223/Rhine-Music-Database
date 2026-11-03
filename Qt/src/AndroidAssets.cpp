#include "AndroidAssets.h"
#include "AppStorage.h"
#include "BuildIdentity.h"
#include <QDebug>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>

namespace {
// 随包资源由 CMake 以 Qt 资源形式编进二进制（前缀 /rhine-assets）。
// 用 qrc 而不是 APK 的 assets/ 有两个硬理由：
//   1. assets/ 的目录枚举依赖 Android asset manager，AAssetDir 不保证列出子目录；
//      构建期生成的清单一旦与真实内容漂移，就会静默漏文件。
//   2. qrc 的内容随 .so 一起映射，读取路径在所有设备上一致，不依赖打包工具的合并规则。
constexpr auto kResourcePrefix = ":/rhine-assets";
// 解包标记：内容随版本与提交变化，标记不一致就整目录重建，避免残留已删除的场景文件。
constexpr auto kStamp = ".rhine-assets";

/** 解包目标。必须是函数而不是全局常量：AppStorage::dataDirectory() 依赖
 *  QCoreApplication 的组织名/程序名，全局对象的构造早于 main()，那时读到的路径是错的。 */
QString resourceTarget() {
    return AppStorage::dataDirectory() + "/resources";
}

QString expectedStamp() {
    return QStringLiteral(RHINE_VERSION "|" RHINE_COMMIT_SHA);
}

bool stampMatches(const QString &target) {
    QFile marker(target + "/" + kStamp);
    if (!marker.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return false;
    }
    return QString::fromUtf8(marker.readAll()).trimmed() == expectedStamp();
}

QStringList resourceEntries() {
    const auto prefix = QString::fromLatin1(kResourcePrefix);
    QStringList entries;
    QDirIterator iterator(prefix, QDir::Files | QDir::NoDotAndDotDot, QDirIterator::Subdirectories);
    while (iterator.hasNext()) {
        iterator.next();
        entries.append(QDir(prefix).relativeFilePath(iterator.filePath()));
    }
    return entries;
}

bool copyEntry(const QString &relative) {
    const auto destination = resourceTarget() + "/" + relative;
    const auto directory = QFileInfo(destination).absolutePath();
    if (!QDir().mkpath(directory)) {
        qWarning().noquote() << "Android: 无法创建资源目录" << directory;
        return false;
    }
    QFile source(QString::fromLatin1(kResourcePrefix) + "/" + relative);
    if (!source.open(QIODevice::ReadOnly)) {
        qWarning().noquote() << "Android: 无法读取内嵌资源" << relative;
        return false;
    }
    QFile target(destination);
    if (!target.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning().noquote() << "Android: 无法写入" << destination;
        return false;
    }
    // 大文件（字体、烘焙场景、打包后的桥接脚本）按块拷贝，避免整份读进内存。
    while (!source.atEnd()) {
        const auto chunk = source.read(1 << 20);
        if (chunk.isEmpty()) {
            break;
        }
        if (target.write(chunk) != chunk.size()) {
            qWarning().noquote() << "Android: 写入不完整" << destination;
            return false;
        }
    }
    target.close();
    return true;
}

QString extract() {
    const auto target = resourceTarget();
    if (stampMatches(target) && QFileInfo::exists(target + "/slots.json")) {
        return target;
    }
    // 旧目录必须先清空：资源切片变化时，增量覆盖会把已删除的文件留在解包结果里。
    QDir(target).removeRecursively();
    if (!QDir().mkpath(target)) {
        qWarning().noquote() << "Android: 无法创建解包目录" << target;
        return {};
    }
    const auto entries = resourceEntries();
    if (entries.isEmpty()) {
        qWarning() << "Android: 二进制里没有内嵌资源";
        return {};
    }
    for (const auto &entry : entries) {
        if (!copyEntry(entry)) {
            return {};
        }
    }
    QFile marker(target + "/" + kStamp);
    if (marker.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        marker.write(expectedStamp().toUtf8());
    }
    qInfo().noquote() << "Android: 已解包" << entries.size() << "个资源到" << target;
    return target;
}
}

QString androidResourceTarget() {
    return resourceTarget();
}

QString androidResourceRoot() {
    // 首次调用完成解包；之后的调用直接复用结果，避免每次请求都遍历一遍资源树。
    static const QString root = extract();
    return root;
}
