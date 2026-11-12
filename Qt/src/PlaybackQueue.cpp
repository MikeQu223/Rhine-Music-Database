#include "PlaybackQueue.h"
#include "MusicApi.h"
#include "ProviderRegistry.h"
#include <QPointer>
#include <QRandomGenerator>
#include <QSet>
#include <algorithm>

namespace {
// 与目录分页一致，避免单次请求携带过多 ID。
constexpr int FetchBatchSize = 100;

/** 去重并剔除无效条目，队列只接受完整歌曲。 */
QJsonArray sanitized(const QJsonArray &values) {
    QJsonArray result;
    QSet<QString> seen;
    for (const auto &value : values) {
        const auto track = value.toObject();
        if (track["kind"] != "song" || track["id"].toString().isEmpty()) {
            continue;
        }
        const auto key = PlaybackQueue::identity(track);
        if (seen.contains(key)) {
            continue;
        }
        seen.insert(key);
        result.append(track);
    }
    return result;
}
} // namespace

PlaybackQueue::PlaybackQueue(MusicApi *api, QObject *parent) : QObject(parent), m_api(api) {
}

QString PlaybackQueue::identity(const QJsonObject &track) {
    return track["provider"].toString() + ":" + track["id"].toString();
}

const QJsonArray &PlaybackQueue::items() const {
    return m_items;
}

int PlaybackQueue::size() const {
    return int(m_items.size());
}

bool PlaybackQueue::isEmpty() const {
    return m_items.isEmpty();
}

QJsonObject PlaybackQueue::at(int row) const {
    if (row < 0 || row >= m_items.size()) {
        return {};
    }
    return m_items.at(row).toObject();
}

int PlaybackQueue::index() const {
    return m_index;
}

QJsonObject PlaybackQueue::current() const {
    return at(m_index);
}

int PlaybackQueue::indexOf(const QJsonObject &track) const {
    const auto key = identity(track);
    for (int row = 0; row < m_items.size(); ++row) {
        if (identity(m_items.at(row).toObject()) == key) {
            return row;
        }
    }
    return -1;
}

int PlaybackQueue::indexOfId(const QString &id) const {
    for (int row = 0; row < m_items.size(); ++row) {
        if (m_items.at(row).toObject()["id"].toString() == id) {
            return row;
        }
    }
    return -1;
}

bool PlaybackQueue::isLoading() const {
    return m_loading;
}

void PlaybackQueue::cancelLoad() {
    ++m_generation;
    m_loading = false;
    m_ids = {};
    m_missing = {};
    m_resolved.clear();
    m_selectedKey.clear();
}

void PlaybackQueue::publish(const QJsonArray &values, const QString &selectedKey) {
    m_items = values;
    m_index = -1;
    if (!selectedKey.isEmpty()) {
        for (int row = 0; row < m_items.size(); ++row) {
            if (identity(m_items.at(row).toObject()) == selectedKey) {
                m_index = row;
                break;
            }
        }
    }
    emit changed();
}

void PlaybackQueue::replace(const QJsonArray &values, const QJsonObject &selected) {
    cancelLoad();
    publish(sanitized(values), selected.isEmpty() ? QString() : identity(selected));
}

void PlaybackQueue::syncSnapshot(const QJsonArray &values, int row) {
    cancelLoad();
    m_items = sanitized(values);
    m_index = row >= 0 && row < m_items.size() ? row : -1;
}

void PlaybackQueue::select(int row) {
    moveTo(row);
}

void PlaybackQueue::selectTrack(const QJsonObject &track) {
    const auto key = identity(track);
    if (m_index >= 0 && m_index < m_items.size() && identity(at(m_index)) == key) {
        return;
    }
    const auto found = indexOf(track);
    if (found >= 0) {
        moveTo(found);
        return;
    }
    if (track["kind"] == "song" && !track["id"].toString().isEmpty()) {
        m_items.append(track);
        m_index = int(m_items.size()) - 1;
        m_selectedKey = key;
        emit changed();
    }
}

bool PlaybackQueue::enqueue(const QJsonObject &track, bool next) {
    if (track["kind"] != "song" || track["id"].toString().isEmpty()) {
        return false;
    }
    // 本地曲目只进入本地队列，避免跨来源混入无法播放的条目。
    if (m_api && ((m_api->provider == "local") != (track["provider"] == "local"))) {
        return false;
    }
    const auto key = identity(track);
    for (int row = 0; row < m_items.size(); ++row) {
        if (row != m_index && identity(m_items.at(row).toObject()) == key) {
            m_items.removeAt(row);
            if (row < m_index) {
                --m_index;
            }
            break;
        }
    }
    const auto position = next ? std::max(0, m_index + 1) : int(m_items.size());
    m_items.insert(position, track);
    const auto currentId = current()["id"].toString();
    const auto id = track["id"].toString();
    if (m_loading && currentId != id) {
        // 补全尚未结束时，同步手动插入的位置，避免后续批次覆盖新队列。
        for (qsizetype index = 0; index < m_ids.size(); ++index) {
            if (m_ids.at(index).toString() == id) {
                m_ids.removeAt(index);
                break;
            }
        }
        qsizetype pendingPosition = next && currentId.isEmpty() ? 0 : m_ids.size();
        if (next && !currentId.isEmpty()) {
            for (qsizetype index = 0; index < m_ids.size(); ++index) {
                if (m_ids.at(index).toString() == currentId) {
                    pendingPosition = index + 1;
                    break;
                }
            }
        }
        m_ids.insert(pendingPosition, id);
        m_resolved.insert(m_provider + ":" + id, track);
    }
    emit changed();
    return true;
}

bool PlaybackQueue::remove(int row) {
    if (row < 0 || row >= m_items.size() || row == m_index) {
        return false;
    }
    if (m_loading) {
        const auto removedId = at(row)["id"];
        for (qsizetype index = 0; index < m_ids.size(); ++index) {
            if (m_ids.at(index) == removedId) {
                m_ids.removeAt(index);
                break;
            }
        }
    }
    m_items.removeAt(row);
    if (row < m_index) {
        --m_index;
    }
    emit changed();
    return true;
}

void PlaybackQueue::updateCurrent(const QJsonObject &track) {
    if (m_index < 0 || m_index >= m_items.size() || identity(at(m_index)) != identity(track)) {
        return;
    }
    m_items.replace(m_index, track);
    emit changed();
}

void PlaybackQueue::clearUpcoming(const QJsonObject &current) {
    cancelLoad();
    if (current.isEmpty() || current["kind"] != "song") {
        m_items = {};
        m_index = -1;
    } else {
        m_items = QJsonArray{current};
        m_index = 0;
    }
    emit changed();
}

void PlaybackQueue::clear() {
    cancelLoad();
    m_items = {};
    m_index = -1;
    emit changed();
}

void PlaybackQueue::moveTo(int row) {
    if (row < 0 || row >= m_items.size() || row == m_index) {
        return;
    }
    m_index = row;
    m_selectedKey = identity(at(row));
    emit changed();
}

void PlaybackQueue::setShuffle(bool enabled, bool reshuffle) {
    m_shuffle = enabled;
    if (enabled && reshuffle) {
        shuffle();
    }
}

/** 打乱一次可见队列，当前曲目固定在本轮起点；加载中的条目沿同一顺序补全。 */
void PlaybackQueue::shuffle() {
    const auto playing = current();
    const auto selected = playing.isEmpty() ? QString() : identity(playing);
    QVector<QJsonValue> remaining;
    for (const auto &value : m_items) {
        if (selected.isEmpty() || identity(value.toObject()) != selected) {
            remaining.append(value);
        }
    }
    auto &random = *QRandomGenerator::global();
    std::shuffle(remaining.begin(), remaining.end(), random);
    QJsonArray shuffled;
    if (!playing.isEmpty()) {
        shuffled.append(playing);
    }
    for (const auto &value : remaining) {
        shuffled.append(value);
    }
    if (m_loading) {
        // 已展示的歌曲优先按打乱后的顺序保留；未补全的歌曲随机排在队尾。
        orderShuffleIds(shuffled);
    }
    publish(shuffled, selected);
}

void PlaybackQueue::orderShuffleIds(const QJsonArray &known) {
    QSet<QString> seen;
    QJsonArray ordered;
    for (const auto &value : known) {
        const auto id = value.toObject()["id"].toString();
        seen.insert(id);
        ordered.append(id);
    }
    QVector<QJsonValue> missing;
    for (const auto &value : m_ids) {
        if (!seen.contains(value.toString())) {
            missing.append(value);
        }
    }
    std::shuffle(missing.begin(), missing.end(), *QRandomGenerator::global());
    for (const auto &value : missing) {
        ordered.append(value);
    }
    m_ids = ordered;
}

int PlaybackQueue::nextIndex(const QString &mode) const {
    if (m_items.isEmpty()) {
        return -1;
    }
    const auto count = int(m_items.size());
    if (mode == "one") {
        return std::max(m_index, 0);
    }
    const auto next = m_index + 1;
    return mode == "off" && next >= count ? -1 : next % count;
}

int PlaybackQueue::navigate(int direction, const QString &mode) {
    if (m_items.isEmpty()) {
        return -1;
    }
    // 单曲循环的前后项都指向当前歌曲，手动切换与播放结束共用同一索引。
    if (mode == "one") {
        return m_index >= 0 ? m_index : 0;
    }
    if (direction == 1) {
        const auto selected = nextIndex(mode);
        if (selected >= 0) {
            moveTo(selected);
        }
        return selected;
    }
    const auto count = int(m_items.size());
    auto selected = m_index + direction;
    if (selected >= count && mode == "off") {
        return -1;
    }
    selected = (selected % count + count) % count;
    moveTo(selected);
    return selected;
}

void PlaybackQueue::load(const QJsonArray &ids, const QJsonArray &known) {
    cancelLoad();
    m_provider = m_api && !m_api->provider.isEmpty()
                     ? m_api->provider
                     : ProviderRegistry::instance().fallbackId();
    if (m_index >= 0 && m_index < m_items.size()) {
        m_selectedKey = identity(m_items.at(m_index).toObject());
    }
    QSet<QString> seen;
    const auto appendID = [this, &seen](const QString &id) {
        if (id.isEmpty()) {
            return;
        }
        const auto key = m_provider + ":" + id;
        if (seen.contains(key)) {
            return;
        }
        seen.insert(key);
        m_ids.append(id);
    };
    for (const auto &value : ids) {
        appendID(value.toString());
    }
    // 已在队列中的完整曲目（例如刚插入的当前曲）必须保留，不能被补全过程挤掉。
    const auto absorb = [this, &appendID](const QJsonArray &values) {
        for (const auto &value : values) {
            const auto track = value.toObject();
            if (track["kind"] != "song" || track["id"].toString().isEmpty()) {
                continue;
            }
            m_resolved.insert(m_provider + ":" + track["id"].toString(), track);
            appendID(track["id"].toString());
        }
    };
    absorb(m_items);
    absorb(known);
    if (m_shuffle) {
        orderShuffleIds(m_items);
    }
    m_missing = {};
    for (const auto &value : m_ids) {
        if (!m_resolved.contains(m_provider + ":" + value.toString())) {
            m_missing.append(value);
        }
    }
    publishResolved();
    if (m_missing.isEmpty()) {
        return;
    }
    m_loading = true;
    fetchNext();
}

QJsonArray PlaybackQueue::orderedResolved() const {
    QJsonArray result;
    QSet<QString> seen;
    for (const auto &value : m_ids) {
        const auto key = m_provider + ":" + value.toString();
        const auto track = m_resolved.value(key);
        if (track.isEmpty() || seen.contains(key)) {
            continue;
        }
        seen.insert(key);
        result.append(track);
    }
    return result;
}

void PlaybackQueue::publishResolved() {
    // 补全期间用户可能换曲，优先使用当前索引对应的歌曲身份。
    auto selected = m_selectedKey;
    if (m_index >= 0 && m_index < m_items.size()) {
        selected = identity(at(m_index));
    }
    publish(orderedResolved(), selected);
}

void PlaybackQueue::fetchNext() {
    if (m_missing.isEmpty()) {
        m_loading = false;
        publishResolved();
        return;
    }
    QJsonArray batch;
    QJsonArray rest;
    for (int row = 0; row < m_missing.size(); ++row) {
        if (row < FetchBatchSize) {
            batch.append(m_missing.at(row));
        } else {
            rest.append(m_missing.at(row));
        }
    }
    m_missing = rest;
    const auto generation = m_generation;
    m_api->call(
        "songs", {batch},
        [this, generation](MusicReply result) {
            if (generation != m_generation) {
                return;
            }
            // 失败的批次直接跳过，未读取到的曲目不会以占位条目进入队列。
            if (!result.ok()) {
                m_loading = false;
                publishResolved();
                return;
            }
            for (const auto &value : result.value.toArray()) {
                const auto track = value.toObject();
                if (track["kind"] == "song" && !track["id"].toString().isEmpty()) {
                    m_resolved.insert(m_provider + ":" + track["id"].toString(), track);
                }
            }
            publishResolved();
            fetchNext();
        },
        [owner = QPointer(this), generation] { return owner && owner->m_generation == generation; });
}

void PlaybackQueue::restore(const QJsonArray &saved, int savedIndex, bool hydrate) {
    cancelLoad();
    QJsonArray ids;
    QJsonArray complete;
    for (const auto &value : saved) {
        const auto track = value.toObject();
        if (track["kind"] != "song" || track["id"].toString().isEmpty()) {
            continue;
        }
        ids.append(track["id"]);
        if (!track["deferred"].toBool()) {
            complete.append(track);
        }
    }
    const auto selected =
        savedIndex >= 0 && savedIndex < saved.size() ? saved.at(savedIndex).toObject() : QJsonObject{};
    replace(complete, selected["deferred"].toBool() ? QJsonObject{} : selected);
    if (hydrate) {
        load(ids, complete);
    }
}

QJsonArray PlaybackQueue::toJson() const {
    return m_items;
}
