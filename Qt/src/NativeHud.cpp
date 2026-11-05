#include "NativeHud.h"
#include "MusicData.h"
#include <QJsonDocument>
#include <QUrl>
#include "MusicDiscover.h"
#include "DiscoverArtwork.h"
#include <algorithm>
#include <cmath>

QJsonArray NativeHud::ink() const {
    if (dark) {
        return {0.92, 0.92, 0.92, 1, "calibratedWhite"};
    }
    return {0.08, 0.085, 0.075, 1, "calibratedRGB"};
}
void NativeHud::op(QJsonArray command) {
    if (!m_contentSink) {
        commands.append(command);
    }
}
void NativeHud::save() {
    op({"save"});
}
void NativeHud::restore() {
    op({"restore"});
}
void NativeHud::alpha(double value) {
    op({"alpha", value});
}
void NativeHud::translate(double x, double y) {
    op({"translate", x, y});
}
void NativeHud::scale(double x, double y) {
    op({"scale", x, y});
}
void NativeHud::clip(double x, double y, double width, double height) {
    op({"clip", x, y, width, height});
}
void NativeHud::fill(double x, double y, double width, double height, QJsonArray color) {
    op({"fill", color.isEmpty() ? ink() : color, x, y, width, height});
}
void NativeHud::text(QString value, double x, double y, double size, QString weight, double tracking,
                     QJsonArray color) {
    if (m_contentSink) {
        m_contentSink->text(value);
        return;
    }
    op({"text", value, x, y, size, weight, tracking, color.isEmpty() ? ink() : color});
}
void NativeHud::aligned(QString value, double x, double y, double size, QString weight, double tracking) {
    if (m_contentSink) {
        m_contentSink->text(value);
        return;
    }
    text(value, x - m_glyphs->inset(value, size, weight), y, size, weight, tracking);
}

QString NativeHud::fit(QString value, double size, double width, QString weight) {
    if (m_contentSink) {
        return value;
    }
    const auto key = QString::fromUtf8(
        QJsonDocument(QJsonArray{value, size, width, weight}).toJson(QJsonDocument::Compact));
    if (const auto cached = m_fitCache.object(key)) {
        return *cached;
    }
    auto length = value.size();
    if (m_glyphs->width(value, size, weight) > width) {
        qsizetype low = 1;
        auto high = length;
        while (low < high) {
            const auto middle = (low + high + 1) / 2;
            if (m_glyphs->width(value.left(middle), size, weight) <= width) {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        length = low;
    }
    auto result = value;
    if (length != value.size()) {
        result = value.left(std::max(qsizetype(0), length - 1)) + "…";
    }
    m_fitCache.insert(key, new QString(result));
    return result;
}
void NativeHud::limited(QString value, double x, double y, double size, double width, QString weight) {
    text(fit(value, size, width, weight), x, y, size, weight);
}
void NativeHud::centeredText(QString value, double x, double cy, double size, QString weight,
                             bool horizontal) {
    if (m_contentSink) {
        m_contentSink->text(value);
        return;
    }
    const auto bounds = m_glyphs->bounds(value, size, weight);
    text(value, x - bounds["x"].toDouble() - (horizontal ? bounds["width"].toDouble() / 2 : 0),
         cy - bounds["y"].toDouble() - bounds["height"].toDouble() / 2, size, weight);
}
void NativeHud::rollingText(QString key, QString value, double x, double y, double size, QString weight,
                            double tracking, bool numeric) {
    const auto result = m_rolling[key].render(
        value, x, y, size, weight, tracking, lastTime, !reduced && frame["mode"] == "archive", numeric, ink(),
        [this](const QString &text, double size, const QString &weight, double tracking) {
            return m_glyphs->width(text, size, weight, tracking);
        });
    for (const auto &command : result) {
        commands.append(command);
    }
}
void NativeHud::roll(QString key, QString value, double x, double y, double size, double width,
                     QString weight, bool numeric) {
    const auto shown = fit(value, size, width, weight);
    rollingText(key, shown, x - m_glyphs->inset(shown, size, weight), y, size, weight, 0, numeric);
}
void NativeHud::hit(double x, double y, double width, double height, QString action, QString label) {
    if (m_contentSink) {
        m_contentSink->action(label.isNull() ? action : label, action);
        return;
    }
    hits.append(QJsonObject{{"x", x},
                            {"y", y},
                            {"width", width},
                            {"height", height},
                            {"action", action},
                            {"label", label.isNull() ? action : label}});
}
void NativeHud::button(QString label, double x, double y, double width, double height, QString action,
                       double size, QString weight) {
    if (m_contentSink) {
        m_contentSink->action(label, action);
        return;
    }
    hit(x, y, width, height, action, label);
    const auto inset = m_modalControls ? std::min(10.0, width / 8) : 0;
    if (m_modalControls) {
        fill(x, y, width, height,
             dark ? QJsonArray{0.55, 0.59, 0.46, 0.13} : QJsonArray{0.44, 0.49, 0.36, 0.1});
    }
    text(m_modalControls ? fit(label, size, width - inset * 2) : label, x + inset,
         y + (height - size) / 2 - 4, size, weight);
}
void NativeHud::control(QString label, double x, double y, double width, QString action) {
    if (m_contentSink) {
        m_contentSink->action(label, action);
        return;
    }
    hit(x - 10, y, width + 20, 54, action, label);
    aligned(label, x, y + 14, 20, "demibold");
}
void NativeHud::rule(double x, double y, double width, double opacity) {
    auto color = ink();
    color[3] = opacity;
    fill(x, y, width, 1, color);
}
void NativeHud::image(QString key, double x, double y, double width, double height) {
    if (m_contentSink) {
        m_contentSink->image(key);
        return;
    }
    if (!key.isEmpty()) {
        op({"image", key, x, y, width, height});
    }
}
void NativeHud::art(QString key, double x, double y, double size, int count, double tracking,
                    QJsonArray color) {
    op({"art", key, x, y, size, count, tracking, color.isEmpty() ? ink() : color});
}

QRectF NativeHud::modalBounds(double width) const {
    if (modal == "detail-sort") {
        const auto layout = containerLayout(width);
        return {layout.x + 195, 391, 240, 184};
    }
    if (modal == "lyrics-source") {
        // 来源菜单
        return {width * 0.56 + 156, 674, 232, 232};
    }
    if (modal == "lyrics-offset") {
        // 偏移设置
        return {width * 0.56, 690, 320, 216};
    }
    double modalWidth = std::min(1260.0, width - 100);
    if (modal == "search") {
        modalWidth = std::min(width - 100, std::max(760.0, std::min(1000.0, width * 0.5 - 59)));
    }
    const auto left = modal == "search" ? width - modalWidth - 59 : (width - modalWidth) / 2;
    return {left, 122, modalWidth, 836};
}
NativeHud::Layout NativeHud::containerLayout(double width) const {
    Layout layout;
    layout.sidebar = std::clamp(width * 0.23 - 40, 250.0, 340.0);
    layout.x = layout.left + layout.sidebar + 36;
    layout.width = width - layout.x - 40;
    return layout;
}
QRectF NativeHud::detailBounds(double width) const {
    if (m_music->current.value("kind") == "song") {
        const auto left = width * 0.56 - 24;
        return {left, 260, width - left - 35, 696};
    }
    const auto layout = containerLayout(width);
    return {layout.left, layout.top, width - layout.left * 2, layout.bottom - layout.top};
}
QJsonObject NativeHud::state() const {
    return m_responsive.state(sourceState());
}

QJsonObject NativeHud::sourceState() const {
    const auto bounds = modalBounds(width);
    const auto rect = [](const std::optional<QRectF> &value) -> QJsonValue {
        if (!value) {
            return QJsonValue::Null;
        }
        return QJsonObject{
            {"x", value->x()}, {"y", value->y()}, {"width", value->width()}, {"height", value->height()}};
    };
    return {{"lyricsMode", lyricsMode},
            {"archiveName", m_music->libraryName()},
            {"archiveIndex", m_music->libraryIndex()},
            {"archiveTotal", m_music->libraryTotal()},
            {"inputX", bounds.x() + 53},
            {"inputY", bounds.y() + 180},
            {"inputWidth", bounds.width() - 106 - libraryToolbarActionWidth()},
            // QML 手势层与原生结果视口共用同一组舞台坐标。
            {"searchListX", bounds.x() + 53},
            {"searchListY", bounds.y() + ResultListTop},
            {"searchListWidth", bounds.width() - 106},
            {"searchListHeight", ResultListBottom - ResultListTop},
            {"playerBounds", rect(playerBounds)},
            {"seek", rect(playerSeekRect)},
            {"volume", rect(playerVolumeRect)},
            {"loginMethod", m_music->loginMethod},
            {"loginBusy", m_music->accountLoading},
            {"smsRetrySeconds", m_music->smsRetrySeconds()},
            {"localMusic", m_music->isLocal()},
            {"formKind", formKind},
            {"formPID", formPID},
            {"modal", modal},
            {"query", query},
            {"closing", closing},
            {"modalOpacity", motion.opacity},
            {"modalOffset", motion.offset},
            {"dark", dark},
            {"reduced", reduced},
            {"editingSetting", !editingSettingId.isEmpty()},
            {"editingSettingValue", editingSettingText},
            {"editingSettingX", editingSettingRect.x()},
            {"editingSettingY", editingSettingRect.y()},
            {"editingSettingWidth", editingSettingRect.width()},
            {"editingSettingHeight", editingSettingRect.height()},
            {"archiveMaskStrength", archiveMaskStrength},
            {"trackListMode", trackListMode},
            {"detailSort", detailSort},
            {"sortLoading", m_sortRequest.has_value()},
            {"mode", frame["mode"]},
            {"viewer", frame["viewer"]},
            {"status", m_music->status}};
}

/** 每帧清空绘制与命中数组，再按原顺序生成；文字动画由原生曲线维护。 */
void NativeHud::draw(QJsonObject next, double stageWidth, double time) {
    // 探针（RHINE_HUD_PROBE=1）：HUD 的舞台宽度必须等于"离屏层实际宽度 / (高度/1080)"，
    // 否则所有按 width 相对定位的内容（导航、列表、弹窗右列）都会被画到层外。
    // 只在宽度变化时输出一次，避免刷屏。
    if (qEnvironmentVariableIntValue("RHINE_HUD_PROBE") == 1) {
        static double lastProbeWidth = -1;
        if (stageWidth != lastProbeWidth) {
            lastProbeWidth = stageWidth;
            qWarning().noquote() << "HUD 探针: 舞台宽度" << stageWidth << "模式" << next["mode"].toString();
        }
    }
    if (themeMode == "system" && dark != m_host->systemDark()) {
        dark = m_host->systemDark();
        m_scene.theme(dark);
    }
    m_responsive.resize(stageWidth);
    m_music->followPlaybackDetails = !m_responsive.compact();
    const double actualStageWidth = stageWidth;
    stageWidth = m_responsive.sourceWidth(stageWidth);
    frame = next;
    width = stageWidth;
    lastTime = time;
    m_responsive.setMotion(time, reduced);
    commands = {};
    hits = {};
    playerBounds.reset();
    playerSeekRect.reset();
    playerVolumeRect.reset();
    if (!trackListMode || frame["mode"] != "archive" || frame["viewer"].toBool() ||
        m_music->current.value("kind") != "song") {
        m_trackListCurve.reset();
        m_trackListScope.clear();
    }
    motion.sample(time);
    if (closing && motion.finished()) {
        modal.clear();
        closing = false;
    }
    if (m_responsive.compact() && frame["mode"] != "boot") {
        const auto scope = modal + ":" + frame["mode"].toString() + ":" +
                           m_music->current.value("kind").toString() + ":" +
                           m_music->current.value("id").toString() + ":" + tab + ":" +
                           (lyricsMode ? "lyrics" : "info") + ":" + m_music->discover->tab + ":" +
                           QString::number(musicCollection) + ":" + artistTab + ":" + query;
        const bool home = modal.isEmpty() && frame["mode"] == "archive" && !lyricsMode;
        m_responsive.prepare(scope, home);
        if (!frame["viewer"].toBool()) {
            if (modal == "player") {
                playerPanel(0, 0, width);
            } else if (modal == "discover") {
                discoverPanel(0, 0, width);
            } else if (modal == "settings") {
                settingsPanel(0, 0, width);
            } else if (!modal.isEmpty() && modal != "search" && modal != "saved") {
                m_responsive.setAuxiliary(auxiliaryContent());
            } else if (modal.isEmpty() && frame["mode"] == "detail" && !lyricsMode &&
                       !m_music->current.isEmpty()) {
                detail(width, frame["detail"].toDouble());
            }
        }
        playerBar(0, 984, width);
        drawMobile(time, scope);
        return;
    }
    if (frame["viewer"].toBool()) {
        viewer(width);
    } else if (frame["mode"] == "boot") {
        if (m_responsive.compact()) {
            // 启动 HUD 沿用原动画，只将 1920 × 1080 画布完整缩放到实际窄舞台中央。
            const double scale = actualStageWidth / 1920.;
            save();
            translate(0, (1080 - 1080 * scale) / 2);
            this->scale(scale, scale);
            boot(1920);
            restore();
        } else {
            boot(width);
        }
    } else {
        if (frame["mode"] == "archive" && !(lyricsMode && !m_music->player.current.isEmpty())) {
            archiveMask(width);
        }
        brand();
        navigation(width);
        footer(width);
        if (modal != "search") {
            if (frame["mode"] == "detail" || (lyricsMode && !m_music->player.current.isEmpty())) {
                detail(width, lyricsMode ? 1 : frame["detail"].toDouble());
            } else {
                archive(width);
            }
        }
    }
    if (!modal.isEmpty()) {
        if (m_responsive.compact()) {
            commands = {};
            hits = {};
        }
        modalDraw(width);
    }
    if (frame["mode"] != "boot") {
        playerBar(0, 984, width);
    }
    if (frame["mode"] == "boot") {
        return;
    }
}
/** 移动端只消费展示模型，不先生成再丢弃横屏 HUD。 */
void NativeHud::drawMobile(double time, const QString &scope) {
    auto mobile = sourceState();
    mobile["lyricsMode"] = lyricsMode;
    mobile["selectedSongIsCurrent"] =
        PlaybackQueue::identity(m_music->current) == PlaybackQueue::identity(m_music->player.current);
    const auto selectedLiked = m_music->songLiked(m_music->current);
    mobile["selectedSongLiked"] = selectedLiked ? QJsonValue(*selectedLiked) : QJsonValue(QJsonValue::Null);
    mobile["lyricDocument"] = m_music->player.lyrics.document();
    mobile["lyricIndex"] = m_music->player.lyrics.index;
    mobile["lyricMessage"] = m_music->player.lyrics.message;
    mobile["playerQuality"] = m_music->player.actualQuality;
    mobile["playerQueueCount"] = m_music->player.queue.size();
    mobile["providerName"] = m_music->providerName();
    mobile["loggedIn"] = !m_music->uid.isEmpty();
    mobile["userName"] = m_music->nickname;
    mobile["editingSettingId"] = editingSettingId;
    mobile["musicCollection"] = musicCollection;
    mobile["searchKind"] = m_music->searchKind;
    mobile["collectionLabels"] = QJsonArray::fromStringList(m_music->columns);
    mobile["collectionTitle"] = m_music->columns.value(musicCollection);
    mobile["provider"] = m_music->provider;
    mobile["canCreatePlaylist"] = m_music->editable();
    mobile["officialPlayback"] = PlatformFeatures::OfficialPlayback;
    mobile["detailBody"] = body();
    // 目录中的物理唱片会跨列排列，栏目始终使用最外层目录的来源。
    int sourceLane = m_music->selectedLane;
    for (auto directory = m_music->directory; directory; directory = directory->parent) {
        sourceLane = directory->parentLane;
    }
    const int columnIndex = m_music->sourceOrder().indexOf(sourceLane) + 1;
    QJsonArray archiveSources;
    for (const int lane : m_music->sourceOrder()) {
        archiveSources.append(QJsonObject{
            {"lane", lane}, {"label", m_music->columns.value(lane)}, {"selected", lane == sourceLane}});
    }
    mobile["archiveSources"] = archiveSources;
    const auto archiveItems =
        modal.isEmpty() && frame["mode"] == "archive" && !lyricsMode ? m_music->libraryItems() : QJsonArray{};
    mobile["archiveRows"] = archiveItems;
    mobile["canPlayArchive"] = !archiveItems.isEmpty() && archiveItems.first().toObject()["kind"] == "song";
    mobile["archiveColumnIndex"] = columnIndex;
    if (modal == "search" || modal == "saved") {
        QJsonArray entries;
        const int lane = modal == "search" ? 0 : musicCollection;
        const auto values = rows(lane);
        const bool gallery =
            modal == "saved" && lane >= 2 && !values.isEmpty() && values.first().value["kind"] != "song";
        const auto [first, last] = m_responsive.resultWindow(int(values.size()), modal == "search", gallery,
                                                             modal == "saved" && lane == 1);
        mobile["resultTotalCount"] = values.size();
        if (modal == "saved" && lane >= 2) {
            if (!m_savedArtwork) {
                m_savedArtwork = new DiscoverArtwork(m_host, this);
            }
            QStringList urls;
            for (int index = first; index < last; ++index) {
                urls.append(values[index].value["cover"].toString());
            }
            m_savedArtwork->show(m_music->provider + ":" + QString::number(m_music->accountGeneration()) +
                                     ":" + QString::number(lane),
                                 urls);
        }
        for (int index = first; index < last; ++index) {
            const auto &row = values[index];
            auto value = row.value;
            if (modal == "saved" && lane >= 2) {
                value["image"] = m_savedArtwork->image(value["cover"].toString());
            }
            const auto route =
                value["kind"] == "group"
                    ? "music:expand:" + QString::fromUtf8(QUrl::toPercentEncoding(value["key"].toString()))
                    : "music:result:" + QString::number(lane) + ":" + QString::number(row.index);
            entries.append(QJsonObject{{"index", index}, {"value", value}, {"action", route}});
        }
        mobile["resultRows"] = entries;
    }
    m_responsive.arrange(commands, hits, mobile, scope, *m_glyphs);
    QString pageKey = modal + ":" + frame["mode"].toString();
    if (lyricsMode && modal.isEmpty()) {
        pageKey = "lyrics";
    } else if (modal.isEmpty() && frame["mode"] == "detail") {
        pageKey += ":" + m_music->current["key"].toString();
    }
    if (!lyricsMode && modal.isEmpty() && frame["mode"] == "archive") {
        pageKey += ":" + QString::number(mobile["archiveColumnIndex"].toInt()) + ":" + m_music->libraryName();
    } else if (modal == "discover") {
        pageKey += ":" + m_music->discover->tab;
    } else if (modal == "search") {
        pageKey += ":" + m_music->searchKind;
    }
    m_mobileTransition.apply(commands, hits, pageKey, time, 1080, reduced, frame["detail"].toDouble());

    // 列表滚动把固定槽位上的歌曲交给原有选择流程；下一帧再绘制新的选中状态。
    if (const int selection = m_responsive.takeArchiveSelection(); selection >= 0) {
        m_music->selectLibraryIndex(selection);
    }
}

void NativeHud::archiveMask(double width) {
    if (archiveMaskStrength == 0) {
        return;
    }
    // 遮罩设置
    constexpr double FadeWidth = 300;
    const auto opacity = archiveMaskStrength / 100.;
    const auto color = dark ? QJsonArray{0.055, 0.075, 0.08, opacity} : QJsonArray{0.9, 0.89, 0.86, opacity};
    const auto fadeEnd = navigationLeft(width);
    const auto fadeStart = fadeEnd - FadeWidth;
    save();
    clip(0, 0, width, 984);
    op({"right-mask", color, fadeStart, fadeEnd - fadeStart, width, 984});
    restore();
}
void NativeHud::brand() {
    roll("music-brand", m_music->libraryName(), 59, 115.425, 44, std::min(720.0, width * 0.45), "bold");
    aligned("RHINE LAB / MUSIC DATABASE", 59, 173, 14, "demibold", 1);
}
void NativeHud::brandLine(int index) {
    if (index == 0) {
        text("RHINE LAB", 59, 115.425, 50.75, "bold", 1);
    } else if (index == 1) {
        text("MUSIC DATABASE", 59, 169, 22, "demibold", 1.7);
    } else {
        rule(59, 212, 300, 0.65);
        text("INDEX / COLLECTION / TRACK", 59, 228, 11, "regular", 1.2);
    }
}
double NativeHud::navigationLeft(double width) {
    return width - 789;
}
void NativeHud::navigation(double width) {
    const auto x = navigationLeft(width) + 210;
    if (m_music->isLocal()) {
        control("文件夹管理 ＋", x - 210, 118, 184, "discover");
    } else if (!m_music->isSiren()) {
        control("发现音乐 ↗", x - 210, 118, 184, "discover");
    }
    control("音乐检索  /", x, 118, 184, "search");
    control(m_music->isLocal() ? "本地曲库" : (m_music->isSiren() ? "＋ 塞壬曲库" : "＋ 我的音乐"), x + 200,
            118, 184, "saved");
    control(m_host->updater.available() ? "设置 · 更新" : "设置", x + 400, 118, 120, "settings");
}
void NativeHud::footer(double width) {
    fill(59, 971, 5, 5, {119.0 / 255, 123.0 / 255, 96.0 / 255, 1});
    QString session = m_music->isLocal() ? "LOCAL LIBRARY" : "GUEST SESSION";
    if (m_music->isSiren()) {
        session = "SIREN RECORDS";
    } else if (!m_music->uid.isEmpty()) {
        session = "NETEASE SESSION";
        if (m_music->provider == "qq") {
            session = "QQ SESSION";
        } else if (m_music->provider == "kugou") {
            session = "KUGOU SESSION";
        }
    }
    text(session, 75, 967, 10, "regular", 0.9);
    const auto credit = QStringLiteral("POWERED BY RHINE LAB");
    text(credit, width - 59 - m_glyphs->width(credit, 10, "demibold"), 967, 10, "demibold");
}
void NativeHud::empty(double width) {
    const auto x = navigationLeft(width);
    auto &music = *m_music;
    if (music.directory) {
        control("← 返回上一级", 59, 211, 280, "music:parent");
    }
    text("MUSIC DATABASE / " + music.libraryName(), x, 471, 12);
    QString title = "音乐资料库";
    QString label = "检索音乐 →";
    QString action = "search";
    if (music.directory) {
        title = music.libraryName();
        label = "查看歌单详情 →";
        action = "music:directory-info";
    } else if (music.selectedLane > 0) {
        title = music.sourceLoading() ? QStringLiteral("正在同步音乐资料…") : music.libraryName();
        label = music.isSiren() ? QStringLiteral("查看曲库 →") : QStringLiteral("查看我的音乐 →");
        action = "saved";
        if (!music.isLocal() && !music.isSiren() && music.uid.isEmpty() && !music.restoringAccount) {
            title = "登录后查看";
            label = "登录" + music.providerName() + " →";
            action = "music:login";
        }
    }
    limited(title, x, 509, 28, width - x - 59, "bold");
    rule(x, 601, width - x - 59);
    limited(music.directory ? music.status : music.sourceMessage(music.selectedLane), x, 624, 16,
            width - x - 117);
    button(label, x, 703, 300, 32, action, 14);
}
void NativeHud::archive(double width) {
    auto &music = *m_music;
    const auto item = music.current;
    if (!item.isEmpty() && !item["id"].toString().isEmpty()) {
        const auto x = navigationLeft(width);
        if (music.directory) {
            control("← 返回上一级", 59, 211, 280, "music:parent");
            const auto kind = music.directory->item["kind"].toString();
            QString label = "查看歌单详情 ↗";
            if (kind == "album") {
                label = "查看专辑详情 ↗";
            } else if (kind == "artist") {
                label = "查看歌手详情 ↗";
            }
            control(label, 59, 265, 310, "music:directory-info");
        }
        if ((music.directory &&
             QStringList{"playlist", "album", "folder"}.contains(music.directory->item["kind"].toString())) ||
            (!music.directory && music.selectedLane == 1)) {
            control("播放全部 →", 59, music.directory ? 319 : 211, 310, "music:play-loaded");
        } else if (!music.directory && music.isSiren() && music.selectedLane == 3) {
            control("播放全部 →", 59, 211, 310, "music:play-loaded");
            control("在资料库中打开 →", 59, 265, 310, "music:open-all-siren");
        }
        const bool showTrackList = trackListMode && item["kind"] == "song";
        if (!showTrackList) {
            roll("music-source", "MUSIC DATABASE / " + music.libraryName(), x, 471, 12, width - x - 59);
        }
        if (showTrackList) {
            archiveTrackList(x, width);
        } else {
            roll("music-title", item["title"].toString(), x, 509, 28, width - x - 59, "bold");
            hit(x, 509, 414, 37, "open", item["title"].toString());
            rule(x, 601, width - x - 59);
            fill(x - 12, 598, 6, 6);
            const auto kind = item["kind"].toString();
            roll("music-id",
                 kind.toUpper() + " ID: " + item["id"].toString() + " / " + item["artist"].toString(), x, 624,
                 16, width - x - 210);
            text(kind.toUpper(), width - 170, 627, 11);
            QString label = "打开歌单资料库 →";
            if (kind == "song") {
                label = "查看歌曲详情 →";
            } else if (kind == "album") {
                label = "打开专辑资料库 →";
            } else if (kind == "artist") {
                label = "浏览歌手作品 →";
            }
            control(label, x, 703, 300, "open");
            aligned("点击打开 · ENTER 键也可打开", x, 771, 14);
        }
        text("TRACK / SELECT", 60, 865, 11);
        const auto number = MusicData::pad(music.libraryIndex() + 1);
        const auto numberSize = std::min(58.0, 58.0 * 77 / std::max(1.0, m_glyphs->width(number, 58)));
        rollingText("music-number", number, 60, 901.2, numberSize, "regular", 0, true);
        text("/", 141, 925, 32, "light");
        text(QString::number(music.libraryTotal()), 172, 932, 22);
    } else {
        empty(width);
    }
    const auto nav = width * 0.2625;
    button("↑", nav, 903, 46, 46, "prev", 28);
    for (int index = 0; index < 8; ++index) {
        const auto x = nav + 85 + index * 26;
        const auto row =
            std::max(0, int(music.physicalSlots[music.selectedLane].indexOf(frame["selected"].toInt())));
        auto color = ink();
        color[3] = index == row ? 1 : 0.45;
        fill(x, index == row ? 909 : 920, 2, index == row ? 33 : 12, color);
        if (!music.libraryItems().isEmpty()) {
            hit(x - 6, 900, 26, 50, "music:slot:" + QString::number(index),
                "选曲 " + QString::number(index + 1));
        }
    }
    button("↓", nav + 320, 903, 46, 46, "next", 28);
    const auto col = width * 0.5234375;
    button("←", col, 903, 46, 46, "column-prev", 28);
    if (!music.directory) {
        text("COLLECTION " + MusicData::pad(music.sourceOrder().indexOf(music.selectedLane) + 1) + " / " +
                 MusicData::pad(music.provider == "kugou" ? 4 : 5),
             col + 70, 904, 10);
        roll("music-column", music.libraryName(), col + 70, 925, 15, width - col - 360);
    } else {
        const auto label = "TRACK COLUMN " + MusicData::pad(music.selectedLane + 1) + " / 05";
        text(label, col + 62 + (171 - m_glyphs->width(label, 15)) / 2, 916, 15);
    }
    button("→", col + 310, 903, 46, 46, "column-next", 28);
    if (supportsTrackList()) {
        archiveTabButton(width);
    }
    text(music.directory ? "← → 浏览曲目列 / ↑ ↓ 选曲 / ENTER 查看 / ESC 上一级"
                         : "← → 切换来源 / ↑ ↓ 选曲 / ENTER 查看 / 检索",
         nav, 850, 12);
}

/** Tab 按钮 */
void NativeHud::archiveTabButton(double width) {
    const auto x = width - 340;
    hit(x - 8, 854, 186, 48, "archive:tab-mode", "Tab Mode，按 Tab 切换");
    text("Tab Mode", x, 866, 18, trackListMode ? "bold" : "regular");
    const auto color = ink();
    const auto keyX = x + 108;
    const auto keycap = QString("M %1 864 L %2 864 L %2 888 L %1 888 Z").arg(keyX).arg(keyX + 34);
    op({"path", keycap, 1, color});
    const auto symbol = QString("M %1 876 L %2 876 M %3 871 L %2 876 L %3 881 M %4 870 L %4 882")
                            .arg(keyX + 7)
                            .arg(keyX + 23)
                            .arg(keyX + 18)
                            .arg(keyX + 27);
    op({"path", symbol, 1.2, color});
}

/** 用连续曲目索引驱动整行位移；快速反向选曲接续当前的位置和速度。 */
double NativeHud::archiveTrackPosition(int selected) {
    const auto scope = m_music->provider + ":" + QString::number(quintptr(m_music->directory.get())) + ":" +
                       (m_music->directory ? QString() : QString::number(m_music->selectedLane)) + ":" +
                       m_music->groupName;
    const bool sameCollection = scope == m_trackListScope;
    auto position =
        m_trackListCurve ? m_trackListCurve->sample(lastTime) : std::array<double, 2>{double(selected), 0};
    if (reduced || !sameCollection || !m_trackListCurve || std::abs(selected - position[0]) > 8) {
        m_trackListCurve = UiMotion::ReelCurve(selected, selected, 0, lastTime - 0.64, 0.64);
        position = {double(selected), 0};
    } else if (m_trackListTarget != selected) {
        m_trackListCurve = UiMotion::ReelCurve(position[0], selected, position[1], lastTime, 0.64);
    }
    m_trackListScope = scope;
    m_trackListTarget = selected;
    return position[0];
}

/** 整首歌曲和对应刻度共用位移，不再使用逐字滚动；静止时保留原歌名字体和锚点。 */
void NativeHud::archiveTrackList(double x, double width) {
    const auto values = m_music->libraryItems();
    const auto selected = m_music->libraryIndex();
    if (selected < 0 || selected >= values.size()) {
        return;
    }
    const auto position = archiveTrackPosition(selected);
    constexpr double titleY = 509;
    constexpr double titleSize = 28;
    const auto bounds = m_glyphs->bounds("音乐", titleSize, "bold");
    const auto centerY = titleY + bounds["y"].toDouble() + bounds["height"].toDouble() / 2;
    // 标尺与指示使用固定锚点，长歌名只截断显示，不再推动标尺左右跳动。
    const auto rulerX = width - 160;
    const auto textWidth = std::max(1.0, rulerX - x - 68);
    const auto gray = dark ? QJsonArray{0.61, 0.62, 0.59, 1} : QJsonArray{0.49, 0.49, 0.46, 1};
    QVector<TrackRulerRow> rows;
    const auto first = std::max(0, int(std::floor(position)) - 5);
    const auto last = std::min(int(values.size()) - 1, int(std::ceil(position)) + 5);
    save();
    clip(x - 4, titleY - 290, width - x, 610);
    for (int index = first; index <= last; ++index) {
        const auto relative = index - position;
        const auto distance = std::abs(relative);
        const auto opacity = std::clamp(5 - distance, 0.0, 1.0);
        if (opacity <= 0.001 || values.at(index).toObject()["kind"] != "song") {
            continue;
        }
        // 第一段保留当前行两侧的大间隙，后续行按固定行距连续滑入和滑出。
        const auto offset = distance <= 1 ? distance * 88 : 88 + (distance - 1) * 52;
        const auto rowY = titleY + std::copysign(offset, relative);
        const auto emphasis = std::max(0.0, 1 - distance);
        auto color = ink();
        if (emphasis < 0.9999) {
            for (int channel = 0; channel < 3; ++channel) {
                color[channel] =
                    gray.at(channel).toDouble() * (1 - emphasis) + color.at(channel).toDouble() * emphasis;
            }
            color = QJsonArray{color.at(0), color.at(1), color.at(2), 1};
        }
        const auto name = index == selected ? m_music->current.value("title").toString()
                                            : values.at(index).toObject()["title"].toString();
        const auto shown = fit(name, titleSize, textWidth, "bold");
        const auto left = x - m_glyphs->inset(shown, titleSize, "bold");
        const auto rowBounds = m_glyphs->bounds(shown, titleSize, "bold");
        rows.append({rowY + rowBounds["y"].toDouble() + rowBounds["height"].toDouble() / 2,
                     left + m_glyphs->width(shown, titleSize, "bold"), emphasis, opacity});
        save();
        alpha(opacity);
        text(shown, left, rowY, titleSize, "bold", 0, color);
        restore();
        if (rowY >= titleY - 270 && rowY <= titleY + 270 && opacity > 0.5) {
            hit(x, rowY - 4, textWidth, 44,
                index == selected ? "open" : "music:index:" + QString::number(index), name);
        }
    }
    archiveTrackRuler(rulerX, centerY, rows);
    restore();
}

/** 刻度与歌曲继续同步滑动；鞍座和箭头始终固定在当前行锚点，不跟随切歌重复入场。 */
void NativeHud::archiveTrackRuler(double x, double centerY, const QVector<TrackRulerRow> &rows) {
    const auto color = dark ? QJsonArray{0.65, 0.67, 0.55, 0.8} : QJsonArray{0.46, 0.48, 0.37, 0.75};
    fill(x, centerY - 272, 1.5, 544, color);
    for (const auto &row : rows) {
        save();
        alpha(row.opacity);
        const auto length = 14 + 36 * row.emphasis;
        // 引导线和刻度以实际文字中心为准，动画中也不会与歌曲错行。
        const auto leaderStart = std::min(x - length - 8, row.textRight + 20);
        auto leader = color;
        leader[3] = 0.12 + 0.16 * row.emphasis;
        fill(leaderStart, row.centerY - 0.4, std::max(0.0, x - length - leaderStart), 0.8, leader);
        fill(x - length, row.centerY - 0.6, length, 1.2, color);
        restore();
    }
    const auto y = centerY;
    const auto saddle = QString("M %1 %2 L %1 %3 Q %1 %4 %5 %4 Q %6 %4 %6 %3 L %6 %2")
                            .arg(x - 6)
                            .arg(y - 7)
                            .arg(y + 4)
                            .arg(y + 11)
                            .arg(x + 2)
                            .arg(x + 10);
    op({"path", saddle, 2, color});
    fill(x + 10, y - 1, 16, 2, color);
    const auto arrow =
        QString("M %1 %2 L %3 %4 L %3 %5 Z").arg(x + 18).arg(y).arg(x + 29).arg(y - 5).arg(y + 5);
    op({"fill-path", arrow, color});
}
void NativeHud::actionButton(QString label, double x, double y, double width, QString action, bool primary) {
    auto color = ink();
    if (primary) {
        color = {119.0 / 255, 123.0 / 255, 96.0 / 255, 1};
    } else {
        color[3] = 0.075;
    }
    fill(x, y, width, 44, color);
    hit(x, y, width, 44, action, label);
    text(label, x + 14, y + 12, 15, "demibold", 0, primary ? QJsonArray{0.96, 0.95, 0.91, 1} : ink());
}
std::array<double, 2> NativeHud::rowMotion(const QString &signature, int index) {
    if (signature != m_resultSignature) {
        m_resultSignature = signature;
        m_resultStart = lastTime;
    }
    const auto progress =
        reduced ? 1 : std::clamp((lastTime - m_resultStart - index * 0.025) / 0.24, 0.0, 1.0);
    const auto remainder = std::pow(1 - progress, 3);
    return {1 - remainder, 10 * remainder};
}
QString NativeHud::clock(double ms) {
    return MusicData::pad(int(std::floor(ms / 60000))) + ":" +
           MusicData::pad(int(std::floor(ms / 1000)) % 60);
}
