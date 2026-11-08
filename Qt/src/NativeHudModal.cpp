#include <QScopedValueRollback>
#include <QtGlobal>
#include "NativeHud.h"
#include "ProviderRegistry.h"
#include <algorithm>

namespace {
struct Provider {
    QString id;
    QString name;
    QString label;
    QString detail;
};
QVector<Provider> providerCards() {
    QVector<Provider> values;
    const auto &registry = ProviderRegistry::instance();
    for (const auto &id : registry.ids()) {
        if (id == "local" && !PlatformFeatures::LocalMusic) {
            continue;
        }
        values.append({id, registry.name(id), registry.label(id), registry.detail(id)});
    }
    return values;
}

QString modalTitle(const QString &modal, const MusicLibrary &music) {
    static const QHash<QString, QString> titles{{"provider", "MUSIC PLATFORM"},
                                                {"settings", "SYSTEM SETTINGS"},
                                                {"desktop-lyrics", "DESKTOP LYRICS"},
                                                {"quality", "AUDIO QUALITY"},
                                                {"disc-rotation-warning", "DISC ROTATION"},
                                                {"saved", "MY MUSIC"},
                                                {"player", "NOW PLAYING"},
                                                {"discover", "DISCOVER MUSIC"},
                                                {"playlist-form", "PLAYLIST EDITOR"},
                                                {"playlist-picker", "PLAYLIST DIRECTORY"},
                                                {"confirm", "CONFIRM DELETE"}};
    if (modal == "local") {
        return "LOCAL MUSIC LIBRARY";
    }
    if (modal == "login") {
        const auto &registry = ProviderRegistry::instance();
        if (music.provider == "kugou" && music.kugouEdition == "lite") {
            return "KUGOU CONCEPT LOGIN";
        }
        return registry.label(music.provider) + " LOGIN";
    }
    return titles.value(modal, "MUSIC INDEX");
}
QString modalSubtitle(const QString &modal, const MusicLibrary &music) {
    static const QHash<QString, QString> subtitles{{"provider", "直接选择音乐平台 / 各平台账号独立保存"},
                                                   {"settings", "终端偏好设置"},
                                                   {"desktop-lyrics", "桌面歌词 / 样式与同步"},
                                                   {"quality", "声音档案 / 播放音质"},
                                                   {"disc-rotation-warning", "开启前请确认资源与功耗风险"},
                                                   {"player", "播放队列 / QUEUE"},
                                                   {"discover", "推荐 / 排行榜 / 新专辑"},
                                                   {"playlist-form", "编辑我的歌单"},
                                                   {"playlist-picker", "添加到我的歌单"},
                                                   {"confirm", "删除确认"}};
    if (modal == "local") {
        return "文件夹管理 / 导入与索引";
    }
    if (modal == "search" && music.isLocal()) {
        return "本地音乐检索 / 仅搜索已导入的索引";
    }
    if (modal == "saved") {
        return "我的音乐 / " + music.nickname;
    }
    if (modal == "login") {
        const auto hint = ProviderRegistry::instance().text(music.provider, "loginHint");
        return hint.isEmpty() ? QStringLiteral("可选登录，公开搜索不需要账号") : hint;
    }
    return subtitles.value(modal, "音乐检索");
}
}

/** 弹窗共用一次绘制栈与命中表，关闭曲线结束后才释放当前面板。 */
void NativeHud::modalDraw(double width) {
    auto &music = *m_music;
    save();
    alpha(motion.opacity);
    if (modal == "lyrics-offset") {
        const auto bounds = modalBounds(width);
        const auto x = bounds.x() + 16;
        const auto y = bounds.y();
        const auto &lyrics = music.player.lyrics;
        translate(0, motion.offset);
        fill(bounds.x(), y, bounds.width(), bounds.height(),
             dark ? QJsonArray{0.15, 0.15, 0.15, 1, "calibratedWhite"} : QJsonArray{0.929, 0.922, 0.894, 1});
        hits = {};
        m_modalControls = true;
        text("歌词偏移", x, y + 18, 17, "demibold");
        button("关闭", x + 232, y + 8, 56, 36, "close-modal", 13);
        QString offsetLabel = "未校准";
        if (lyrics.offsetMs != 0) {
            const auto direction = lyrics.offsetMs > 0 ? "已提前 " : "已延后 ";
            offsetLabel =
                QString(direction) + QString::number(std::abs(lyrics.offsetMs) / 1000, 'f', 1) + "s";
        }
        text(offsetLabel, x, y + 58, 15);
        button("歌词提前 0.2s", x, y + 92, 138, 40, "player:lyrics-earlier", 13);
        button("歌词延后 0.2s", x + 150, y + 92, 138, 40, "player:lyrics-later", 13);
        auto muted = ink();
        muted[3] = 0.45;
        if (lyrics.offsetMs != 0) {
            button("重置", x, y + 152, 138, 40, "player:lyrics-reset", 13);
        } else {
            text("重置", x, y + 161, 13, "regular", 0, muted);
        }
        if (lyrics.offsetMs != lyrics.globalOffsetMs()) {
            button("全局应用", x + 150, y + 152, 138, 40, "player:lyrics-apply-global", 13);
        } else {
            text("全局应用", x + 150, y + 161, 13, "regular", 0, muted);
        }
        m_modalControls = false;
        restore();
        return;
    }
    if (modal == "detail-sort") {
        const auto bounds = modalBounds(width);
        translate(0, motion.offset);
        hits = {};
        m_modalControls = true;
        // 菜单之外的点击只负责收起，避免穿透到下方曲目。
        hit(0, -motion.offset, width, 1080, "close-modal", "关闭排序菜单");
        fill(bounds.x(), bounds.y(), bounds.width(), bounds.height(),
             dark ? QJsonArray{0.15, 0.15, 0.15, 1} : QJsonArray{0.929, 0.922, 0.894, 1});
        const QStringList fields{"none", "title", "album", "artist"};
        const QStringList labels{"默认排序", "按歌曲名排序", "按专辑名排序", "按歌手名排序"};
        for (int index = 0; index < fields.size(); ++index) {
            const auto label = (detailSort == fields[index] ? QString("✓ ") : QString()) + labels[index];
            button(label, bounds.x() + 8, bounds.y() + 8 + index * 42, bounds.width() - 16, 42,
                   "music:sort:detail:" + fields[index], 14);
        }
        m_modalControls = false;
        restore();
        return;
    }
    if (modal == "lyrics-source") {
        const auto bounds = modalBounds(width);
        translate(0, motion.offset);
        fill(bounds.x(), bounds.y(), bounds.width(), bounds.height(),
             dark ? QJsonArray{0.15, 0.15, 0.15, 1, "calibratedWhite"} : QJsonArray{0.929, 0.922, 0.894, 1});
        hits = {};
        m_modalControls = true;
        const QStringList sources{"auto", "local", "netease", "qq", "kugou"};
        const QStringList labels{"自动（本地优先）", "本地歌词", "网易云音乐", "QQ 音乐", "酷狗音乐"};
        for (int index = 0; index < sources.size(); ++index) {
            const auto label =
                (music.player.lyrics.localSource == sources[index] ? QStringLiteral("✓ ") : QString()) +
                labels[index];
            button(label, bounds.x() + 10, bounds.y() + 11 + index * 42, bounds.width() - 20, 42,
                   "player:lyrics-source:" + sources[index], 15);
        }
        m_modalControls = false;
        restore();
        return;
    }
    const bool search = modal == "search";
    fill(0, 0, width, 1080,
         dark ? QJsonArray{17.0 / 255, 24.0 / 255, 27.0 / 255, search ? 0.15 : 0.6}
              : QJsonArray{227.0 / 255, 224.0 / 255, 215.0 / 255, search ? 0.12 : 0.45});
    translate(0, motion.offset);
    const auto bounds = modalBounds(width);
    const auto x = bounds.x();
    const auto y = bounds.y();
    const auto usable = bounds.width();
    fill(x, y, usable, 836,
         dark ? QJsonArray{0.15, 0.15, 0.15, 1, "calibratedWhite"} : QJsonArray{0.929, 0.922, 0.894, 1});
    hits = {};
    m_modalControls = true;
    if (modal == "player") {
        playerPanel(x, y, usable);
        m_modalControls = false;
        restore();
        return;
    }
    if (modal == "discover") {
        // 发现页独立绘制内部外观；弹层边界、遮罩、位移动画与关闭流程仍由宿主管理。
        discoverPanel(x, y, usable);
        m_modalControls = false;
        restore();
        return;
    }
    QString category = "MUSIC DIRECTORY";
    if (modal == "settings") {
        category = "SYSTEM PREFERENCES";
    } else if (modal == "desktop-lyrics") {
        category = "DESKTOP LYRICS";
    } else if (modal == "player") {
        category = "AUDIO TERMINAL";
    } else if (modal == "quality") {
        category = "AUDIO SPECIFICATION";
    }
    text("RHINE LAB / MUSIC DATABASE / " + category, x + 53, y + 37, modal == "settings" ? 14 : 11);
    button("← 返回", x + usable - 220, y + 18, 167, 54,
           modal == "desktop-lyrics" ? "desktop-lyrics:back" : "close-modal", 20, "demibold");
    text(modalTitle(modal, music), x + 53, y + 91, 38, "demibold");
    text(modalSubtitle(modal, music), x + 53, y + 147, modal == "settings" ? 18 : 15);
    modalBody(x, y, usable);
    m_modalControls = false;
    restore();
}

/** 主副布局复用相同业务文案和动作，移动端通过语义端口接收，不依赖桌面坐标。 */
void NativeHud::modalBody(double x, double y, double usable) {
    auto &music = *m_music;
    if (modal == "disc-rotation-warning") {
        text("唱片旋转需要持续刷新画面。", x + 53, y + 250, 22, "demibold");
        text("开启后会增加 CPU / GPU 占用、耗电和发热，可能缩短电池续航。", x + 53, y + 310, 16);
        text("仅当前歌曲的详情页和歌词页旋转；资源库、暂停和后台均不旋转。", x + 53, y + 352, 16);
        text("该功能默认关闭，减少动态效果开启时也不会旋转。", x + 53, y + 394, 16);
        button("了解风险，仍然开启", x + 53, y + 480, 260, 48, "disc-rotation:enable", 16);
        button("保持关闭", x + 340, y + 480, 180, 48, "disc-rotation:cancel", 16);
    } else if (modal == "quality") {
        qualityPanel(x, y, usable);
    } else if (modal == "provider") {
        platformPanel(x, y, usable);
    } else if (modal == "confirm") {
        limited(confirmTitle, x + 53, y + 260, 24, usable - 106, "demibold");
        text(music.isLocal() ? "只移除本地索引，磁盘音乐文件保持原样。"
                             : (music.isSiren() ? "只删除本机歌单，不会同步到塞壬唱片。"
                                                : "此操作将同步至" + music.providerName() + "。"),
             x + 53, y + 330, 16);
        button("确认删除", x + 53, y + 450, 180, 45, "confirm:yes", 16);
        button("取消", x + 270, y + 450, 150, 45, "close-modal", 16);
    } else if (modal == "playlist-picker") {
        text("选择我的歌单", x + 53, y + 240, 18);
        if (music.provider == "qq" &&
            std::none_of(music.lists[2].begin(), music.lists[2].end(),
                         [&music](QJsonValue value) { return music.canEditPlaylist(value.toObject()); })) {
            text("暂无可编辑的自建普通歌单，请先创建歌单。", x + 53, y + 320, 16);
        }
        for (int index = 0; index < 7 && listOffset + index < music.lists[2].size(); ++index) {
            const auto value = music.lists[2].at(listOffset + index).toObject();
            if (music.provider == "qq" && !music.canEditPlaylist(value)) {
                continue;
            }
            button(fit(value["title"].toString(), 18, usable - 106), x + 53, y + 290 + index * 60,
                   usable - 106, 52, "music:playlist-pick:" + value["id"].toString(), 18);
        }
        button("↑ 上一页", x + usable - 330, y + 758, 120, 32, "music:picker-prev", 12);
        button("下一页 ↓", x + usable - 190, y + 758, 120, 32, "music:picker-next", 12);
        limited(music.status, x + 53, y + 775, 12, usable - 420);
    } else if (modal == "playlist-form") {
        if (m_contentSink) {
            m_contentSink->field("account", formKind == "create" ? "歌单名称" : "新歌单名称");
            m_contentSink->field("submit", "提交歌单");
        }
        text(formKind == "create" ? "歌单名称" : "新歌单名称", x + 53, y + 240, 15);
        text(music.provider == "qq" ? "1–20 字 / 按 ENTER 提交" : "按 ENTER 提交", x + 53, y + 420, 12);
        limited(music.status, x + 53, y + 775, 12, usable - 106);
    } else if (modal == "local") {
        localPanel(x, y, usable);
    } else if (modal == "settings") {
        settingsPanel(x, y, usable);
    } else if (modal == "desktop-lyrics") {
        desktopLyricsPanel(x, y, usable);
    } else if (modal == "login") {
        loginPanel(x, y, usable);
    } else {
        libraryPanel(x, y, usable);
    }
}

QVector<ResponsiveHudContent::Item> NativeHud::auxiliaryContent() {
    ResponsiveHudContent::Model content;
    QScopedValueRollback<ResponsiveHudContent::Model *> sink(m_contentSink, &content);
    if (QStringList{"lyrics-offset", "lyrics-source", "detail-sort"}.contains(modal)) {
        modalDraw(width);
    } else {
        modalBody(0, 0, width);
    }
    return content.items;
}

void NativeHud::platformChoices(double x, double y, double width, bool expanded) {
    constexpr double gap = 12;
    const auto items = providerCards();
    if (items.isEmpty()) {
        return;
    }
    const auto cardWidth = (width - gap * (items.size() - 1)) / items.size();
    for (int index = 0; index < items.size(); ++index) {
        const auto &provider = items.at(index);
        const auto left = x + index * (cardWidth + gap);
        const bool selected = m_music->provider == provider.id;
        if (m_contentSink) {
            m_contentSink->action(provider.name + (selected ? " / 当前平台" : ""), "provider:" + provider.id);
            m_contentSink->text(provider.detail);
            continue;
        }
        const auto height = expanded ? 190 : 66;
        const auto tint = dark ? QJsonArray{0.55, 0.59, 0.46, selected ? 0.3 : 0.12}
                               : QJsonArray{0.44, 0.49, 0.36, selected ? 0.23 : 0.09};
        fill(left, y, cardWidth, height, tint);
        hit(left, y, cardWidth, height, "provider:" + provider.id, provider.name);
        if (selected) {
            fill(left, y, 3, height, dark ? QJsonArray{0.7, 0.75, 0.53, 1} : QJsonArray{0.44, 0.49, 0.36, 1});
        }
        text(provider.label + (selected ? " / ACTIVE" : ""), left + 16, y + 10, 10);
        text(provider.name, left + 16, y + 29, expanded ? 22 : 17, "demibold");
        if (expanded) {
            const auto lines = m_glyphs->wrap(provider.detail, cardWidth - 32, 14);
            for (int row = 0; row < std::min(3, int(lines.size())); ++row) {
                text(lines.at(row), left + 16, y + 75 + row * 21, 14);
            }
            const bool authenticated = m_host->hasCredential(provider.id);
            const auto note =
                provider.id == "local"
                    ? QStringLiteral("独立本地库 / 无需登录")
                    : (provider.id == "siren" ? QStringLiteral("官网曲库 / 无需登录")
                                              : (authenticated ? QStringLiteral("本机已保存登录")
                                                               : QStringLiteral("未登录 / 可选择后扫码")));
            limited(note, left + 16, y + 150, 12, cardWidth - 32);
        }
    }
}
void NativeHud::platformPanel(double x, double y, double width) {
    text("PROVIDER ACCESS / 音乐平台", x + 53, y + 222, 13, "demibold");
    platformChoices(x + 53, y + 258, width - 106, true);
    rule(x + 53, y + 490, width - 106, 0.2);
    text("切换平台会停止当前播放，各平台账号与个人音乐独立保存。", x + 53, y + 520, 15);
    QStringList editable;
    const auto &registry = ProviderRegistry::instance();
    for (const auto &id : registry.ids()) {
        if (id == "local" || id == "siren") {
            continue;
        }
        const auto methods =
            registry.descriptor(id)["capabilities"].toObject()["playlistManagement"].toObject();
        for (auto it = methods.begin(); it != methods.end(); ++it) {
            if (it.value().toBool()) {
                editable.append(registry.name(id));
                break;
            }
        }
    }
    text(editable.isEmpty() ? QStringLiteral("平台能力由插件声明。")
                            : QStringLiteral("支持歌单编辑：") + editable.join(QStringLiteral("、")),
         x + 53, y + 558, 15);
    text(registry.name("siren"), x + 53, y + 590, 15);
    if (m_music->isLocal()) {
        button("文件夹管理 ＋", x + 53, y + 660, 330, 48, "discover", 16);
    } else if (m_music->isSiren()) {
        text(registry.name("siren") + registry.detail("siren"), x + 53, y + 675, 15);
    } else {
        button("账号登录 / " + m_music->providerName(), x + 53, y + 660, 330, 48, "music:login", 16);
    }
}
namespace {
struct QualityDescription {
    QString title;
    QString caption;
    QString detail;
    QString badge;
};
const QHash<QString, QualityDescription> fallbackQualityDescriptions{
    {"standard", {"标准", "STANDARD", "日常聆听，兼顾音质与数据流量", ""}},
    {"higher", {"较高", "HIGH QUALITY", "提升声音细节，保持轻量传输", "hq"}},
    {"exhigh", {"极高", "HIGH QUALITY", "更充分保留有损编码中的声音细节", "hq"}},
    {"lossless", {"无损", "LOSSLESS / SQ", "无损编码，保留更完整的录音细节", "sq"}},
    {"ape", {"无损 / APE", "LOSSLESS / APE", "以 APE 格式提供无损音源", "sq"}},
    {"hires", {"高解析无损", "HI-RES AUDIO", "还原高解析录音中的丰富层次", "hires"}},
    {"jymaster", {"超清母带", "MASTER AUDIO", "聆听母带版本中的细腻质感与动态", "jymaster"}},
    {"best", {"自动最高可用", "BEST AVAILABLE", "由平台选择当前可用的最高音质", ""}}};
QualityDescription qualityDescriptionFor(const QString &provider, const QString &id) {
    const auto value = ProviderRegistry::instance().qualityDescription(provider, id);
    QualityDescription description{value["title"].toString(), value["caption"].toString(),
                                   value["detail"].toString(), value["badge"].toString()};
    if (description.title.isEmpty()) {
        description = fallbackQualityDescriptions.value(id);
    }
    return description;
}
QString qualityLabelFor(const QString &provider, const QString &id) {
    static const QHash<QString, QString> fallback{
        {"standard", "标准"},     {"hq", "高品质 / HQ"},
        {"sq", "无损 / SQ"},      {"hires", "高解析无损 / Hi-Res"},
        {"jymaster", "超清母带"}, {"jyeffect", "高清臻音"},
        {"sky", "沉浸环绕声"},
    };
    return ProviderRegistry::instance().qualityLabel(provider, id, fallback.value(id, id));
}
}

/** 音质选项采用统一档案标记；重点档位展开为卡片，普通档位保持紧凑行高。 */
void NativeHud::qualityChoice(const QString &id, int number, double x, double y, double width,
                              bool featured) {
    const auto description = qualityDescriptionFor(m_music->provider, id);
    const auto selected = m_music->player.quality == id ||
                          (m_music->isSiren() && id == ProviderRegistry::instance().defaultQuality("siren"));
    if (m_contentSink) {
        m_contentSink->action(description.title + (selected ? " / 已选择" : ""), "quality:set:" + id);
        m_contentSink->text(description.detail);
        return;
    }
    const auto height = featured ? 174. : 57.;
    const auto accent = dark ? QJsonArray{0.69, 0.74, 0.53, 1} : QJsonArray{0.43, 0.48, 0.34, 1};
    auto tint = accent;
    tint[3] = selected ? 0.18 : 0.055;
    if (featured || selected) {
        fill(x, y, width, height, tint);
    }
    rule(x, y + height, width, selected ? 0.6 : 0.13);
    if (selected) {
        fill(x, y, 3, height, accent);
    }
    hit(x, y, width, height, "quality:set:" + id, description.title);
    const auto index = QString::number(number).rightJustified(2, '0');
    const auto key = "quality:" + m_music->provider + "-" + description.badge;
    const auto pixels = description.badge.isEmpty() ? QImage() : m_host->image(key);
    const auto badgeX = featured ? x + width - 104 : x + 30;
    const auto badgeY = featured ? y + 19 : y + 16;
    if (!pixels.isNull()) {
        const auto badgeWidth = std::min(68., 21. * pixels.width() / pixels.height());
        const auto badgeHeight = badgeWidth * pixels.height() / pixels.width();
        if (ProviderRegistry::instance().qualityBadgeBackground(m_music->provider)) {
            fill(badgeX - 4, badgeY - 4, badgeWidth + 8, badgeHeight + 8, {0.30, 0.33, 0.26, 1});
        }
        image(key, badgeX, badgeY, badgeWidth, badgeHeight);
    } else if (!featured) {
        QString label = "STD";
        if (id == "best") {
            label = "AUTO";
        } else if (description.badge == "hq") {
            label = "HQ";
        }
        text(label, x + 30, y + 18, 11, "demibold");
    }
    if (featured) {
        text(index + " / " + description.caption, x + 22, y + 22, 11, "demibold", 0.8);
        text(description.title, x + 22, y + 62, 26, "demibold");
        limited(description.detail, x + 22, y + 106, 13, width - 44);
        text(selected ? "✓ 已选择" : "选择此档 →", x + 22, y + 143, 12, "demibold");
    } else {
        text(index, x + 10, y + 20, 9);
        text(description.title, x + 112, y + 6, 17, "demibold");
        limited(description.detail, x + 112, y + 32, 12, width - 256);
        text(selected ? "✓ 已选择" : description.caption, x + width - 134, y + 20, 10, "demibold");
    }
}

/** 将播放偏好与实际音源分开呈现；卡片与设置共用播放器的音质切换入口。 */
void NativeHud::qualityPanel(double x, double y, double width) {
    const auto &music = *m_music;
    const auto &player = music.player;
    const auto left = x + 53;
    const auto usable = width - 106;
    QString actual = player.actualQuality.isEmpty() ? QStringLiteral("尚未确认")
                                                    : qualityLabelFor(music.provider, player.actualQuality);
    if (player.failed) {
        actual = "音源不可用";
    } else if (player.loading) {
        actual = "正在获取音源…";
    } else if (player.trial) {
        actual = "试听片段";
    }
    const auto accent = dark ? QJsonArray{0.69, 0.74, 0.53, 1} : QJsonArray{0.43, 0.48, 0.34, 1};
    fill(left, y + 195, 3, 48, accent);
    text("实际音源 / SOURCE", left + 17, y + 199, 10, "demibold", 0.6);
    text(actual, left + 17, y + 219, 18, "demibold");
    const auto preference = qualityDescriptionFor(music.provider, player.quality).title;
    limited("已选偏好：" + preference, left + usable * 0.52, y + 219, 14, usable * 0.48);
    rule(left, y + 257, usable, 0.25);
    const auto featured = ProviderRegistry::instance().qualityFeatured(music.provider);
    const auto cardWidth = (usable - 18) / 2;
    for (int index = 0; index < featured.size(); ++index) {
        qualityChoice(featured.at(index), index + 1, left + index * (cardWidth + 18), y + 278, cardWidth,
                      true);
    }
    const auto options = MusicPlayer::qualityOptions(music.provider);
    int row = 0;
    for (auto option = options.crbegin(); option != options.crend(); ++option) {
        if (!featured.contains(option->first)) {
            qualityChoice(option->first, row + 3, left, y + 474 + row * 58, usable, false);
            ++row;
        }
    }
    // 未开放手动选择的扩展音源仍展示官方图标名称，避免把图标当作额外可选档位。
    const auto extras = ProviderRegistry::instance().qualityExtras(music.provider);
    if (!extras.isEmpty()) {
        text("其他音源标识", left, y + 738, 11, "demibold");
        for (int index = 0; index < extras.size(); ++index) {
            const auto extra = extras.at(index).toObject();
            const auto id = extra["id"].toString();
            if (id.isEmpty()) {
                continue;
            }
            const auto key = "quality:" + music.provider + "-" + id;
            const auto pixels = m_host->image(key);
            const auto badgeX = left + 130 + index * 235;
            if (!pixels.isNull()) {
                const auto badgeWidth = 18. * pixels.width() / pixels.height();
                image(key, badgeX, y + 735, badgeWidth, 18);
                text(extra["label"].toString(id), badgeX + badgeWidth + 12, y + 737, 12);
            }
        }
    }
    rule(left, y + 775, usable, 0.22);
    text("选择与设置同步 · 切换保留播放位置", left, y + 791, 12);
    limited("可用音质由歌曲与平台权益决定，以实际音源为准。", left + usable * 0.47, y + 791, 12,
            usable * 0.53);
}
