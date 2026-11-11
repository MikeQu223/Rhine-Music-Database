#include "SongDetailCard.h"

namespace SongDetailCard {
namespace {
const QJsonArray Amber{0.835, 0.639, 0.282, 1};

QJsonArray ink(bool dark) {
    return dark ? QJsonArray{0.92, 0.93, 0.88, 1} : QJsonArray{0.133, 0.165, 0.145, 1};
}

void rule(const Model &model, const Canvas &canvas, double y, double opacity) {
    auto color = ink(model.dark);
    color[3] = opacity;
    canvas.fill(model.x, y, model.width, 1, color);
}

void actions(const Model &model, const Canvas &canvas, const QVector<Action> &items, double y,
             bool primaryRow) {
    constexpr double gap = 12;
    constexpr double height = 44;
    const auto width = (model.width - gap * 2) / 3;
    const auto foreground = ink(model.dark);
    const auto inverse = model.dark ? QJsonArray{0.12, 0.15, 0.13, 1} : QJsonArray{0.973, 0.969, 0.933, 1};
    for (int index = 0; index < items.size(); ++index) {
        const auto &item = items.at(index);
        if (item.route.isEmpty()) {
            continue;
        }
        const auto x = model.x + index * (width + gap);
        const bool primary = primaryRow && index == 0;
        if (primary) {
            canvas.fill(x, y, width, height, foreground);
        } else {
            auto border = foreground;
            border[3] = 0.2;
            canvas.fill(x, y, width, 1, border);
            canvas.fill(x, y + height - 1, width, 1, border);
            canvas.fill(x, y, 1, height, border);
            canvas.fill(x + width - 1, y, 1, height, border);
        }
        canvas.hit(x, y, width, height, item.route, item.label);
        const auto color = primary ? inverse : foreground;
        // 文字也裁剪到按钮内，长平台名称不会覆盖相邻操作。
        canvas.text(item.label, x + 12, y + 12, 14, primary ? "demibold" : "regular", color);
    }
}
}

/** 在宿主原有内边距中绘制档案式卡片；坐标保持使用原舞台单位。 */
void paint(const Model &model, const Canvas &canvas) {
    const auto foreground = ink(model.dark);
    auto muted = foreground;
    muted[3] = 0.62;
    canvas.fill(model.x - 24, 260, model.width + 48, 3, foreground);
    canvas.fill(model.x, 280, 24, 18, foreground);
    const auto inverse = model.dark ? QJsonArray{0.12, 0.15, 0.13, 1} : QJsonArray{0.973, 0.969, 0.933, 1};
    canvas.text("01", model.x + 4, 282, 10, "regular", inverse);
    canvas.text("TRACK RECORD / 歌曲档案", model.x + 36, 282, 11, "regular", muted);
    canvas.limited("ID · " + model.id, model.x + model.width * 0.65, 282, 10, model.width * 0.35, "regular");
    rule(model, canvas, 314, 0.18);
    canvas.limited(model.album.isEmpty() ? "AUDIO ARCHIVE / 音频档案" : model.album, model.x, 332, 15,
                   model.width, "regular");
    // 两行标题空间固定，长歌名不会推动下方布局或改变外框尺寸。
    for (int index = 0; index < model.titleLines.size(); ++index) {
        canvas.limited(model.titleLines.at(index), model.x, 366 + index * 40, 32, model.width, "bold");
    }
    const double artistY = model.titleLines.size() > 1 ? 450 : 416;
    canvas.limited(model.artist, model.x, artistY, 18, model.width, "regular");
    actions(model, canvas, model.primaryActions, 476, true);
    actions(model, canvas, model.secondaryActions, 532, false);
    const bool albumTracks = model.tab == "history";
    if (!albumTracks) {
        rule(model, canvas, 586, 0.18);
        const auto column = (model.width - 12) / 2;
        const QVector<QPair<QString, QString>> fields{{"ALBUM / 所属专辑", model.album},
                                                      {"QUALITY / 音质", model.quality},
                                                      {"DURATION / 时长", model.duration},
                                                      {"PLAYBACK / 播放方式", model.playback}};
        for (int index = 0; index < fields.size(); ++index) {
            const auto x = model.x + (index % 2) * (column + 12);
            const auto y = 609 + (index / 2) * 57;
            canvas.text(fields.at(index).first, x, y, 10, "regular", muted);
            if (index == 1 && model.badgeWidth > 0) {
                canvas.image(model.badgeKey, x, y + 24, model.badgeWidth, 22);
            } else {
                const auto value = fields.at(index).second;
                canvas.limited(value.isEmpty() ? "暂无" : value, x, y + 22, 15, column - 12, "regular");
            }
            if (index == 1 && !model.local && !model.quality.isEmpty()) {
                canvas.hit(x, y + 18, column, 34, "quality:open", "音质说明与切换");
            }
        }
    }
    QStringList keys{"overview", "notes", "history"};
    QStringList labels{model.local ? "文件信息" : "歌曲百科", "专辑信息", "同专辑曲目"};
    if (albumTracks && model.trackCount > 0) {
        labels[2] += " · " + QString::number(model.trackCount) + " 首";
    }
    if (model.comments) {
        keys.append("comments");
        labels.append("评论");
    }
    // 两排按钮等高；同专辑标签留在曲目视口之前，避免与第二排命中区域重叠。
    const double tabsY = albumTracks ? 584 : 720;
    rule(model, canvas, tabsY + 42, 0.18);
    const auto tabWidth = model.width / keys.size();
    for (int index = 0; index < keys.size(); ++index) {
        const auto x = model.x + index * tabWidth;
        const auto width = tabWidth - 12;
        canvas.hit(x, tabsY, width, 38, "tab:" + keys.at(index), labels.at(index));
        canvas.limited(labels.at(index), x, tabsY + 10, 14, width, "regular");
        if (model.tab == keys.at(index)) {
            canvas.fill(x, tabsY + 41, 48, 3, Amber);
        }
    }
}
}
