#include "NativeHud.h"
#include "DiscoverArtwork.h"
#include "DiscoverMusicCard.h"
#include "MusicDiscover.h"
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
    QVector<QPair<QString, QString>> tabs{{"playlists", "推荐歌单"},
                                          {"daily", music.provider == "qq" ? "每日 30 首" : "每日推荐"},
                                          {"charts", "排行榜"},
                                          {"albums", "新专辑"},
                                          {"categories", "分类歌单"}};
    if (music.provider == "qq") {
        tabs.insert(2, {"guess", "猜你喜欢"});
        tabs.insert(3, {"new-songs", "新歌速递"});
    }
    if (music.provider == "netease") {
        tabs.append(QPair<QString, QString>{"artists", "收藏歌手"});
    }
    tabs.append(QPair<QString, QString>{"history", "历史"});
    for (const auto &[key, label] : tabs) {
        model.tabs.append(DiscoverMusicCard::Choice{label, "discover:tab:" + key, discover.tab == key});
    }
    if (discover.tab == "categories") {
        QJsonArray categories;
        if (music.provider != "qq" || discover.categories.isEmpty()) {
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
    discoverScrollMaximum = DiscoverMusicCard::layout(model.bounds, model.loadedCount).maximumScroll;
    discoverScroll = std::clamp(discoverScroll, 0., discoverScrollMaximum);
    model.scroll = discoverScroll;
    const auto indices =
        model.categoryPicker ? QVector<int>{}
        : m_responsive.compact()
            ? m_responsive.discoverVisibleIndices(model.loadedCount, model.tabs.size(), model.tab)
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
    QVector<int> entryIndices = indices;
    if (m_responsive.compact() && !model.categoryPicker) {
        entryIndices.clear();
        for (int index = 0; index < discover.items.size(); ++index) {
            entryIndices.append(index);
        }
    }
    for (const auto index : entryIndices) {
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
