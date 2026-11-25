#include "PlayerBar.h"
#include <QJsonObject>
#include <algorithm>
#include <cmath>

namespace PlayerBar {
/** 共用播放键绘制，桌面和窄屏使用同一组变形顶点。中心和尺寸使用各自的 HUD 坐标。 */
void appendPlayButton(QJsonArray &commands, const State &state, QPointF center, double size,
                      const QJsonArray &ink, const QJsonArray &paper) {
    commands.append(QJsonArray{"save"});
    commands.append(QJsonArray{"translate", center.x(), center.y()});
    if (state.boxedPlayButton) {
        commands.append(QJsonArray{"fill", ink, -size / 2, -size / 2, size, size});
    }
    const auto &color = state.boxedPlayButton ? paper : ink;
    const double glyphScale = size / 46 * (state.loading || state.boxedPlayButton ? 1 : 1.25);
    commands.append(QJsonArray{"scale", glyphScale, glyphScale});
    const double morph = state.playMorph >= 0 ? std::clamp(state.playMorph, 0.0, 1.0)
                                              : (state.playing ? 1.0 : 0.0);
    if (state.loading) {
        for (const double x : {-11., -2., 7.}) {
            commands.append(QJsonArray{"fill", color, x, -2, 4, 4});
        }
    } else if (morph == 0) {
        commands.append(QJsonArray{"fill-path", "M -5 -10 L 9 0 L -5 10 Z", color});
    } else {
        // 沿 x = 2 切分三角，两块四边形分别向暂停竖杠插值。
        static constexpr QPointF play[2][4] = {{{-5, -10}, {2, -5}, {2, 5}, {-5, 10}},
                                                {{2, -5}, {9, 0}, {9, 0}, {2, 5}}};
        static constexpr QPointF pause[2][4] = {{{-6, -9}, {-3, -9}, {-3, 9}, {-6, 9}},
                                                 {{3, -9}, {6, -9}, {6, 9}, {3, 9}}};
        QString path;
        for (int part = 0; part < 2; ++part) {
            for (int corner = 0; corner < 4; ++corner) {
                const auto start = play[part][corner];
                const auto vertex = start + (pause[part][corner] - start) * morph;
                path += corner == 0 ? QStringLiteral("M ") : QStringLiteral(" L ");
                path += QString::number(vertex.x(), 'f', 2) + ' ' + QString::number(vertex.y(), 'f', 2);
            }
            path += QStringLiteral(" Z ");
        }
        commands.append(QJsonArray{"fill-path", path, color});
    }
    commands.append(QJsonArray{"restore"});
}

namespace {
QString clock(double milliseconds) {
    const auto seconds = int(std::max(0.0, milliseconds) / 1000);
    return QString::number(seconds / 60).rightJustified(2, '0') + ":" +
           QString::number(seconds % 60).rightJustified(2, '0');
}

// 绘制器只输出值命令和语义动作，输入分发仍由宿主负责。
class Painter {
  public:
    Painter(Glyphs &glyphs, bool dark) : glyphs(glyphs) {
        if (dark) {
            paper = {0.133, 0.161, 0.137, 1};
            ink = {0.929, 0.941, 0.875, 1};
            muted = {0.647, 0.678, 0.616, 1};
            line = {0.298, 0.329, 0.282, 1};
        }
    }
    Drawing drawing;
    Glyphs &glyphs;
    QJsonArray paper{0.933, 0.937, 0.894, 1};
    QJsonArray ink{0.141, 0.161, 0.145, 1};
    QJsonArray muted{0.4, 0.439, 0.392, 1};
    QJsonArray line{0.8, 0.816, 0.761, 1};
    QJsonArray amber{0.863, 0.651, 0.227, 1};

    void fill(QRectF rect, QJsonArray color) {
        drawing.commands.append(QJsonArray{"fill", color, rect.x(), rect.y(), rect.width(), rect.height()});
    }
    void label(QString value, double x, double y, double size, double width, QString weight = "regular",
               bool secondary = false) {
        if (glyphs.width(value, size, weight) > width) {
            while (!value.isEmpty() && glyphs.width(value + "…", size, weight) > width) {
                value.chop(1);
            }
            value += "…";
        }
        drawing.commands.append(
            QJsonArray{"text", value, x, y, size * glyphs.textScale(), weight, 0, secondary ? muted : ink});
    }
    void hit(QRectF rect, QString action, QString label) {
        drawing.hits.append(QJsonObject{{"x", rect.x()},
                                        {"y", rect.y()},
                                        {"width", rect.width()},
                                        {"height", rect.height()},
                                        {"action", action},
                                        {"label", label},
                                        {"fixed", true}});
    }
    void path(QString value, QJsonArray color, bool filled = false) {
        if (filled) {
            drawing.commands.append(QJsonArray{"fill-path", value, color});
        } else {
            drawing.commands.append(QJsonArray{"path", value, 1.5, color, QJsonArray{}, 0});
        }
    }
    void centeredLabel(QString value, QPointF center, double size, QString weight = "regular") {
        const auto bounds = glyphs.bounds(value, size, weight);
        label(value, center.x() - bounds["x"].toDouble() - bounds["width"].toDouble() / 2,
              center.y() - bounds["y"].toDouble() - bounds["height"].toDouble() / 2, size, 100, weight);
    }
    void controls(const State &state, double x, double y) {
        drawing.commands.append(QJsonArray{"save"});
        drawing.commands.append(QJsonArray{"translate", x, y});
        path("M -57 -9 L -69 0 L -57 9 Z M -73 -10 L -73 10", ink);
        path("M 57 -9 L 69 0 L 57 9 Z M 73 -10 L 73 10", ink);
        drawing.commands.append(QJsonArray{"restore"});
        appendPlayButton(drawing.commands, state, {x, y}, 46, ink, paper);
        hit({x - 89, y - 24, 44, 48}, "player:prev", "上一首");
        hit({x - 23, y - 23, 46, 46}, "player:toggle", state.playing ? "暂停" : "播放");
        hit({x + 45, y - 24, 44, 48}, "player:next", "下一首");
    }
    void chrome(const State &state, QRectF bounds) {
        const auto x = bounds.x() + 28;
        const auto width = bounds.width() - 56;
        const auto brandWidth = 145 + 120 * (glyphs.textScale() - 1);
        label("RHINE LAB", x, bounds.y() + 6, 17, brandWidth, "bold");
        label("莱茵生命 / 音频终端", x + brandWidth, bounds.y() + 10, 11, width - brandWidth);
        fill({bounds.x(), bounds.y() + HeaderHeight - 1, bounds.width(), 1}, line);
        const auto bottom = bounds.y() + HeaderHeight + RowHeight;
        fill({bounds.x(), bottom, bounds.width(), 1}, line);
        label("AUDIO ARCHIVE / RL–004", x, bottom + 6, 11, width, "regular", true);
        auto status = state.status;
        if (status.isEmpty()) {
            status = state.playing ? "正在播放" : "播放已暂停";
        }
        label(status, bounds.right() - 228, bottom + 6, 11, 200, "regular", true);
    }
};

void song(Painter &paint, const State &state, double x, double y, double width) {
    if (!state.cover.isEmpty()) {
        paint.drawing.commands.append(QJsonArray{"image", state.cover, x, y + 21, 54, 54});
    } else {
        paint.drawing.commands.append(QJsonArray{"ellipse", paint.line, x, y + 21, 54, 54});
        paint.drawing.commands.append(QJsonArray{"ellipse", paint.paper, x + 2, y + 23, 50, 50});
        paint.drawing.commands.append(QJsonArray{"ellipse", paint.line, x + 10, y + 31, 34, 34});
        paint.drawing.commands.append(QJsonArray{"ellipse", paint.paper, x + 11, y + 32, 32, 32});
        paint.drawing.commands.append(QJsonArray{"ellipse", paint.ink, x + 23, y + 44, 8, 8});
        paint.drawing.commands.append(QJsonArray{"ellipse", paint.amber, x + 37, y + 27, 5, 5});
    }
    const auto infoX = x + 74;
    const auto infoWidth = width - 74;
    auto caption = QStringLiteral("NOW PLAYING / 当前音轨");
    if (state.failed) {
        caption = state.status.isEmpty() ? QStringLiteral("音频连接中断") : state.status;
    } else if (state.loading) {
        caption = "BUFFERING / 正在缓冲";
    }
    const auto scale = paint.glyphs.textScale();
    const auto extra = scale - 1;
    paint.label(caption, infoX, y + 13 - 12 * extra, 11, infoWidth, "regular", true);
    const auto titleSize = std::min(23., 33. / scale);
    paint.label(state.title.isEmpty() ? "尚未播放" : state.title, infoX, y + 32 - 5 * extra, titleSize,
                infoWidth, "demibold");
    auto detail = state.artist;
    if (!state.album.isEmpty()) {
        detail += " / " + state.album;
    }
    if (detail.isEmpty()) {
        detail = "RHINE LAB / MUSIC DATABASE";
    }
    paint.label(detail, infoX, y + 65, 13, infoWidth, "regular", true);
    if (state.hasTrack) {
        paint.hit({x, y + 14, width, 74}, "player:lyrics", "当前歌曲歌词");
    }
}

// 进度命中区位于主界面与播放行的交界处，始终沿用整行宽度。
void timeline(Painter &paint, const State &state, QRectF row) {
    const auto position =
        state.durationMs > 0 ? std::clamp(state.positionMs / state.durationMs, 0.0, 1.0) : 0;
    paint.fill({row.x(), row.y(), row.width(), 3}, paint.line);
    paint.fill({row.x(), row.y(), row.width() * position, 3}, paint.amber);
    const auto markerX = std::clamp(row.x() + row.width() * position - 1.5, row.left(), row.right() - 3);
    paint.fill({markerX, row.y() - 4, 3, 11}, paint.ink);
    if (state.seekable && state.durationMs > 0) {
        paint.drawing.seek = QRectF(row.x(), row.y() - 6, row.width(), 18);
        paint.hit(*paint.drawing.seek, "player:seek-fraction:0", "播放进度");
    }
    const auto center = row.center().x();
    const auto clockWidth = 50 + 22 * (paint.glyphs.textScale() - 1);
    paint.label(clock(state.positionMs), center - 157, row.y() + 42, 11, clockWidth, "regular", true);
    paint.label(clock(state.durationMs), center + 110, row.y() + 42, 11, clockWidth, "regular", true);
}

// 附加操作与播放键共用行中心，图标采用相同的细线、直角和倒角语言。
void favorite(Painter &paint, const State &state, double x, double y) {
    paint.drawing.commands.append(QJsonArray{"save"});
    paint.drawing.commands.append(QJsonArray{"translate", x, y + 1});
    paint.path("M 0 11 L -12 -1 L -12 -8 L -7 -13 L -2 -13 L 0 -10 "
               "L 2 -13 L 7 -13 L 12 -8 L 12 -1 Z",
               state.likeKnown ? paint.ink : paint.muted, state.liked);
    paint.drawing.commands.append(QJsonArray{"restore"});
    if (state.canLike) {
        const auto label = state.liked ? QStringLiteral("取消喜欢当前歌曲")
                                       : QStringLiteral("喜欢当前歌曲");
        paint.hit({x - 24, y - 24, 48, 48}, "music:like-current", label);
    }
}

void playbackMode(Painter &paint, const State &state, double x, double y) {
    paint.drawing.commands.append(QJsonArray{"save"});
    paint.drawing.commands.append(QJsonArray{"translate", x, y});
    QString label;
    if (state.mode == "shuffle") {
        label = "随机播放";
        paint.path("M -12 -8 L -6 -8 L 6 8 L 12 8 M 8 4 L 12 8 L 8 12 "
                   "M -12 8 L -6 8 L 6 -8 L 12 -8 M 8 -12 L 12 -8 L 8 -4",
                   paint.ink);
    } else if (state.mode == "all" || state.mode == "one") {
        label = state.mode == "one" ? "单曲循环" : "列表循环";
        paint.path("M -11 3 L -11 -6 L -7 -9 L 11 -9 M 7 -13 L 11 -9 L 7 -5 "
                   "M 11 -3 L 11 6 L 7 9 L -11 9 M -7 5 L -11 9 L -7 13",
                   paint.ink);
        if (state.mode == "one") {
            paint.centeredLabel("1", {0, 0}, 12, "demibold");
        }
    } else {
        label = "顺序播放";
        paint.path("M -12 -8 L -3 -8 M -12 0 L -3 0 M -12 8 L -3 8 "
                   "M 2 0 L 12 0 M 7 -5 L 12 0 L 7 5",
                   paint.ink);
    }
    paint.drawing.commands.append(QJsonArray{"restore"});
    paint.hit({x - 24, y - 24, 48, 48}, "player:mode", label + "，点击切换播放模式");
}

void lyrics(Painter &paint, const State &state, double x, double y) {
    paint.centeredLabel("词", {x, y}, 19, "regular");
    if (state.hasTrack) {
        paint.hit({x - 24, y - 24, 48, 48}, "player:lyrics", "当前歌曲歌词");
    }
}

void output(Painter &paint, const State &state, double x, double y, double right) {
    paint.fill({x - 22, y + 23, 1, 50}, paint.line);
    paint.label("OUTPUT / 输出", x, y + 29, 11, 180, "regular", true);
    const auto scale = paint.glyphs.textScale();
    const double volumeLabelWidth = state.applicationVolume && scale > 1 ? 54 : 78;
    paint.label(state.applicationVolume ? "音量" : "系统音量", x, y + 53, 14, volumeLabelWidth);
    if (state.applicationVolume) {
        const auto volumeX = x + 58;
        paint.drawing.volume = QRectF(volumeX, y + 47, 100, 28);
        paint.fill({volumeX, y + 60, 100, 3}, paint.line);
        paint.fill({volumeX, y + 60, 100 * std::clamp(state.volume, 0.0, 1.0), 3}, paint.ink);
        paint.hit(*paint.drawing.volume, "player:volume-fraction:0", "音量");
        const auto volume = int(std::lround(std::clamp(state.volume, 0.0, 1.0) * 100));
        paint.label(QString::number(volume) + "%", volumeX + 108, y + 53, 11, 42 + 30 * (scale - 1),
                    "regular", true);
    }
    const auto queueX = right - 65;
    paint.fill({queueX, y + 28, 19, 1.5}, paint.ink);
    paint.fill({queueX, y + 34, 19, 1.5}, paint.ink);
    paint.fill({queueX, y + 40, 13, 1.5}, paint.ink);
    paint.label("队列", queueX - 3, y + 57, 11, 50);
    paint.hit({queueX - 14, y + 16, 54, 65}, "player:open", "播放队列");
}
}

/** 将播放快照转换为独立绘制命令，装饰仅在浮窗模式组合，不访问或修改播放状态。 */
Drawing render(const State &state, const QRectF &bounds, bool dark, Glyphs &glyphs, Surface surface) {
    Painter paint(glyphs, dark);
    paint.fill(bounds, paint.paper);
    auto y = bounds.y();
    if (surface == Surface::Floating) {
        paint.chrome(state, bounds);
        y += HeaderHeight;
    }
    const auto center = bounds.center().x();
    const auto outputX = bounds.right() - 300;
    const auto favoriteX = bounds.x() + bounds.width() * 0.23;
    const auto songWidth = favoriteX - bounds.x() - 62;
    const QRectF row(bounds.x(), y, bounds.width(), RowHeight);
    paint.drawing.inputBounds = row.adjusted(0, -6, 0, 0);
    song(paint, state, bounds.x() + 28, y, songWidth);
    const auto centerY = y + RowHeight / 2;
    favorite(paint, state, favoriteX, centerY);
    paint.controls(state, center, centerY);
    lyrics(paint, state, bounds.right() - (state.musicVideo ? 490 : 470), centerY);
    if (state.musicVideo) {
        const auto mvX = bounds.right() - 435;
        paint.centeredLabel("MV", {mvX, centerY}, 15, "regular");
        paint.hit({mvX - 24, centerY - 24, 48, 48}, "player:mv", "打开 MV 播放窗口");
    }
    playbackMode(paint, state, bounds.right() - 380, centerY);
    timeline(paint, state, row);
    output(paint, state, outputX, y, bounds.right());
    return paint.drawing;
}
}
