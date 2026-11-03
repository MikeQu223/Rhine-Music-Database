#include "PlaybackQueueCard.h"
#include "MusicData.h"
#include <algorithm>

namespace PlaybackQueueCard {
int maximumOffset(int trackCount) {
    return std::max(0, trackCount - 1);
}

/** 绘制播放队列卡片 */
void paint(const Model &model, const Canvas &canvas) {
    const auto x = model.bounds.x() + 53;
    const auto y = model.bounds.y();
    const auto width = model.bounds.width() - 106;
    const QJsonArray ink = model.dark ? QJsonArray{0.93, 0.94, 0.88, 1} : QJsonArray{0.145, 0.176, 0.153, 1};
    const QJsonArray muted = model.dark ? QJsonArray{0.68, 0.71, 0.64, 1} : QJsonArray{0.41, 0.44, 0.39, 1};
    const QJsonArray line = model.dark ? QJsonArray{0.31, 0.35, 0.29, 1} : QJsonArray{0.79, 0.80, 0.74, 1};
    const QJsonArray selected =
        model.dark ? QJsonArray{0.24, 0.28, 0.22, 1} : QJsonArray{0.90, 0.90, 0.83, 1};
    const QJsonArray amber{0.83, 0.64, 0.27, 1};
    const auto label = [&](QString value, double left, double top, double size, double limit,
                           bool secondary = false, QString weight = "regular") {
        canvas.text(canvas.fit(value, size, limit, weight), left, top, size, weight, secondary ? muted : ink);
    };
    const auto action = [&](const QRectF &rect, QString title, QString id, bool active = false) {
        if (active) {
            canvas.fill(rect.x(), rect.y(), rect.width(), rect.height(), ink);
        }
        canvas.text(canvas.fit(title, 14, rect.width() - 24, "regular"), rect.x() + 12, rect.y() + 12, 14,
                    "regular", active ? selected : ink);
        canvas.hit(rect.x(), rect.y(), rect.width(), rect.height(), id, title);
    };

    label("RHINE LAB / MUSIC DATABASE / AUDIO TERMINAL", x, y + 37, 11, width - 220, true);
    action({x + width - 167, y + 18, 167, 54}, "← 返回", "close-modal");
    label("Now Playing", x, y + 91, 38, width * 0.5, false, "demibold");
    label("播放队列 / SESSION TRACKS", x, y + 147, 13, width * 0.5, true);

    // 当前音轨缩为标题右侧摘要，不占用队列横向空间。
    const auto summaryX = x + width * 0.58;
    const auto summaryWidth = width * 0.42;
    const auto hasCover = !model.cover.isEmpty();
    if (hasCover) {
        canvas.image(model.cover, summaryX, y + 100, 58, 58);
    }
    const auto copyX = summaryX + (hasCover ? 72 : 0);
    const auto copyWidth = summaryWidth - (hasCover ? 72 : 0);
    label(model.current.isEmpty() ? "等待音轨 / STANDBY"
                                  : (model.playing ? "正在播放 / ON AIR" : "已暂停 / PAUSED"),
          copyX, y + 98, 10, copyWidth, true);
    label(model.current.value("title").toString("暂无播放歌曲"), copyX, y + 116, 18, copyWidth, false,
          "demibold");
    label(model.current.value("artist").toString(), copyX, y + 143, 11, copyWidth, true);

    label("播放队列  " + QString::number(model.tracks.size()), x, y + 194, 20, width - 160, false,
          "demibold");
    if (!model.tracks.isEmpty()) {
        action({x + width - 130, y + 185, 130, 40}, "清空队列", "player:clear");
    }
    canvas.fill(x, y + 233, width, 2, ink);
    label("PLAYBACK MODE / 播放模式", x, y + 247, 10, width, true);
    const QStringList modes{"off", "all", "one", "shuffle"};
    const QStringList names{"顺序播放", "列表循环", "单曲循环", "随机播放"};
    const auto modeWidth = (width - 24) / 4;
    for (int index = 0; index < modes.size(); ++index) {
        action({x + index * (modeWidth + 8), y + 269, modeWidth, 40}, names[index],
               "player:mode:" + modes[index], model.mode == modes[index]);
    }
    canvas.fill(x, y + 322, width, 1, line);
    label("#", x + 10, y + 334, 10, 28, true);
    label("曲目 / TRACK", x + 44, y + 334, 10, width - 160, true);
    label("时长", x + width - 100, y + 334, 10, 55, true);

    const auto offset = std::clamp(model.offset, 0, maximumOffset(int(model.tracks.size())));
    for (int row = 0; row < VisibleRows && offset + row < model.tracks.size(); ++row) {
        const auto index = offset + row;
        const auto song = model.tracks.at(index).toObject();
        const auto top = y + 358 + row * 56;
        const bool current = index == model.currentIndex;
        if (current) {
            canvas.fill(x, top, width, 56, selected);
            canvas.fill(x, top, 3, 56, amber);
        }
        label(current ? "●" : MusicData::pad(index + 1), x + 10, top + 18, 12, 28, !current);
        label(song.value("title").toString(), x + 44, top + 7, 17, width - 175, false,
              current ? "demibold" : "regular");
        label(song.value("artist").toString(), x + 44, top + 32, 11, width - 175, true);
        label(MusicData::time(song), x + width - 100, top + 18, 12, 55, true);
        // 曲目与移除按钮使用独立命中区域，避免点击移除时触发播放。
        canvas.hit(x + 5, top, width - 50, 55, "player:queue:" + QString::number(index),
                   "播放 " + song.value("title").toString());
        if (!current) {
            action({x + width - 38, top + 6, 38, 42}, "×", "player:remove:" + QString::number(index));
        }
        canvas.fill(x, top + 55, width, 1, line);
    }
    if (model.tracks.isEmpty()) {
        label("播放队列为空", x + 30, y + 476, 24, width - 60, false, "demibold");
        label("从音乐资料库添加歌曲，开启下一段音乐。", x + 30, y + 523, 15, width - 60, true);
    }
    label("清空仅移除待播歌曲，当前歌曲继续播放。", x, y + 768, 11, width * 0.65, true);
    label(QString::number(offset + (model.tracks.isEmpty() ? 0 : 1)) + "–" +
              QString::number(std::min(offset + VisibleRows, int(model.tracks.size()))) + " / " +
              QString::number(model.tracks.size()) + "  · 滚轮浏览",
          x + width * 0.68, y + 768, 11, width * 0.32, true);
    label(model.status, x, y + 800, 11, width, true);
}
}
