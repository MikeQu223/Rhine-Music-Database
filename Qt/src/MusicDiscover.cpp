#include "MusicDiscover.h"
#include "MusicData.h"
#include "MusicLibrary.h"
#include "ProviderRegistry.h"
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

/** 竖屏单页一次加载所有可用发现栏目；每个栏目独立保存状态，迟到响应互不覆盖。 */
void MusicDiscover::loadSections() {
    ++sectionsGeneration;
    sectionOrder.clear();
    QStringList tabs;
    const QStringList supported = {"playlists",  "daily",   "charts", "albums",
                                   "categories", "artists", "history"};
    bool configured = false;
    for (const auto &value : ProviderRegistry::instance().discoverTabs(m_store->provider)) {
        const auto id = value.toObject()["id"].toString();
        configured = configured || !id.isEmpty();
        if (supported.contains(id) && !tabs.contains(id)) {
            tabs.append(id);
        }
    }
    if (tabs.isEmpty() && !configured) {
        tabs = {"playlists", "daily", "charts", "albums", "categories", "artists", "history"};
    }
    for (auto it = sections.begin(); it != sections.end();) {
        if (tabs.contains(it.key())) {
            ++it;
        } else {
            it = sections.erase(it);
        }
    }
    for (const auto &id : tabs) {
        sectionOrder.append(id);
        if (!sections.contains(id)) {
            sections.insert(id, SectionState{});
        }
        sections[id].loading = false;
        ensureSection(id, true);
    }
}

void MusicDiscover::ensureSection(const QString &id, bool preserve) {
    if (id.isEmpty() || !sections.contains(id)) {
        return;
    }
    auto &state = sections[id];
    if (state.loading) {
        return;
    }
    const auto generation = sectionsGeneration;
    const auto token = ++state.generation;
    const auto account = m_store->accountGeneration();
    state.attempted = true;
    state.loading = true;
    state.failed = false;
    if (!preserve) {
        state.status = QStringLiteral("正在读取…");
        state.items = {};
        state.offset = 0;
        state.more = false;
    } else if (state.status.isEmpty()) {
        state.status = QStringLiteral("正在读取…");
    }
    m_store->changed();

    if ((id == "daily" || id == "guess") && m_store->uid.isEmpty()) {
        state.loading = false;
        state.failed = false;
        state.status = QStringLiteral("登录后查看每日推荐");
        m_store->changed();
        return;
    }
    if (id == "artists" && m_store->uid.isEmpty()) {
        state.loading = false;
        state.failed = false;
        state.status = QStringLiteral("登录后查看收藏歌手");
        m_store->changed();
        return;
    }
    if (id == "history") {
        QJsonArray history;
        for (const auto &value : m_store->player.history) {
            if (value.toObject()["provider"].toString(m_store->provider) == m_store->provider) {
                history.append(value);
            }
        }
        state.items = history;
        state.loading = false;
        state.failed = false;
        state.status =
            state.items.isEmpty()
                ? QStringLiteral("暂无播放历史")
                : QStringLiteral("已载入 ") + QString::number(state.items.size()) + QStringLiteral(" 条");
        m_store->changed();
        return;
    }

    const auto alive = [owner = QPointer(m_store), generation, token, id, account] {
        return owner && owner->discover->sectionsGeneration == generation &&
               owner->discover->sections.value(id).generation == token &&
               owner->accountGeneration() == account;
    };
    const auto categoryArgument = id == "categories" ? QStringLiteral("全部") : category;
    m_store->api.call(
        "discover", {id, 0, id == "new-songs" ? newSongArea : categoryArgument},
        [this, generation, token, id](MusicReply result) {
            if (sectionsGeneration != generation || !sections.contains(id) ||
                sections[id].generation != token) {
                return;
            }
            auto &section = sections[id];
            if (!result.ok()) {
                section.failed = true;
                section.status = result.error;
            } else {
                section.failed = false;
                const auto page = result.value.toObject();
                section.items = page["items"].toArray();
                section.offset = page["rawCount"].toInt();
                section.more = page["more"].toBool();
                section.status = section.items.isEmpty()
                                     ? QStringLiteral("暂无内容")
                                     : QStringLiteral("已载入 ") + QString::number(section.items.size()) +
                                           QStringLiteral(" 条");
                if (id == "artists") {
                    for (const auto &value : section.items) {
                        m_store->subscriptions.insert(value.toObject()["key"].toString());
                    }
                }
                if (id == "new-songs") {
                    newSongAreas = page["areas"].toArray();
                    newSongArea = QString::number(page["area"].toInt(5));
                }
            }
            section.loading = false;
            m_store->changed();
        },
        alive);
}

void MusicDiscover::openSection(const QString &id, int index) {
    const auto section = sections.constFind(id);
    if (section == sections.cend() || index < 0 || index >= section->items.size()) {
        return;
    }
    const auto value = section->items.at(index).toObject();
    m_store->privateSelection = id == "daily" || id == "artists";
    m_store->playContext = section->items;
    if (value["kind"] == "song") {
        m_store->player.play(value, section->items);
        m_store->choose(value);
        emit m_store->modeRequested("detail");
    } else {
        m_store->enterDirectory(value);
    }
}

void MusicDiscover::playSection(const QString &id, int index) {
    const auto section = sections.constFind(id);
    if (section != sections.cend() && index >= 0 && index < section->items.size()) {
        m_store->playCollection(section->items.at(index).toObject());
    }
}

void MusicDiscover::loadCategories() {
    const auto token = ++categoriesGeneration;
    const auto account = m_store->accountGeneration();
    const auto alive = [owner = QPointer(m_store), token, account] {
        return owner && owner->discover->categoriesGeneration == token &&
               owner->accountGeneration() == account;
    };
    categoriesLoading = true;
    categoryStatus = QStringLiteral("正在读取分类…");
    m_store->changed();
    const auto accept = [this](MusicReply result) {
        categoriesLoading = false;
        if (result.ok()) {
            categories = result.value.toArray();
            categoryStatus = categories.isEmpty() ? QStringLiteral("暂无分类") : QString();
        } else {
            categoryStatus = result.error;
        }
        m_store->changed();
    };
    m_store->api.call("categories", {}, accept, alive);
}

void MusicDiscover::cancel() {
    ++generation;
    ++categoriesGeneration;
    ++sectionsGeneration;
    loading = false;
    categoriesLoading = false;
    categoryStatus.clear();
    items = {};
    more = false;
    offset = 0;
    categories = {};
    newSongAreas = {};
    newSongArea = "5";
    category = QStringLiteral("全部");
    tab = "playlists";
    sections.clear();
    sectionOrder.clear();
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
