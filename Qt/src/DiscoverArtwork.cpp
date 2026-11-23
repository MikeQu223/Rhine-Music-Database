#include "DiscoverArtwork.h"
#include "Host.h"
#include <QPointer>

DiscoverArtwork::DiscoverArtwork(Host *host, QObject *parent, int maximumDimension)
    : QObject(parent), m_host(host), m_maximumDimension(maximumDimension) {
}

/** 滚动、切换来源或账号时作废旧回调；失败封面保持占位，不在每帧重试。 */
void DiscoverArtwork::show(const QString &scope, const QStringList &urls) {
    if (scope != m_scope) {
        m_scope = scope;
        m_urls.clear();
        m_images.clear();
        m_requested.clear();
        ++m_generation;
    }
    if (urls == m_urls) {
        return;
    }
    m_urls = urls;
    const QSet<QString> visible(urls.cbegin(), urls.cend());
    for (auto it = m_images.begin(); it != m_images.end();) {
        if (visible.contains(it.key())) {
            ++it;
        } else {
            it = m_images.erase(it);
        }
    }
    for (auto it = m_requested.begin(); it != m_requested.end();) {
        if (visible.contains(*it)) {
            ++it;
        } else {
            it = m_requested.erase(it);
        }
    }
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
            if (!key.isEmpty() && owner->m_urls.contains(url)) {
                owner->m_images[url] = key;
                owner->m_host->invalidate();
            }
        },
        m_maximumDimension);
}

/** 只查询当前页已经取得键的封面，不会像 image() 那样触发新的加载。 */
bool DiscoverArtwork::hasCachedImage(const QString &url) const {
    const auto key = m_images.value(url);
    return !key.isEmpty() && !m_host->image(key).isNull();
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
