#include "NativeHud.h"
#include "DiscoverArtwork.h"
#include "DiscoverMusicCard.h"
#include "MusicDiscover.h"
#include "ProviderRegistry.h"
#include <QUrl>
#include <algorithm>

/** 仅适配发现页的真实数据、权限入口与显示偏移；平台加载和打开动作仍由原控制器执行。 */
void NativeHud::discoverPanel(double x, double y, double width) {
    auto &music = *m_music;
    const auto &discover = *music.discover;
    DiscoverMusicCard::Model model;
    model.bounds = {x, y, width, 836};
    model.dark = dark;
    model.tab = discover.tab;
    model.status = discover.status;
    model.loading = discover.loading;
    model.more = discover.more;
    model.loadedCount = discover.items.size();
    if (m_responsive.compact()) {
        model.onePage = true;
        const auto makeSection = [&](const QString &id, const QString &source, const QString &title,
                                     const QString &english, bool featured, int first, int count) {
            const auto state = discover.sections.constFind(source);
            if (state == discover.sections.cend()) {
                return;
            }
            DiscoverMusicCard::Section section;
            section.id = id;
            section.source = source;
            section.title = title;
            section.english = english;
            section.status = state->status;
            section.loading = state->loading;
            section.failed = state->failed;
            section.featured = featured;
            const int last = std::min(int(state->items.size()), first + count);
            for (int index = first; index < last; ++index) {
                const auto item = state->items.at(index).toObject();
                DiscoverMusicCard::Entry entry;
                entry.section = id;
                entry.index = index;
                entry.title = item["title"].toString();
                entry.artist = item["artist"].toString();
                entry.kind = item["kind"].toString();
                entry.imageAspect = 1.;
                section.entries.append(entry);
            }
            if (section.entries.isEmpty() && section.status.isEmpty() && !section.loading) {
                section.status = QStringLiteral("暂无内容");
            }
            if (section.entries.isEmpty() && id == QStringLiteral("recommended")) {
                section.status = QStringLiteral("暂无更多推荐");
            }
            model.sections.append(section);
        };

        makeSection("featured", "playlists", "精选推荐", "FEATURED / INDEX", true, 0, 4);
        makeSection("daily", "daily", "每日推荐", "DAILY SELECTION", false, 0, 8);
        makeSection("recommended", "playlists", "推荐歌单", "RECOMMENDED / INDEX", false, 4, 8);
        makeSection("artists", "artists", "收藏歌手", "SAVED ARTISTS", false, 0, 8);
        makeSection("charts", "charts", "排行榜", "CHART INDEX", false, 0, 8);
        makeSection("albums", "albums", "新专辑", "NEW RELEASES", false, 0, 8);
        makeSection("categories", "categories", "分类歌单", "PLAYLIST CATEGORIES", false, 0, 8);
        makeSection("history", "history", "最近播放", "LISTENING HISTORY", false, 0, 8);

        QStringList urls;
        const auto visibleEntries = m_responsive.discoverVisibleEntries(model);
        for (const auto &[sectionIndex, entryIndex] : visibleEntries) {
            auto &section = model.sections[sectionIndex];
            const auto state = discover.sections.constFind(section.source);
            if (state == discover.sections.cend()) {
                continue;
            }
            auto &entry = section.entries[entryIndex];
            const auto item = state->items.at(entry.index).toObject();
            const auto cover = item["cover"].toString();
            entry.image = cover;
            if (!cover.isEmpty() && !urls.contains(cover)) {
                urls.append(cover);
            }
        }
        if (!m_discoverArtwork) {
            m_discoverArtwork = new DiscoverArtwork(m_host, this);
        }
        const auto scope = music.provider + ":" + QString::number(music.accountGeneration()) +
                           ":sections:" + QString::number(discover.sectionsGeneration);
        m_discoverArtwork->show(scope, urls);
        for (const auto &[sectionIndex, entryIndex] : visibleEntries) {
            auto &section = model.sections[sectionIndex];
            auto &entry = section.entries[entryIndex];
            const auto key = m_discoverArtwork->image(entry.image);
            const auto cover = m_host->image(key);
            entry.image = key;
            if (!cover.isNull()) {
                entry.imageAspect = double(cover.width()) / cover.height();
            }
        }
        m_responsive.setDiscover(model);
        if (!m_pendingDiscoverSection.isEmpty()) {
            for (const auto &section : model.sections) {
                if (section.id != m_pendingDiscoverSection) {
                    continue;
                }
                if (!section.loading || !section.entries.isEmpty()) {
                    m_responsive.focusDiscoverSection(section.id);
                    m_pendingDiscoverSection.clear();
                }
                break;
            }
        }
        return;
    }
    QVector<QPair<QString, QString>> tabs;
    for (const auto &value : ProviderRegistry::instance().discoverTabs(music.provider)) {
        const auto tab = value.toObject();
        if (tab["id"].isString()) {
            tabs.append({tab["id"].toString(), tab["label"].toString(tab["id"].toString())});
        }
    }
    if (tabs.isEmpty()) {
        tabs = {{"playlists", "推荐歌单"}, {"daily", "每日推荐"},      {"charts", "排行榜"},
                {"albums", "新专辑"},      {"categories", "分类歌单"}, {"artists", "收藏歌手"},
                {"history", "历史"}};
    }
    for (const auto &[key, label] : tabs) {
        model.tabs.append(DiscoverMusicCard::Choice{label, "discover:tab:" + key, discover.tab == key});
    }
    if (discover.tab == "categories") {
        model.categoriesLoading = discover.categoriesLoading;
        model.categoryStatus = discover.categoryStatus;
        QJsonArray categories;
        if (discover.categories.isEmpty()) {
            categories.append(QJsonObject{{"id", "全部"}, {"name", "全部"}});
        }
        for (const auto &category : discover.categories) {
            categories.append(category);
        }
        if (categoryPicker) {
            model.categoryPicker = true;
            model.categoryPages =
                std::max(1, (int(categories.size()) + CategoryPageSize - 1) / CategoryPageSize);
            categoryPage = std::clamp(categoryPage, 0, model.categoryPages - 1);
            model.categoryPage = categoryPage;
            model.tools.append(DiscoverMusicCard::Choice{"← 返回列表", "discover:categories"});
            for (int index = categoryPage * CategoryPageSize;
                 index < std::min(int(categories.size()), (categoryPage + 1) * CategoryPageSize); ++index) {
                const auto category = categories.at(index).toObject();
                const auto id = category["id"].toString();
                model.categories.append(
                    {category["name"].toString(),
                     "discover:category:" + QString::fromUtf8(QUrl::toPercentEncoding(id)),
                     id == discover.category});
            }
        } else {
            QString name = "全部";
            for (const auto &value : categories) {
                const auto category = value.toObject();
                if (category["id"] == discover.category) {
                    name = category["name"].toString();
                    break;
                }
            }
            model.tools.append(DiscoverMusicCard::Choice{"分类：" + name + " ↓", "discover:categories"});
        }
    } else if (discover.tab == "guess") {
        model.tools.append(DiscoverMusicCard::Choice{"换一批推荐 ↻", "discover:tab:guess"});
    } else if (discover.tab == "daily") {
        model.tools.append(DiscoverMusicCard::Choice{"在资料库打开 ↗", "discover:open"});
    } else if (discover.tab == "new-songs") {
        for (const auto &value : discover.newSongAreas) {
            const auto area = value.toObject();
            const auto id = QString::number(area["id"].toInt());
            model.tools.append(DiscoverMusicCard::Choice{area["name"].toString(), "discover:area:" + id,
                                                         id == discover.newSongArea});
        }
    } else if (discover.tab == "playlists") {
        model.tools.append(DiscoverMusicCard::Choice{"每日推荐 ↗", "discover:tab:daily"});
    }
    const auto scrollScope =
        music.provider + ":" + QString::number(music.accountGeneration()) + ":" + discover.tab;
    if (m_discoverScrollScope != scrollScope) {
        discoverScroll = 0;
        m_discoverScrollScope = scrollScope;
    }
    if (!m_responsive.compact()) {
        discoverScrollMaximum = DiscoverMusicCard::layout(model.bounds, model.loadedCount).maximumScroll;
        discoverScroll = std::clamp(discoverScroll, 0., discoverScrollMaximum);
        model.scroll = discoverScroll;
    }
    const auto indices =
        model.categoryPicker
            ? QVector<int>{}
            : DiscoverMusicCard::visibleIndices(model.bounds, model.loadedCount, model.scroll);
    QStringList urls;
    for (const auto index : indices) {
        urls.append(discover.items.at(index).toObject()["cover"].toString());
    }
    if (!m_discoverArtwork) {
        m_discoverArtwork = new DiscoverArtwork(m_host, this);
    }
    const auto scope = music.provider + ":" + QString::number(music.accountGeneration()) + ":" +
                       QString::number(discover.generation);
    m_discoverArtwork->show(scope, urls);
    for (const auto index : indices) {
        const auto item = discover.items.at(index).toObject();
        DiscoverMusicCard::Entry entry;
        entry.index = index;
        entry.title = item["title"].toString();
        entry.artist = item["artist"].toString();
        entry.kind = item["kind"].toString();
        const auto key = m_discoverArtwork->image(item["cover"].toString());
        const auto cover = m_host->image(key);
        if (!cover.isNull()) {
            entry.image = key;
            entry.imageAspect = double(cover.width()) / cover.height();
        }
        model.entries.append(entry);
    }
    const DiscoverMusicCard::Canvas canvas{
        [this](double x, double y, double width, double height, QJsonArray color) {
            fill(x, y, width, height, color);
        },
        [this](QString value, double x, double y, double size, QString weight, QJsonArray color) {
            text(value, x, y, size, weight, 0, color);
        },
        [this](QString value, double size, double width, QString weight) {
            return fit(value, size, width, weight);
        },
        [this](QString value, double width, double size, QString weight) {
            return m_glyphs->wrap(value, width, size, weight);
        },
        [this](double x, double y, double width, double height, QString action, QString label) {
            hit(x, y, width, height, action, label);
        },
        [this](QString key, double x, double y, double width, double height) {
            image(key, x, y, width, height);
        },
        [this](double x, double y, double radius, QJsonArray color) {
            op({"ellipse", color, x - radius, y - radius, radius * 2, radius * 2});
        },
        [this](QString value, double size, QString weight) { return m_glyphs->width(value, size, weight); },
        [this](QJsonArray command) { op(command); }};
    if (m_responsive.compact()) {
        m_responsive.setDiscover(model);
        return;
    }
    DiscoverMusicCard::paint(model, canvas);
}
