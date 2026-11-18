#include "DiscoverArtwork.h"
#include "Host.h"
#include <QPointer>

DiscoverArtwork::DiscoverArtwork(Host *host, QObject *parent, int maximumDimension)
    : QObject(parent), m_host(host), m_maximumDimension(maximumDimension) {
}

/** 滚动、切换来源或账号时作废旧回调；失败封面保持占位，不在每帧重试。 */
void DiscoverArtwork::show(const QString &scope, const QStringList &urls) {
    bool changed = scope != m_scope;
    if (changed) {
        m_scope = scope;
        m_urls.clear();
    }
    if (urls != m_urls) {
        m_urls = urls;
        changed = true;
    }
    if (!changed) {
        return;
    }
    m_images.clear();
    m_requested.clear();
    ++m_generation;
    for (const auto &url : urls) {
        request(url);
    }
}

void DiscoverArtwork::request(const QString &url) {
    if (url.isEmpty() || m_requested.contains(url)) {
        return;
    }
    m_requested.insert(url);
    const auto generation = m_generation;
    m_host->loadCover(
        url,
        [owner = QPointer(this), generation, url](QString key) {
            if (!owner || generation != owner->m_generation) {
                return;
            }
            if (!key.isEmpty()) {
                owner->m_images[url] = key;
                owner->m_host->invalidate();
            }
        },
        m_maximumDimension);
}

/** 行渲染到屏幕时才请求封面；已缓存的图片直接返回缓存键，避免重复下载。 */
QString DiscoverArtwork::image(const QString &url) {
    if (url.isEmpty()) {
        return {};
    }
    const auto cachedKey = m_images.value(url);
    if (!cachedKey.isEmpty() && !m_host->image(cachedKey).isNull()) {
        return cachedKey;
    }
    // Host 的内存图片可能已被预算淘汰；清除旧键后重新走磁盘缓存。
    if (!cachedKey.isEmpty()) {
        m_images.remove(url);
        m_requested.remove(url);
    }
    request(url);
    return m_images.value(url);
}
