#include "DiscoverMusicCard.h"
#include <algorithm>

namespace DiscoverMusicCard {
Layout layout(const QRectF &bounds, int count) {
    Layout result;
    result.viewport = {bounds.x() + 53, bounds.y() + ViewportTop, bounds.width() - 106,
                       ViewportBottom - ViewportTop};
    result.tileSize = (result.viewport.width() - (ArchiveColumns - 1) * 18) / ArchiveColumns;
    result.rowStride = result.tileSize + 112;
    const auto rows = (std::max(0, count - 2) + ArchiveColumns - 1) / ArchiveColumns;
    const auto bottom = rows > 0 ? 526 + rows * result.rowStride - 18 : 468;
    result.maximumScroll = std::max(0., bottom - ViewportBottom);
    return result;
}

QRectF entryBounds(const QRectF &bounds, int index) {
    const auto geometry = layout(bounds, 0);
    const auto left = geometry.viewport.left();
    const auto width = geometry.viewport.width();
    const auto featuredWidth = (width - 18) * 0.66;
    if (index == 0) {
        return {left, bounds.y() + 230, featuredWidth, 238};
    }
    if (index == 1) {
        return {left + featuredWidth + 18, bounds.y() + 230, width - featuredWidth - 18, 238};
    }
    return {left + ((index - 2) % ArchiveColumns) * (geometry.tileSize + 18),
            bounds.y() + 526 + ((index - 2) / ArchiveColumns) * geometry.rowStride, geometry.tileSize,
            geometry.rowStride - 18};
}

// 绘制、点击和封面请求共用可见索引，避免滚动后误开相邻档案或下载整页封面。
QVector<int> visibleIndices(const QRectF &bounds, int count, double scroll) {
    const auto geometry = layout(bounds, count);
    QVector<int> indices;
    const auto offset = std::clamp(scroll, 0., geometry.maximumScroll);
    for (int index = 0; index < std::min(2, count); ++index) {
        if (entryBounds(bounds, index).translated(0, -offset).intersects(geometry.viewport)) {
            indices.append(index);
        }
    }
    const auto firstRow = std::max(0, int((ViewportTop + offset - 526) / geometry.rowStride));
    const auto lastRow = std::max(0, int((ViewportBottom + offset - 526) / geometry.rowStride));
    for (int index = 2 + firstRow * ArchiveColumns;
         index < std::min(count, 2 + (lastRow + 1) * ArchiveColumns); ++index) {
        if (entryBounds(bounds, index).translated(0, -offset).intersects(geometry.viewport)) {
            indices.append(index);
        }
    }
    return indices;
}
namespace {
class Painter {
  public:
    Painter(const Model &model, const Canvas &canvas)
        : model(model), canvas(canvas), x(model.bounds.x() + 53), y(model.bounds.y()),
          width(model.bounds.width() - 106) {
        if (model.dark) {
            paper = {0.09, 0.115, 0.095, 1};
            ink = {0.93, 0.94, 0.88, 1};
            muted = {0.65, 0.69, 0.62, 1};
            soft = {0.16, 0.20, 0.16, 1};
        }
    }

    void paint() {
        canvas.fill(model.bounds.x(), y, model.bounds.width(), model.bounds.height(), paper);
        canvas.fill(model.bounds.x(), y, model.bounds.width(), 3, ink);
        header();
        tabs();
        tools();
        if (model.categoryPicker) {
            categories();
        } else if (model.loadedCount == 0) {
            empty();
        } else {
            const auto viewport = layout(model.bounds, model.loadedCount).viewport;
            canvas.command({"save"});
            canvas.command({"clip", viewport.x(), viewport.y(), viewport.width(), viewport.height()});
            canvas.command({"translate", 0, -model.scroll});
            recommendations();
            canvas.command({"restore"});
            scrollIndicator();
        }
        footer();
    }

  private:
    const Model &model;
    const Canvas &canvas;
    double x;
    double y;
    double width;
    QJsonArray paper{0.973, 0.969, 0.933, 1};
    QJsonArray ink{0.133, 0.165, 0.145, 1};
    QJsonArray muted{0.39, 0.43, 0.38, 1};
    QJsonArray soft{0.89, 0.90, 0.85, 1};
    const QJsonArray amber{0.835, 0.639, 0.282, 1};
    const QJsonArray night{0.133, 0.165, 0.145, 1};
    const QJsonArray white{0.95, 0.95, 0.9, 1};

    void label(const QString &value, double left, double top, double size, double available,
               const QString &weight = "regular", QJsonArray color = {}) {
        canvas.text(canvas.fit(value, size, available, weight), left, y + top, size, weight,
                    color.isEmpty() ? ink : color);
    }

    void rule(double top, double opacity = 0.18) {
        auto color = ink;
        color[3] = opacity;
        canvas.fill(x, y + top, width, 1, color);
    }

    void button(const Choice &choice, double left, double top, double available, double height = 36) {
        auto border = ink;
        border[3] = 0.18;
        canvas.fill(left, y + top, available, 1, border);
        canvas.fill(left, y + top + height - 1, available, 1, border);
        canvas.fill(left, y + top, 1, height, border);
        canvas.fill(left + available - 1, y + top, 1, height, border);
        label(choice.label, left + 12, top + (height - 12) / 2 - 3, 12, available - 24);
        canvas.hit(left, y + top, available, height, choice.action, choice.label);
    }

    void header() {
        label("02 / MUSIC DIRECTORY", x, 25, 11, width - 180, "regular", muted);
        button({"← 返回", "close-modal"}, x + width - 140, 20, 140, 38);
        label("发现音乐", x, 65, 36, 180, "bold");
        label("Discover music", x + 190, 76, 22, width - 200, "light", muted);
        label("RHINE LAB / MUSIC DATABASE", x + width - 270, 97, 10, 270, "regular", muted);
    }

    void tabs() {
        const auto cell = width / std::max(1, int(model.tabs.size()));
        rule(126);
        rule(170);
        for (int index = 0; index < model.tabs.size(); ++index) {
            const auto &choice = model.tabs.at(index);
            const auto left = x + index * cell;
            const auto value = canvas.fit(choice.label, 12, cell - 8, "regular");
            const auto textWidth = canvas.measure(value, 12, "regular");
            label(value, left + (cell - textWidth) / 2, 141, 12, cell - 8, "regular",
                  choice.selected ? ink : muted);
            canvas.hit(left, y + 128, cell, 40, choice.action, choice.label);
            if (choice.selected) {
                const auto underline = std::min(48.0, cell - 8);
                canvas.fill(left + (cell - underline) / 2, y + 169, underline, 3, amber);
            }
        }
    }

    void tools() {
        if (model.tools.isEmpty()) {
            label("CURATED ARCHIVES / 精选音乐档案", x, 191, 10, width, "regular", muted);
            return;
        }
        const auto cell = std::min(190.0, width / model.tools.size());
        for (int index = 0; index < model.tools.size(); ++index) {
            const auto &choice = model.tools.at(index);
            button(choice, x + index * cell, 182, cell - 8, 32);
            if (choice.selected) {
                canvas.fill(x + index * cell, y + 213, cell - 8, 2, amber);
            }
        }
    }

    QString kind(const Entry &entry) const {
        if (entry.kind == "album") {
            return "ALBUM / 专辑";
        }
        if (entry.kind == "artist") {
            return "ARTIST / 歌手";
        }
        if (entry.kind == "song") {
            return "TRACK / 歌曲";
        }
        return "PLAYLIST / 歌单";
    }

    void title(const Entry &entry, double left, double top, double size, double available,
               QJsonArray color = {}, int maximum = 2) {
        const auto lines = canvas.wrap(entry.title, available, size, "demibold");
        for (int index = 0; index < std::min(maximum, int(lines.size())); ++index) {
            auto value = lines.at(index);
            if (index == maximum - 1 && lines.size() > maximum) {
                value += "…";
            }
            label(value, left, top + index * (size * model.textScale + 6), size, available, "demibold",
                  color);
        }
    }

    void artwork(const Entry &entry, double left, double top, double available, double height,
                 bool darkTile = false) {
        canvas.fill(left, y + top, available, height, darkTile ? night : soft);
        if (!entry.image.isEmpty()) {
            const auto aspect = std::max(0.1, entry.imageAspect);
            const auto imageWidth = std::min(available, height * aspect);
            const auto imageHeight = imageWidth / aspect;
            canvas.image(entry.image, left + (available - imageWidth) / 2,
                         y + top + (height - imageHeight) / 2, imageWidth, imageHeight);
        } else {
            // 没有封面时使用统一档案占位，不伪造专辑封面或推荐数量。
            label(kind(entry), left + 14, top + 13, 10, available - 28, "regular", darkTile ? white : muted);
            label(QString::number(entry.index + 1).rightJustified(2, '0'), left + 14, top + height - 65, 42,
                  available - 28, "light", darkTile ? amber : muted);
        }
    }

    void contentHit(const QRectF &rectangle, const QString &action, const QString &name) {
        const auto viewport = layout(model.bounds, model.loadedCount).viewport;
        const auto target = rectangle.translated(0, -model.scroll).intersected(viewport);
        if (!target.isEmpty()) {
            canvas.hit(target.x(), target.y(), target.width(), target.height(), action, name);
        }
    }

    void open(const Entry &entry) {
        contentHit(entryBounds(model.bounds, entry.index), "discover:item:" + QString::number(entry.index),
                   entry.title);
    }

    bool canPlayAll(const Entry &entry) const {
        return entry.kind == "playlist" || entry.kind == "album" || entry.kind == "artist";
    }

    void playAll(const Entry &entry, double left, double top, double available, bool darkSurface = false) {
        if (!canPlayAll(entry)) {
            return;
        }
        constexpr double height = 38;
        constexpr double textSize = 13;
        const auto background = darkSurface ? amber : ink;
        const auto foreground = darkSurface ? night : paper;
        canvas.fill(left, y + top, available, height, background);
        label("▶ 播放全部", left + 14, top + (height - textSize * model.textScale) / 2 - 3,
              textSize, available - 28,
              "demibold", foreground);
        contentHit({left, y + top - 3, available, 44}, "discover:play:" + QString::number(entry.index),
                   "播放全部 " + entry.title);
    }

    void framedArtwork(const Entry &entry, double left, double top, double size) {
        // 以装裱中心旋转，阴影与浅色卡纸一同倾斜；不改变原始封面的宽高比。
        canvas.command({"save"});
        canvas.command({"translate", left + size / 2, y + top + size / 2});
        canvas.command({"rotate", 0.0872664626});
        canvas.command({"translate", -left - size / 2, -y - top - size / 2});
        canvas.fill(left + 5, y + top + 8, size, size, {0.725, 0.749, 0.675, 1});
        canvas.fill(left, y + top, size, size, {0.969, 0.957, 0.898, 1});
        artwork(entry, left + 7, top + 7, size - 14, size - 14);
        canvas.command({"restore"});
    }

    void featured(const Entry &entry) {
        const auto rectangle = entryBounds(model.bounds, 0);
        const auto artSize = std::min(184.0, rectangle.width() * 0.4);
        const auto copyWidth = rectangle.width() - artSize - 80;
        const bool playable = canPlayAll(entry);
        canvas.fill(rectangle.x(), rectangle.y(), rectangle.width(), rectangle.height(), soft);
        label("01", rectangle.right() - 120, 361, 94, 120, "light",
              model.dark ? QJsonArray{0.24, 0.29, 0.23, 1} : QJsonArray{0.788, 0.812, 0.737, 1});
        label("FEATURED ARCHIVE / 精选推荐", x + 24, 250, 10, copyWidth, "regular", muted);
        title(entry, x + 24, 288 - 10 * (model.textScale - 1), 27, copyWidth);
        label(entry.artist.isEmpty() ? kind(entry) : entry.artist, x + 24, 382, 12, copyWidth, "regular",
              muted);
        label(entry.kind == "song" ? "▶ 播放歌曲" : "打开音乐档案 ↗", x + (playable ? 174 : 24),
              playable ? 427.5 : 425, playable ? 13 : 12, copyWidth - (playable ? 150 : 0));
        framedArtwork(entry, rectangle.right() - artSize - 28, 257, artSize);
        open(entry);
        if (playable) {
            playAll(entry, x + 24, 418, 132);
        }
    }

    void secondary(const Entry *entry) {
        const auto rectangle = entryBounds(model.bounds, 1);
        const auto sideX = rectangle.x();
        const auto sideWidth = rectangle.width();
        canvas.fill(sideX, rectangle.y(), sideWidth, rectangle.height(), night);
        label("NEXT DISCOVERY / 继续探索", sideX + 20, 250, 10, sideWidth - 40, "regular", white);
        const auto center = sideX + sideWidth - 70;
        const QJsonArray ring{0.40, 0.46, 0.37, 1};
        canvas.circle(center, y + 310, 37, ring);
        canvas.circle(center, y + 310, 36, night);
        canvas.circle(center, y + 310, 28, ring);
        canvas.circle(center, y + 310, 27, night);
        canvas.circle(center + 25, y + 283, 3, amber);
        if (entry) {
            const bool playable = canPlayAll(*entry);
            label("02", center - 18, 289, 30, sideWidth / 2, "light", amber);
            const double secondaryTitleSize = std::min(20., 23. / model.textScale);
            title(*entry, sideX + 20, 333 - 7 * (model.textScale - 1), secondaryTitleSize, sideWidth - 40,
                  white);
            label(entry->artist.isEmpty() ? kind(*entry) : entry->artist, sideX + 20, 382, 11, sideWidth - 40,
                  "regular", white);
            label(entry->kind == "song" ? "播放歌曲 ▶" : "打开档案 ↗", sideX + (playable ? 172 : 20),
                  playable ? 427.5 : 430, playable ? 13 : 11, sideWidth - (playable ? 192 : 40), "regular",
                  amber);
            open(*entry);
            if (playable) {
                playAll(*entry, sideX + 20, 418, 132, true);
            }
        } else {
            label("＋", center - 10, 292, 24, sideWidth / 2, "light", amber);
            label("每日推荐", sideX + 20, 365, 23, sideWidth - 40, "demibold", white);
            label("进入推荐 ↗", sideX + 20, 426, 12, sideWidth - 40, "regular", white);
            contentHit(rectangle, "discover:tab:daily", "每日推荐");
        }
    }

    void recommendations() {
        if (model.loadedCount > 2) {
            label("音乐档案", x, 490, 17, 150, "demibold");
            const auto englishX = 95 + 58 * (model.textScale - 1);
            label("SELECTED PROGRAMS", x + englishX, 495, 10, width - englishX - 5, "regular", muted);
        }
        for (const auto &entry : model.entries) {
            if (entry.index == 0) {
                featured(entry);
            } else if (entry.index == 1) {
                secondary(&entry);
            } else {
                tile(entry);
            }
        }
        if (model.loadedCount == 1) {
            secondary(nullptr);
        }
    }

    void tile(const Entry &entry) {
        const auto rectangle = entryBounds(model.bounds, entry.index);
        const auto left = rectangle.x();
        const auto top = rectangle.y() - y;
        const auto size = rectangle.width();
        artwork(entry, left, top, size, size);
        label(kind(entry), left, top + size + 12, 9, size, "regular", muted);
        title(entry, left, top + size + 32, std::min(14., 18. / model.textScale), size);
        label(entry.artist.isEmpty() ? kind(entry) : entry.artist, left, top + size + 78, 10, size, "regular",
              muted);
        open(entry);
    }

    void scrollIndicator() {
        const auto geometry = layout(model.bounds, model.loadedCount);
        if (geometry.maximumScroll <= 0) {
            return;
        }
        const auto height = geometry.viewport.height();
        const auto thumb = std::max(28., height * height / (height + geometry.maximumScroll));
        const auto top = geometry.viewport.top() + (height - thumb) * model.scroll / geometry.maximumScroll;
        auto track = muted;
        track[3] = 0.16;
        canvas.fill(x + width + 16, geometry.viewport.top(), 2, height, track);
        canvas.fill(x + width + 16, top, 2, thumb, muted);
    }

    void categories() {
        label("选择歌单分类", x, 237, 20, width, "demibold");
        constexpr int columns = 5;
        const auto cell = (width - 32) / columns;
        for (int index = 0; index < model.categories.size(); ++index) {
            const auto left = x + (index % columns) * (cell + 8);
            const auto top = 285 + (index / columns) * 44;
            const auto &choice = model.categories.at(index);
            button(choice, left, top, cell, 36);
            if (choice.selected) {
                canvas.fill(left, y + top + 35, cell, 2, amber);
            }
        }
        if (model.categoriesLoading) {
            label("正在读取分类…", x, 360, 14, width, "regular", muted);
        } else if (model.categories.size() <= 1 && !model.categoryStatus.isEmpty()) {
            const bool failed = model.categoryStatus != "暂无分类";
            label(failed ? "分类读取失败" : "暂无分类", x, 360, 16, width, "demibold", failed ? amber : ink);
            if (failed) {
                label(model.categoryStatus, x, 388, 12, width, "regular", muted);
                button({"重新读取", "discover:categories-retry"}, x, 420, 140, 36);
            }
        } else if (model.categories.size() <= 1) {
            label(model.status, x, 360, 14, width, "regular", muted);
        }
    }

    void empty() {
        rule(230);
        label(model.loading ? "LOADING ARCHIVES" : "MUSIC ARCHIVE", x, 336, 12, width, "regular", muted);
        label(model.loading ? "正在读取音乐…" : (model.status.isEmpty() ? "暂无内容" : model.status), x, 377,
              25, width, "demibold");
        label("切换上方分类，继续探索音乐资料库。", x, 428, 13, width, "regular", muted);
    }

    void footer() {
        rule(756);
        QString status = model.status;
        if (model.categoryPicker) {
            status = QString::number(model.categoryPage + 1) + " / " + QString::number(model.categoryPages);
        } else if (!model.loading && model.loadedCount > 0) {
            status = "已载入 " + QString::number(model.loadedCount) + " 条 / 滚轮浏览";
        }
        label(status, x, 779, 11, width - 350, "regular", muted);
        if (model.categoryPicker) {
            button({"↑ 上一页", "discover:category-page:prev"}, x + width - 212, 770, 100, 34);
            button({"下一页 ↓", "discover:category-page:next"}, x + width - 100, 770, 100, 34);
        } else if (model.more) {
            button({model.loading ? "载入中…" : "加载更多 ↓", "discover:more"}, x + width - 120, 770, 120,
                   34);
        } else if (model.loadedCount > 0) {
            const auto maximum = layout(model.bounds, model.loadedCount).maximumScroll;
            const auto hint =
                model.scroll < maximum ? "SCROLL TO EXPLORE / 向下滚动" : "END OF ARCHIVE / 档案结束";
            label(hint, x + width - 205, 779, 10, 205, "regular", muted);
        }
    }
};
}

/** 只绘制原面板内部，不修改宿主的外框、动画、数据或交互状态。 */
void paint(const Model &model, const Canvas &canvas) {
    Painter(model, canvas).paint();
}
}
