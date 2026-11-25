#include "NativeHud.h"
#include "MusicData.h"
#include <QUrl>
#include <algorithm>
#include <cmath>

namespace {
constexpr double SearchInset = 53;
constexpr double SearchBarTop = 172;
constexpr double SearchBarHeight = 66;
constexpr double SearchTabTop = 252;
constexpr double SearchTabHeight = 36;
constexpr double SearchTableY = 302;
constexpr double SearchFooterY = 786;
constexpr double SearchKindGap = 26;
constexpr double SearchSortGap = 20;
constexpr double SearchTitleX = 107;
constexpr double SearchActionWidth = 136;

QJsonArray accent() {
    return {0.835, 0.639, 0.282, 1};
}

QJsonArray mutedInk(const QJsonArray &ink) {
    auto value = ink;
    value[3] = 0.55;
    return value;
}

QJsonArray faintInk(const QJsonArray &ink, double alpha) {
    auto value = ink;
    value[3] = alpha;
    return value;
}

QJsonArray searchBarFill(bool dark) {
    return dark ? QJsonArray{0.169, 0.200, 0.173, 1} : QJsonArray{0.898, 0.906, 0.855, 1};
}

QJsonArray searchTagFill(bool dark) {
    return dark ? QJsonArray{1, 1, 1, 0.07} : QJsonArray{0.10, 0.11, 0.10, 0.05};
}
}

/** 检索面板只重排弹窗内部；外框尺寸、位置和 QML 输入框几何均由宿主保持。 */
void NativeHud::searchPanel(double x, double y, double width) {
    searchToolbar(x, y, width);
    searchResultList(x, y, width);
    searchFooter(x, y, width);
}

void NativeHud::searchToolbar(double x, double y, double width) {
    const auto left = x + SearchInset;
    const auto usable = width - SearchInset * 2;
    const auto muted = mutedInk(ink());
    const auto gold = accent();

    // 检索条背景
    fill(left, y + SearchBarTop, usable, SearchBarHeight, searchBarFill(dark));
    fill(left, y + SearchBarTop, 3, SearchBarHeight, gold);
    text("QUERY / 检索词", left + 18, y + SearchBarTop + 10, 9, "regular", 0.08, muted);

    const QStringList kinds{"song", "album", "playlist", "artist"};
    const auto labels = m_music->isLocal() ? QStringList{"歌曲", "专辑", "文件夹", "歌手"}
                                           : QStringList{"歌曲", "专辑", "歌单", "歌手"};
    int activeKind = kinds.indexOf(m_music->searchKind);
    if (activeKind < 0 && m_music->searchKind == "folder") {
        activeKind = 2;
    }
    double cursor = left;
    for (int index = 0; index < labels.size(); ++index) {
        const auto label = labels.at(index);
        const auto labelWidth = m_glyphs->width(label, 13, "regular");
        const bool active = index == activeKind;
        hit(cursor - 4, y + SearchTabTop, labelWidth + 8, SearchTabHeight,
            "music:kind:" + QString::number(index), label);
        text(label, cursor, y + SearchTabTop + 10, 13, active ? "demibold" : "regular", 0,
             active ? ink() : muted);
        if (active) {
            fill(cursor, y + SearchTabTop + SearchTabHeight - 3, labelWidth, 3, gold);
        }
        cursor += labelWidth + SearchKindGap;
    }

    const bool songs =
        std::any_of(m_music->lists[0].cbegin(), m_music->lists[0].cend(),
                    [](const QJsonValue &value) { return value.toObject()["kind"].toString() == "song"; });
    if (songs) {
        const QStringList groupLabels{"原序", "歌手分组", "专辑分组"};
        const QStringList groupKeys{"none", "artist", "album"};
        QVector<double> widths;
        double total = 0;
        for (const auto &label : groupLabels) {
            const auto labelWidth = m_glyphs->width(label, 11, "regular");
            widths.append(labelWidth);
            total += labelWidth;
        }
        total += SearchSortGap * (groupLabels.size() - 1);
        double sortX = x + width - SearchInset - total;
        fill(sortX - 16, y + SearchTabTop + 6, 1, SearchTabHeight - 12, faintInk(ink(), 0.18));
        for (int index = 0; index < groupLabels.size(); ++index) {
            const auto label = groupLabels.at(index);
            const bool active = groupBy == groupKeys.at(index);
            hit(sortX - 4, y + SearchTabTop, widths.at(index) + 8, SearchTabHeight,
                "music:group:" + QString::number(index), label);
            text(label, sortX, y + SearchTabTop + 11, 11, active ? "demibold" : "regular", 0,
                 active ? ink() : muted);
            if (active) {
                fill(sortX, y + SearchTabTop + SearchTabHeight - 2, widths.at(index), 2, gold);
            }
            sortX += widths.at(index) + SearchSortGap;
        }
    }

    rule(left, y + SearchTabTop + SearchTabHeight, usable, 0.18);
    text("ID / 编号", left, y + SearchTableY, 9, "regular", 0.07, muted);
    text("TITLE / 音乐", left + SearchTitleX, y + SearchTableY, 9, "regular", 0.07, muted);
    text("OPEN", x + width - SearchActionWidth, y + SearchTableY, 9, "regular", 0.07, muted);
    rule(left, y + SearchTableY + 16, usable, 0.24);

    if (!activeGroup.isEmpty()) {
        // 分组内的返回入口
        const auto label = QStringLiteral("← 全部分组");
        const auto labelWidth = m_glyphs->width(label, 11, "regular") + 16;
        const auto actionX = x + width - SearchInset - 150 - labelWidth;
        hit(actionX, y + SearchTableY - 7, labelWidth, 28, "music:group-back", "全部分组");
        text(label, actionX + 8, y + SearchTableY, 11, "regular", 0, ink());
    }
}

void NativeHud::searchResultList(double x, double y, double width) {
    const auto left = x + SearchInset;
    const auto usable = width - SearchInset * 2;
    const QRectF viewport(left, y + ResultListTop, usable, ResultListBottom - ResultListTop);
    const auto values = rows(0);
    const auto muted = mutedInk(ink());
    searchRowCount = int(values.size());
    const auto maximum = searchScrollMaximum();
    searchScroll = std::clamp(searchScroll, 0., maximum);

    if (values.isEmpty()) {
        const auto message = m_music->sourceMessage(0);
        text(fit(message, 18, usable, "demibold"), left, y + ResultListTop + 92, 18, "demibold");
        const auto hint = m_music->isLocal() ? QStringLiteral("在文件夹管理中导入音乐后即可检索。")
                                             : QStringLiteral("输入歌曲、歌手、专辑或歌单名称后按 ENTER。");
        text(fit(hint, 12, usable, "regular"), left, y + ResultListTop + 128, 12, "regular", 0, muted);
        return;
    }

    const auto firstHit = hits.size();
    save();
    clip(viewport.x(), viewport.y(), viewport.width(), viewport.height());
    const auto first = std::max(0, int(std::floor(searchScroll / ResultRowHeight)) - 1);
    const auto last = std::min(int(values.size()) - 1,
                               int(std::ceil((searchScroll + viewport.height()) / ResultRowHeight)) + 1);
    for (int index = first; index <= last; ++index) {
        const auto rowY = y + ResultListTop + index * ResultRowHeight - searchScroll;
        resultListRow(values.at(index), x, rowY, width, m_music->keyword, 0);
    }
    restore();
    HudScroll::clipHits(hits, int(firstHit), viewport);

    const auto railX = x + width - 24;
    const auto railTop = viewport.top() + 8;
    const auto railHeight = viewport.height() - 16;
    const auto track = QRectF(railX, railTop, 3, railHeight);
    const auto rail =
        HudScroll::rail(track, searchRowCount * ResultRowHeight, viewport.height(), searchScroll, 30.);
    fill(track.x(), track.y(), track.width(), track.height(), faintInk(ink(), 0.10));
    if (rail.visible) {
        fill(rail.thumb.x(), rail.thumb.y(), rail.thumb.width(), rail.thumb.height(), faintInk(ink(), 0.45));
    }
}

void NativeHud::resultListRow(const Row &entry, double x, double y, double width, const QString &query,
                              int lane) {
    const auto left = x + SearchInset;
    const auto usable = width - SearchInset * 2;
    const auto titleWidth = width - 308;
    const auto muted = mutedInk(ink());
    const auto &value = entry.value;
    const auto title = value["title"].toString();

    rule(left, y + ResultRowHeight - 1, usable, 0.16);
    text(fit(value["id"].toString(), 10, 92, "regular"), left, y + 20, 10, "regular", 0, muted);
    searchTitle(title, query, left + SearchTitleX, y + 11, 18, titleWidth);

    auto kind = value["kind"].toString().toUpper();
    if (kind.isEmpty()) {
        kind = QStringLiteral("SONG");
    }
    auto detail = value["artist"].toString();
    if (detail.isEmpty()) {
        detail = value["album"].toString();
    }
    if (value.contains("playCount")) {
        detail += " / " + QString::number(value["playCount"].toDouble(), 'f', 0) + QStringLiteral(" 次播放");
    }
    const auto detailY = y + std::max(40., 11. + 18. * textScale() + 4.);
    const auto tagWidth = m_glyphs->width(kind, 8, "regular") + 10;
    fill(left + SearchTitleX, detailY, tagWidth, 14, searchTagFill(dark));
    text(kind, left + SearchTitleX + 5, detailY + 1, 8, "regular", 0.06, muted);
    text(fit(detail, 10, titleWidth - tagWidth - 8, "regular"),
         left + SearchTitleX + tagWidth + 8, detailY, 10, "regular", 0, muted);
    text("查看 ↗", x + width - SearchActionWidth, y + 20, 11, "regular", 0, muted);

    const auto action =
        value["kind"].toString() == "group"
            ? "music:expand:" + QString::fromUtf8(QUrl::toPercentEncoding(value["key"].toString()))
            : "music:result:" + QString::number(lane) + ":" + QString::number(entry.index);
    hit(left, y, usable, ResultRowHeight, action, title);
}

/** 标题按完整字宽截断后，再给匹配关键词画下划线。 */
void NativeHud::searchTitle(const QString &title, const QString &query, double x, double y, double size,
                            double width) {
    const auto shown = fit(title, size, width, "demibold");
    text(shown, x, y, size, "demibold");
    if (query.isEmpty()) {
        return;
    }
    const auto index = shown.indexOf(query, 0, Qt::CaseInsensitive);
    if (index < 0) {
        return;
    }
    const auto prefixWidth = m_glyphs->width(shown.left(index), size, "demibold");
    const auto matchWidth = m_glyphs->width(shown.mid(index, query.size()), size, "demibold");
    if (matchWidth > 0) {
        fill(x + prefixWidth, y + size + 1, matchWidth, 2, accent());
    }
}

void NativeHud::searchFooter(double x, double y, double width) {
    const auto muted = mutedInk(ink());
    fill(x + SearchInset, y + SearchFooterY + 3, 5, 5, accent());
    text(fit(m_music->status, 10, width - 320, "regular"), x + SearchInset + 13, y + SearchFooterY, 10,
         "regular", 0, muted);

    const auto loaded = int(m_music->lists[0].size());
    if (loaded == 0 && !m_music->sourceLoading()) {
        return;
    }
    const auto total = std::max(m_music->totals[0], loaded);
    QString hint = QStringLiteral("全部已载入");
    if (m_music->sourceLoading()) {
        hint = QStringLiteral("正在加载…");
    } else if (m_music->hasMore[0]) {
        hint = QStringLiteral("SCROLL / 滚动加载");
    }
    const auto label =
        QStringLiteral("已载入 ") + QString::number(loaded) + " / " + QString::number(total) + " · " + hint;
    const auto labelWidth = m_glyphs->width(label, 9, "regular");
    text(label, x + width - SearchInset - labelWidth, y + SearchFooterY, 9, "regular", 0.04, muted);
}

double NativeHud::searchScrollMaximum() const {
    return HudScroll::maximum(searchRowCount * ResultRowHeight, ResultListBottom - ResultListTop);
}

void NativeHud::resetResultViews() {
    searchScroll = 0;
    searchRowCount = 0;
    m_searchAutoFillSize = -1;
    savedScroll = 0;
    savedRowCount = 0;
    m_savedAutoFillSize = -1;
}

void NativeHud::ensureSearchFilled() {
    if (modal != "search" || closing || query.trimmed() != m_music->keyword || m_music->sourceLoading() ||
        !m_music->hasMore[0]) {
        return;
    }
    const auto count = int(rows(0).size());
    if (count <= m_searchAutoFillSize) {
        return;
    }
    m_searchAutoFillSize = count;
    if (count * ResultRowHeight < ResultListBottom - ResultListTop) {
        m_music->loadMoreSource(0);
    }
}
