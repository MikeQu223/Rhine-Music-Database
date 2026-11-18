#include "MusicDiscover.h"
#include "MusicData.h"
#include "MusicLibrary.h"
#include <QPointer>

MusicDiscover::MusicDiscover(MusicLibrary *store) : m_store(store) {
}

MusicApi::Valid MusicDiscover::valid(quint64 token, quint64 account) {
    return [owner = QPointer(m_store), token, account] {
        return owner && owner->discover->generation == token && owner->accountGeneration() == account;
    };
}

/** 推荐分页与账号代数一起校验，退出或切换来源后旧推荐不能重新进入当前列表。 */
void MusicDiscover::load(QString nextTab, bool append) {
    if (append && (loading || !more)) {
        return;
    }
    if (!nextTab.isEmpty()) {
        tab = nextTab;
    }
    const auto token = ++generation;
    const auto alive = valid(token, m_store->accountGeneration());
    const auto start = append ? offset : 0;
    loading = true;
    status = QStringLiteral("正在读取…");
    if (!append) {
        items = {};
    }
    m_store->changed();
    if ((tab == "daily" || tab == "guess") && m_store->uid.isEmpty()) {
        accept({{}, QStringLiteral("登录后查看每日推荐"), {}}, tab, start, append);
        return;
    }
    if (tab == "artists" && m_store->uid.isEmpty()) {
        accept({{}, QStringLiteral("登录后查看收藏歌手"), {}}, tab, start, append);
        return;
    }
    if (tab == "history") {
        QJsonArray history;
        for (const auto &value : m_store->player.history) {
            if (value.toObject()["provider"].toString(m_store->provider) == m_store->provider) {
                history.append(value);
            }
        }
        accept({QJsonObject{{"items", history}, {"rawCount", 0}, {"more", false}}, {}, {}}, tab, start,
               append);
        return;
    }
    const auto currentTab = tab;
    m_store->api.call(
        "discover", {tab, start, tab == "new-songs" ? newSongArea : category},
        [this, currentTab, start, append](MusicReply result) { accept(result, currentTab, start, append); },
        alive);
}

void MusicDiscover::accept(MusicReply result, QString currentTab, int start, bool append) {
    if (!result.ok()) {
        status = result.error;
    } else {
        const auto page = result.value.toObject();
        if (currentTab == "categories" && page["category"].isString()) {
            category = page["category"].toString();
        }
        if (currentTab == "new-songs") {
            newSongAreas = page["areas"].toArray();
            newSongArea = QString::number(page["area"].toInt(5));
        }
        items = append ? MusicData::unique(items, page["items"].toArray()) : page["items"].toArray();
        offset = start + page["rawCount"].toInt();
        if (currentTab == "artists") {
            for (const auto &value : items) {
                m_store->subscriptions.insert(value.toObject()["key"].toString());
            }
        }
        more = page["more"].toBool();
        status = items.isEmpty()
                     ? QStringLiteral("暂无内容")
                     : QStringLiteral("已载入 ") + QString::number(items.size()) + QStringLiteral(" 条");
    }
    loading = false;
    m_store->changed();
}

void MusicDiscover::loadCategories() {
    const auto alive = valid(generation, m_store->accountGeneration());
    const auto accept = [this](MusicReply result) {
        if (result.ok()) {
            categories = result.value.toArray();
            m_store->changed();
        } else {
            status = result.error;
        }
    };
    m_store->api.call("categories", {}, accept, alive);
}

void MusicDiscover::cancel() {
    ++generation;
    loading = false;
    items = {};
    more = false;
    offset = 0;
    categories = {};
    newSongAreas = {};
    newSongArea = "5";
    category = QStringLiteral("全部");
    tab = "playlists";
}

void MusicDiscover::open(int index) {
    if (index < 0 || index >= items.size()) {
        return;
    }
    const auto value = items.at(index).toObject();
    m_store->privateSelection = tab == "daily" || tab == "artists";
    // 发现页条目作为单曲打开时，替换队列
    m_store->playContext = items;
    if (value["kind"] == "song") {
        m_store->player.play(value, items);
        m_store->choose(value);
        emit m_store->modeRequested("detail");
    } else {
        m_store->enterDirectory(value);
    }
}
