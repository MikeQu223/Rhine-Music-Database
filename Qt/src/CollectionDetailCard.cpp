#include "CollectionDetailCard.h"
#include <algorithm>

namespace CollectionDetailCard {
namespace {
QJsonArray withAlpha(QJsonArray color, double alpha) {
    color[3] = alpha;
    return color;
}

class Painter {
  public:
    Painter(const Model &model, const Canvas &canvas)
        : model(model), canvas(canvas), sx(model.left + 22), sideWidth(model.sidebar - 44),
          right(model.x + model.width) {
        if (model.dark) {
            paper = {0.08, 0.095, 0.09, 1};
            panel = {0.095, 0.11, 0.10, 1};
            ink = {0.93, 0.94, 0.88, 1};
            muted = {0.65, 0.69, 0.62, 1};
            line = {0.30, 0.34, 0.29, 1};
            soft = {0.16, 0.20, 0.16, 1};
            inverse = {0.12, 0.15, 0.13, 1};
        }
    }

    void paint() {
        canvas.fill(model.bounds.x(), model.bounds.y(), model.bounds.width(), model.bounds.height(), paper);
        sheet();
        header();
        toolbar();
        table();
        sidebar();
        footer();
    }

  private:
    const Model &model;
    const Canvas &canvas;
    const double sx;
    const double sideWidth;
    const double right;
    QJsonArray paper{0.945, 0.941, 0.906, 1};
    QJsonArray panel{0.973, 0.969, 0.933, 1};
    QJsonArray ink{0.133, 0.165, 0.145, 1};
    QJsonArray muted{0.384, 0.42, 0.376, 1};
    QJsonArray line{0.80, 0.808, 0.753, 1};
    QJsonArray soft{0.898, 0.906, 0.855, 1};
    QJsonArray inverse{0.973, 0.969, 0.933, 1};
    const QJsonArray amber{0.835, 0.639, 0.282, 1};

    void label(const QString &value, double x, double y, double size, const QJsonArray &color,
               const QString &weight = "regular", double tracking = 0) {
        canvas.text(value, x, y, size, weight, tracking, color);
    }

    void fitted(const QString &value, double x, double y, double size, double width, const QJsonArray &color,
                const QString &weight = "regular") {
        label(canvas.fit(value, size, width, weight), x, y, size, color, weight);
    }

    void rightLabel(const QString &value, double edge, double y, double size, const QJsonArray &color,
                    const QString &weight = "regular", double tracking = 0) {
        const auto width = canvas.measure(value, size, weight);
        label(value, edge - width, y, size, color, weight, tracking);
    }

    void rule(double x, double y, double width, double opacity) {
        canvas.fill(x, y, width, 1, withAlpha(line, opacity));
    }

    void textButton(const Choice &choice, double x, double y, double width, double height, double size,
                    const QJsonArray &color) {
        if (choice.action.isEmpty()) {
            return;
        }
        canvas.hit(x, y, width, height, choice.action, choice.label);
        canvas.text(canvas.fit(choice.label, size, width, "regular"), x, y + (height - size) / 2 - 4, size,
                    "regular", 0, color);
    }

    void rightTextButton(const Choice &choice, double edge, double y, double size, const QJsonArray &color) {
        if (choice.action.isEmpty()) {
            return;
        }
        const auto width = canvas.measure(choice.label, size, "regular");
        canvas.hit(edge - width - 4, y - 6, width + 4, size + 12, choice.action, choice.label);
        label(choice.label, edge - width, y, size, color);
    }

    void outlinedButton(const Choice &choice, double x, double y, double width, double height, double size) {
        if (choice.action.isEmpty()) {
            return;
        }
        const auto border = withAlpha(line, 0.9);
        canvas.fill(x, y, width, 1, border);
        canvas.fill(x, y + height - 1, width, 1, border);
        canvas.fill(x, y, 1, height, border);
        canvas.fill(x + width - 1, y, 1, height, border);
        canvas.hit(x, y, width, height, choice.action, choice.label);
        canvas.text(canvas.fit(choice.label, size, width - 24, "regular"), x + 12,
                    y + (height - size) / 2 - 4, size, "regular", 0, ink);
    }

    void primaryButton(const Choice &choice, double x, double y, double width, double height) {
        if (choice.action.isEmpty()) {
            return;
        }
        canvas.fill(x, y, width, height, ink);
        canvas.hit(x, y, width, height, choice.action, choice.label);
        canvas.text(canvas.fit(choice.label, 16, width - 44, "demibold"), x + 22, y + 12, 16, "demibold", 0,
                    inverse);
    }

    void sheet() {
        canvas.fill(model.x - 18, model.bounds.y(), model.width + 18, model.bounds.height(), panel);
        // 顶线需要延伸到左边缘，与纵向分隔线在左上角接合成完整外框。
        canvas.fill(model.x - 18, model.bounds.y(), model.width + 18, 3, ink);
        canvas.fill(model.x - 18, model.bounds.y() + 3, 1, model.bounds.height() - 29, withAlpha(line, 0.85));
    }

    QString record() const {
        if (model.kind == "album") {
            return "ALBUM RECORD";
        }
        if (model.kind == "artist") {
            return "ARTIST RECORD";
        }
        return "PLAYLIST RECORD";
    }

    void header() {
        const auto kicker =
            (model.provider.isEmpty() ? QString("RHINE LAB") : model.provider) + " / " + record();
        const auto contentRight = right - 22;
        label(kicker, model.x, 268, 11, muted, "regular", 0.8);
        const auto title = canvas.fit(model.title, 32, contentRight - model.x - 190, "bold");
        canvas.text(title, model.x, 284, 32, "bold", -0.6, ink);
        rightLabel(QString::number(model.totalCount), contentRight, 270, 38, ink, "light", -1);
        rightLabel("TRACKS / 曲目", contentRight, 312, 11, muted, "regular", 0.6);
    }

    void toolbar() {
        primaryButton(model.playAll, model.x, 339, 180, 44);
        if (!model.sort.action.isEmpty()) {
            outlinedButton(model.sort, model.x + 195, 339, 180, 44, 16);
        }
        if (!model.search.action.isEmpty()) {
            searchField(model.x + 390, 339, 270, 44);
        }
        for (int index = 0; index < model.tabs.size(); ++index) {
            const auto &tab = model.tabs.at(index);
            const auto left = model.x + 210 + index * 125;
            canvas.hit(left, 345, 110, 32, tab.action, tab.label);
            label(canvas.fit(tab.label, 13, 110, "regular"), left, 355, 13, tab.selected ? ink : muted);
            if (tab.selected) {
                canvas.fill(left, 377, 42, 3, amber);
            }
        }
        rightLabel("TRACK INDEX / 曲目目录", right - 22, 354, 11, muted, "regular", 0.5);
    }

    void searchField(double x, double y, double width, double height) {
        const auto border = withAlpha(line, 0.9);
        canvas.fill(x, y, width, height, soft);
        canvas.fill(x, y, width, 1, border);
        canvas.fill(x, y + height - 1, width, 1, border);
        canvas.fill(x, y, 1, height, border);
        canvas.fill(x + width - 1, y, 1, height, border);
        canvas.hit(x, y, width - 40, height, model.search.action, model.search.label);
        if (!model.searchEditing) {
            canvas.text(canvas.fit(model.search.label, 14, width - 62, "regular"), x + 14, y + 12, 14,
                        "regular", 0, muted);
        }
        if (!model.clearSearch.action.isEmpty()) {
            canvas.hit(x + width - 40, y, 40, height, model.clearSearch.action, model.clearSearch.label);
            canvas.text("×", x + width - 28, y + 8, 22, "regular", 0, muted);
        }
    }

    void table() {
        const auto contentRight = right - 22;
        canvas.fill(model.x, 398, contentRight - model.x, 2, withAlpha(ink, 0.55));
        const auto titleX = model.x + 48;
        const auto artistX = model.x + model.width * 0.55;
        const auto timeEdge = contentRight - 60;
        label("封面", model.x, 414, 11, muted, "regular", 0.5);
        label("曲目 / TITLE", titleX, 414, 11, muted, "regular", 0.5);
        label("歌手 / ARTIST", artistX, 414, 11, muted, "regular", 0.5);
        rightLabel("时长", timeEdge, 414, 11, muted, "regular", 0.5);
        rule(model.x, 433, contentRight - model.x, 0.25);
        for (int index = 0; index < model.rows.size(); ++index) {
            const auto &row = model.rows.at(index);
            const auto yy = model.rowsY + index * model.rowHeight;
            if (row.current) {
                canvas.fill(model.x - 8, yy, contentRight - model.x + 16, model.rowHeight - 2, soft);
                canvas.fill(model.x - 8, yy, 3, model.rowHeight - 2, amber);
            }
            const QRectF artwork(model.x, yy + 8, 38, 38);
            canvas.fill(artwork.x(), artwork.y(), artwork.width(), artwork.height(), withAlpha(line, 0.16));
            if (!row.image.isEmpty()) {
                canvas.image(row.image, artwork.x(), artwork.y(), artwork.width(), artwork.height());
                const auto border = withAlpha(line, 0.7);
                canvas.fill(artwork.x(), artwork.y(), artwork.width(), 1, border);
                canvas.fill(artwork.x(), artwork.bottom() - 1, artwork.width(), 1, border);
                canvas.fill(artwork.x(), artwork.y(), 1, artwork.height(), border);
                canvas.fill(artwork.right() - 1, artwork.y(), 1, artwork.height(), border);
            } else {
                label(row.number, model.x + 13, yy + 18, 11, row.current ? ink : muted);
            }
            fitted(row.title, titleX, yy + 13, 18, artistX - titleX - 30, ink, "demibold");
            fitted(row.artist, artistX, yy + 17, 13, timeEdge - artistX - 30, muted);
            rightLabel(row.stamp, timeEdge, yy + 18, 12, muted);
            rightLabel("▷", contentRight, yy + 13, 18, row.current ? amber : muted);
            rule(model.x, yy + model.rowHeight - 1, contentRight - model.x, 0.15);
            canvas.hit(model.x - 8, yy, contentRight - model.x + 16, model.rowHeight - 2, row.action,
                       row.label);
        }
        if (model.rows.isEmpty() && !model.emptyMessage.isEmpty()) {
            canvas.text(canvas.fit(model.emptyMessage, 22, contentRight - model.x - 100, "demibold"), titleX,
                        500, 22, "demibold", 0, ink);
        }
        if (model.scrollFraction >= 0) {
            const auto height = model.rowCount * model.rowHeight - 2;
            const auto thumb = std::clamp(std::max(28.0, model.scrollThumb * height), 0.0, height);
            const auto travel = std::clamp(model.scrollFraction, 0.0, 1.0) * (height - thumb);
            canvas.fill(right - 8, model.rowsY, 2, height, withAlpha(line, 0.55));
            canvas.fill(right - 8, model.rowsY + travel, 2, thumb, muted);
        }
    }

    void sidebar() {
        label("03 / " + record(), sx, 322, 11, muted, "regular", 0.8);
        // 画框式封面：画布尺寸保持传入值，外侧留出统一卡纸与编号行。
        const auto artSize = std::min(model.coverSize, sideWidth - 16);
        const auto artX = sx + (sideWidth - artSize) / 2;
        constexpr double artTop = 352;
        const auto matTop = artTop - 8;
        const auto matHeight = artSize + 30;
        canvas.fill(artX - 8, matTop, artSize + 16, matHeight, soft);
        const auto frame = withAlpha(line, 0.9);
        canvas.fill(artX - 8, matTop, artSize + 16, 1, frame);
        canvas.fill(artX - 8, matTop + matHeight - 1, artSize + 16, 1, frame);
        canvas.fill(artX - 8, matTop, 1, matHeight, frame);
        canvas.fill(artX + artSize + 7, matTop, 1, matHeight, frame);
        canvas.image(model.coverKey, artX, artTop, artSize, artSize);
        fitted(model.archiveId, artX, artTop + artSize + 5, 10, artSize, muted);
        const auto titleY = matTop + matHeight + 18;
        canvas.text(canvas.fit(model.title, 22, sideWidth, "bold"), sx, titleY, 22, "bold", 0, ink);
        fitted(model.artist, sx, titleY + 36, 13, sideWidth, muted);
        double y = titleY + 68;
        for (const auto &fact : model.facts) {
            label(fact.label, sx, y, 11, muted, "regular", 0.5);
            canvas.text(canvas.fit(fact.value, 13, sideWidth, "regular"), sx, y + 19, 13, "regular", 0, ink);
            y += 40;
        }
        if (!model.quote.isEmpty()) {
            rule(sx, y + 14, sideWidth, 0.35);
            const auto lines = canvas.wrap(model.quote, sideWidth, 12, "regular");
            for (int index = 0; index < std::min(2, int(lines.size())); ++index) {
                label(lines.at(index), sx, y + 28 + index * 22, 12, muted);
            }
        }
        const bool edits = !model.rename.action.isEmpty() || !model.remove.action.isEmpty();
        if (edits) {
            rule(sx, 858, sideWidth, 0.3);
        }
        textButton(model.rename, sx, 866, sideWidth / 2 - 6, 30, 12, ink);
        textButton(model.remove, sx + sideWidth / 2, 866, sideWidth / 2, 30, 12, ink);
        if (!model.subscribe.action.isEmpty()) {
            rule(sx, 900, sideWidth, 0.3);
            canvas.hit(sx, 904, sideWidth, 40, model.subscribe.action, model.subscribe.label);
            canvas.text(canvas.fit(model.subscribe.label, 14, sideWidth, "regular"), sx, 914, 14, "regular",
                        0, model.subscribe.selected ? amber : ink);
        }
    }

    void footer() {
        const auto contentRight = right - 22;
        const auto moreVisible = !model.more.action.isEmpty();
        fitted(model.hint, model.x, 934, 12, contentRight - model.x - (moreVisible ? 360.0 : 220.0), muted);
        if (moreVisible) {
            outlinedButton(model.more, contentRight - 150, 922, 150, 32, 12);
        }
        rightTextButton(model.source, moreVisible ? contentRight - 170 : contentRight, 931, 11, ink);
    }
};
}

/** 只绘制详情卡内部；外框、滚动和动作路由仍由宿主控制器决定。 */
void paint(const Model &model, const Canvas &canvas) {
    Painter(model, canvas).paint();
}
}
