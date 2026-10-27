#include "NativeHud.h"
#include "GraphicsBackend.h"
#include "fg/FgCapability.h"
#include "scene/FilamentConfig.h"
#include "MusicData.h"
#include <algorithm>

namespace {
struct Provider {
    QString id;
    QString name;
    QString label;
    QString detail;
};
const QVector<Provider> providers = [] {
    QVector<Provider> values{
        {"netease", "网易云音乐", "NETEASE", "搜索 · 个人音乐 · 推荐 · 播放 · 歌单编辑"},
        {"qq", "QQ 音乐", "QQ MUSIC", "全类搜索 · 每日推荐 · 个人音乐 · 歌单编辑"},
        {"kugou", "酷狗音乐", "KUGOU", "标准版 / 概念版 · 个人歌单 · 推荐与榜单 · 播放"},
        {"local", "本地音乐", "LOCAL", "文件夹管理 · 导入与索引 · 本地检索 · 播放"},
    };
    if (!PlatformFeatures::LocalMusic) {
        values.removeLast();
    }
    return values;
}();

QString modalTitle(const QString &modal, const MusicLibrary &music) {
    static const QHash<QString, QString> titles{{"provider", "MUSIC PLATFORM"},
                                                {"settings", "SYSTEM SETTINGS"},
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
        if (music.provider == "qq") {
            return "QQ MUSIC LOGIN";
        }
        if (music.provider == "kugou") {
            return music.kugouEdition == "lite" ? "KUGOU CONCEPT LOGIN" : "KUGOU LOGIN";
        }
        return "NETEASE LOGIN";
    }
    return titles.value(modal, "MUSIC INDEX");
}
QString modalSubtitle(const QString &modal, const MusicLibrary &music) {
    static const QHash<QString, QString> subtitles{{"provider", "直接选择音乐平台 / 各平台账号独立保存"},
                                                   {"settings", "终端偏好设置"},
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
        return music.provider == "kugou" ? "使用对应版本酷狗 App 扫码；搜索与个人音乐需要登录"
                                         : "可选登录，公开搜索不需要账号";
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
    QString category = "MUSIC DIRECTORY";
    if (modal == "settings") {
        category = "SYSTEM PREFERENCES";
    } else if (modal == "player") {
        category = "AUDIO TERMINAL";
    } else if (modal == "quality") {
        category = "AUDIO SPECIFICATION";
    }
    text("RHINE LAB / MUSIC DATABASE / " + category, x + 53, y + 37, modal == "settings" ? 14 : 11);
    button("← 返回", x + usable - 220, y + 18, 167, 54, "close-modal", 20, "demibold");
    text(modalTitle(modal, music), x + 53, y + 91, 38, "demibold");
    text(modalSubtitle(modal, music), x + 53, y + 147, modal == "settings" ? 18 : 15);
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
                             : "此操作将同步至" + music.providerName() + "。",
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
        text(formKind == "create" ? "歌单名称" : "新歌单名称", x + 53, y + 240, 15);
        text(music.provider == "qq" ? "1–20 字 / 按 ENTER 提交" : "按 ENTER 提交", x + 53, y + 420, 12);
        limited(music.status, x + 53, y + 775, 12, usable - 106);
    } else if (modal == "local") {
        localPanel(x, y, usable);
    } else if (modal == "discover") {
        discoverPanel(x, y, usable);
    } else if (modal == "player") {
        playerPanel(x, y, usable);
    } else if (modal == "settings") {
        settings(x, y, usable);
    } else if (modal == "login") {
        loginPanel(x, y, usable);
    } else {
        libraryPanel(x, y, usable);
    }
    m_modalControls = false;
    restore();
}

void NativeHud::platformChoices(double x, double y, double width, bool expanded) {
    constexpr double gap = 12;
    const auto cardWidth = (width - gap * (providers.size() - 1)) / providers.size();
    for (int index = 0; index < providers.size(); ++index) {
        const auto &provider = providers.at(index);
        const auto left = x + index * (cardWidth + gap);
        const bool selected = m_music->provider == provider.id;
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
            const auto note = provider.id == "local"
                                  ? QStringLiteral("独立本地库 / 无需登录")
                                  : (authenticated ? QStringLiteral("本机已保存登录")
                                                   : QStringLiteral("未登录 / 可选择后扫码"));
            limited(note, left + 16, y + 150, 12, cardWidth - 32);
        }
    }
}
void NativeHud::platformPanel(double x, double y, double width) {
    text("PROVIDER ACCESS / 音乐平台", x + 53, y + 222, 13, "demibold");
    platformChoices(x + 53, y + 258, width - 106, true);
    rule(x + 53, y + 490, width - 106, 0.2);
    text("切换平台会停止当前播放，各平台账号与个人音乐独立保存。", x + 53, y + 520, 15);
    text("网易云与 QQ 支持歌单编辑；酷狗支持读取与播放。", x + 53, y + 558, 15);
    if (m_music->isLocal()) {
        button("文件夹管理 ＋", x + 53, y + 660, 330, 48, "discover", 16);
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
const QHash<QString, QualityDescription> qualityDescriptions{
    {"standard", {"标准", "STANDARD", "日常聆听，兼顾音质与数据流量", ""}},
    {"higher", {"较高", "HIGH QUALITY", "提升声音细节，保持轻量传输", "hq"}},
    {"exhigh", {"极高", "HIGH QUALITY", "更充分保留有损编码中的声音细节", "hq"}},
    {"lossless", {"无损", "LOSSLESS / SQ", "无损编码，保留更完整的录音细节", "sq"}},
    {"ape", {"无损 / APE", "LOSSLESS / APE", "以 APE 格式提供无损音源", "sq"}},
    {"hires", {"高解析无损", "HI-RES AUDIO", "还原高解析录音中的丰富层次", "hires"}},
    {"jymaster", {"超清母带", "MASTER AUDIO", "聆听母带版本中的细腻质感与动态", "jymaster"}},
    {"best", {"自动最高可用", "BEST AVAILABLE", "由平台选择当前可用的最高音质", ""}}};
}

/** 音质选项采用统一档案标记；重点档位展开为卡片，普通档位保持紧凑行高。 */
void NativeHud::qualityChoice(const QString &id, int number, double x, double y, double width,
                              bool featured) {
    const auto description = qualityDescriptions.value(id);
    const bool selected = m_music->player.quality == id;
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
        if (m_music->provider == "kugou") {
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
    const QHash<QString, QString> names{{"standard", "标准"},     {"hq", "高品质 / HQ"},
                                        {"sq", "无损 / SQ"},      {"hires", "高解析无损 / Hi-Res"},
                                        {"jymaster", "超清母带"}, {"jyeffect", "高清臻音"},
                                        {"sky", "沉浸环绕声"}};
    QString actual = names.value(player.actualQuality, "尚未确认");
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
    const auto preference = qualityDescriptions.value(player.quality).title;
    limited("已选偏好：" + preference, left + usable * 0.52, y + 219, 14, usable * 0.48);
    rule(left, y + 257, usable, 0.25);
    QStringList featured{"jymaster", "hires"};
    if (music.provider == "qq") {
        featured = {"best", "lossless"};
    } else if (music.provider == "kugou") {
        featured = {"hires", "lossless"};
    }
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
    if (music.provider == "netease") {
        text("其他音源标识", left, y + 738, 11, "demibold");
        const QStringList extraBadges{"jyeffect", "sky"};
        for (int index = 0; index < extraBadges.size(); ++index) {
            const auto id = extraBadges.at(index);
            const auto key = "quality:" + music.provider + "-" + id;
            const auto pixels = m_host->image(key);
            const auto badgeX = left + 130 + index * 235;
            if (!pixels.isNull()) {
                const auto badgeWidth = 18. * pixels.width() / pixels.height();
                image(key, badgeX, y + 735, badgeWidth, 18);
                text(names.value(id), badgeX + badgeWidth + 12, y + 737, 12);
            }
        }
    }
    rule(left, y + 775, usable, 0.22);
    text("选择与设置同步 · 切换保留播放位置", left, y + 791, 12);
    limited("可用音质由歌曲与平台权益决定，以实际音源为准。", left + usable * 0.47, y + 791, 12,
            usable * 0.53);
}

namespace {
/**
 * 优先使用本次启动实际后端，避免 Vulkan 探测失败后仍按保存的偏好启用 FSR3。
 * Qt 的 GL RHI 没有计算着色器，OpenGL 回退时必须关闭此能力。
 */
bool backendRunsFsr3(const Host *host) {
#if defined(Q_OS_MACOS)
    // macOS 只有 Metal，而 FSR3 后端只实现 Vulkan/D3D12。
    Q_UNUSED(host);
    return false;
#elif !defined(RHINE_FSR3_VULKAN) && !defined(RHINE_FSR3_DX12)
    // 构建里没有编进任何 FSR3 后端（Vulkan 后端缺失或着色器置换未生成）。
    // 这时即使后端名匹配也不该把 FSR3 列成可选——选中的结果只是静默无效。
    Q_UNUSED(host);
    return false;
#else
    const auto active = RhineGraphics::activeBackend();
    const auto backend = active.isEmpty() ? host->preference("graphics-backend") : active;
#if RHINE_ENABLE_D3D12_BACKEND
    if (backend == "d3d12") {
        return true;
    }
#endif
    return backend.isEmpty() || backend == "vulkan";
#endif
}
/**
 * 帧生成这一行的结论：判定本身在 RhineFg::frameGenerationUi（可单测），
 * 这里只负责把当前进程的能力快照与用户偏好喂进去。
 *
 * 后端能力看的是"这次启动实际选中的后端"而不是持久化偏好：RHINE_GRAPHICS 覆盖、
 * 或者 Vulkan 设备缺失导致回退时，偏好里写的还是 vulkan，但真正跑的已经不是它了。
 * 帧生成目前只有 Vulkan 实现，所以这里要求恰好是 vulkan。
 */
RhineFg::FrameGenerationUi frameGenerationUi(const Host *host, bool preferenceOn) {
    const auto &capability = RhineFg::capability();
    const auto active = RhineGraphics::activeBackend();
    const bool backendCapable = active.isEmpty() ? host->preference("graphics-backend") != "opengl"
                                                 : active == QLatin1String("vulkan")
#ifdef Q_OS_MACOS
                                                       || active == QLatin1String("metal")
#endif
        ;
    return RhineFg::frameGenerationUi(capability.compiledIn, capability.presentLayerActive,
                                      capability.interpolationAvailable, capability.reason, backendCapable,
                                      preferenceOn);
}

} // namespace

void NativeHud::settings(double x, double y, double width) {
    const auto &music = *m_music;
    static const QHash<QString, QString> qualities{
        {"standard", "标准"}, {"higher", "较高"},   {"exhigh", "极高"},       {"lossless", "无损"},
        {"hires", "Hi-Res"},  {"jymaster", "母带"}, {"best", "自动最高可用"}, {"ape", "APE 无损"}};
    QString theme = dark ? "暗色" : "亮色";
    if (themeMode == "system") {
        theme = "跟随系统";
    }
    QVector<QStringList> rows{
        {"WINDOW / 窗口显示", "切换全屏 / F11", "window:fullscreen"},
        {"COLOR THEME / 界面配色", theme, "theme"},
        {"REDUCED MOTION / 动态效果", reduced ? "减少动态效果" : "完整动效", "motion"},
        {"STARTUP ANIMATION / 初始化动画", startupAnimation ? "开启" : "关闭", "startup-animation"},
        {"AUDIO QUALITY / 音质", qualities.value(music.player.quality), "quality"}};
    if (music.provider == "netease") {
        rows.append({"ALTERNATE SOURCE / 替代音源",
                     music.player.alternative ? "开启（音质由来源决定）" : "关闭", "alternative"});
    }
    if (music.isLocal()) {
        rows.removeLast();
    } else if (PlatformFeatures::OfficialPlayback) {
        rows.append({"OFFICIAL PLAYER / 官方窗口", m_host->activates() ? "播放时显示" : "尽量保持后台",
                     "music:activate"});
    }
    if (!PlatformFeatures::DesktopWindowControls) {
        rows.removeFirst();
    }
    rows.append({"ENTER AUTOPLAY / 进入详情自动播放",
                 m_host->preference("detail-autoplay") == "on" ? "开启" : "关闭", "detail-autoplay"});
    rows.append({"PLAYLIST ON PLAY / 点击播放单曲",
                 m_host->preference("single-play-mode") == "append" ? "仅添加当前单曲" : "替换为所在列表",
                 "single-play-mode"});
    rows.append({"RIGHT MASK / 右侧画面遮罩", "", "archive-mask"});
    // 图形后端写入配置，重启后由启动逻辑应用；用于定位玻璃渲染是否为特定后端的问题。
    const auto savedBackend = m_host->preference("graphics-backend");
    const auto backendSetting = savedBackend == "d3d12" || savedBackend == "d3d11" ? QString() : savedBackend;
    static const QHash<QString, QString> backendNames{
        {"vulkan", "Vulkan"}, {"opengl", "OpenGL"}, {"d3d12", "Direct3D 12"}};
    const auto pending = backendSetting.isEmpty() ? QStringLiteral("默认 / 自动探测")
                                                  : backendNames.value(backendSetting, backendSetting);
    // 显示本次启动实际应用的后端：只读配置值会在环境变量覆盖或保存值过期时与画面不一致。
    const auto applied = RhineGraphics::activeBackend();
    QString backendLabel = pending;
    if (!applied.isEmpty()) {
        const auto appliedName = backendNames.value(applied, applied);
        if (backendSetting.isEmpty()) {
            backendLabel = appliedName + QStringLiteral("（自动）");
        } else if (applied != backendSetting) {
            backendLabel = appliedName + QStringLiteral("（下次启动：") + pending + QStringLiteral("）");
        } else {
            backendLabel = appliedName;
        }
    }
    rows.append({"GRAPHICS BACKEND / 图形后端 · 重启生效", backendLabel, "graphics-backend"});
    // 【功能暂未完成】Filament 渲染后端暂不对外开放：V3/V4 画面保真度未达标，
    // resolveConfig() 已无条件回退到 legacy 链路，因此设置里不再暴露该条目。
    // 功能完成并验收通过后取消下面的注释、并删除 FilamentConfig.cpp 里的无条件 return。
    // 原实现：
    // {
    //     const auto config = RhineFilament::resolveConfig(m_host->preference("filament"), false);
    //     const auto state = !RhineFilament::compiledIn()
    //                            ? QStringLiteral("未编入")
    //                            : (config.requested ? QStringLiteral("开启") : QStringLiteral("关闭"));
    //     rows.append({"FILAMENT / Filament 渲染 · 重启生效", state, "filament"});
    // }
    // 显卡选择的选项表：非 Linux 恒为空，这一行也就不出现（Windows 由 DXGI 直接取适配器，
    // macOS 固定 Metal，两边都没有可选项）。表在这里一次建好，绘制与展开高度共用同一份。
    // 只显示序号（0 基，与 /sys/class/drm 的 cardN 顺序一致）：换过卡之后型号必定变化，
    // 拿型号当身份会让"换卡"变成"悄悄选到另一张卡"；序号不存在时启动逻辑会回退默认，
    // 这里把回退写进当前值，用户才知道自己保存的序号已经不适用了。
    QVector<QPair<QString, QString>> gpuOptions;
    int gpuOptionIndex = 0;
#if defined(Q_OS_LINUX)
    int gpuCount = 0;
    QString gpuLabel = QStringLiteral("默认");
    gpuCount = RhineGraphics::gpuDeviceCount();
    if (gpuCount > 1) {
        // 第一项是"默认"：清空配置后启动不再注入任何厂商变量，行为与没有这个功能时一致。
        gpuOptions.append({"default", QStringLiteral("默认")});
        for (int gpu = 0; gpu < gpuCount; ++gpu) {
            gpuOptions.append({QString::number(gpu), QStringLiteral("显卡 ") + QString::number(gpu)});
        }
        const auto gpuPreference = m_host->preference("gpu-index").trimmed();
        bool numeric = false;
        const int stored = gpuPreference.toInt(&numeric);
        if (numeric && stored >= 0 && stored < gpuCount) {
            gpuOptionIndex = stored + 1;
            gpuLabel = QStringLiteral("显卡 ") + QString::number(stored);
        } else if (!gpuPreference.isEmpty()) {
            gpuLabel = QStringLiteral("默认（序号 %1 不存在）").arg(gpuPreference);
        } else if (RhineGraphics::gpuAppliedIndex() >= 0) {
            // RHINE_GPU_INDEX 只影响本次启动，标出来免得和保存值混淆。
            gpuLabel = QStringLiteral("显卡 %1（RHINE_GPU_INDEX）").arg(RhineGraphics::gpuAppliedIndex());
        }
        rows.append({"GPU / 显卡 · 重启生效", gpuLabel, "gpu-index"});
    }
#endif
#ifndef Q_OS_MACOS
    // 垂直同步关闭后允许帧率超过屏幕刷新率，由交换链的呈现模式决定，重启生效。
    rows.append({"V-SYNC / 垂直同步 · 重启生效", vsync ? "开启" : "关闭", "vsync"});
#endif
    // 渲染分辨率：内部目标按百分比创建，最终合成通道再缩放回窗口，重启后生效。
    // 小于 100 换帧率，大于 100 是超采样换抗锯齿，因此用 +/- 步进而不是点击循环。
    const auto renderScale = m_host->preference("render-scale").toInt();
    rows.append({"RENDER SCALE / 渲染分辨率", "", "render-scale"});
    // 抗锯齿互斥单选，默认关闭；倍率只对 SSAA 生效，与渲染分辨率相乘。
    const auto aaMode = m_host->preference("aa-mode");
    const auto aaScale = m_host->preference("aa-scale").toInt();
    const auto fgUi = frameGenerationUi(m_host, m_host->preference("fg") == "on");
    // 这一栏同时包含抗锯齿与超分（FSR），所以标题不能只写"抗锯齿"。
#ifdef Q_OS_MACOS
    rows.append({"METALFX / 时域抗锯齿与超分辨率",
                 RhineFg::capability().temporalAvailable ? "" : "系统或设备不支持",
                 RhineFg::capability().temporalAvailable ? "aa-mode" : "aa-mode:unavailable"});
#else
    rows.append({"AA & UPSCALING / 抗锯齿与超分辨率", "", "aa-mode"});
#endif
    // 下拉块选项表在建表时确定：展开高度与绘制共用同一份列表，避免两处不一致。
    // 名称必须用 QStringLiteral：QLatin1String 会把 UTF-8 字节逐个当 Latin-1 解释，中文变乱码。
    // FSR 只有一个选项：内部按后端能力自动选择 FFX 计算后端（FSR3）或 EASU/RCAS
    // 片元实现（FSR1），用户不需要理解两代算法的差别，也不会选到跑不了的那个。
    QVector<QPair<QString, QString>> aaOptions{
        {"off", QStringLiteral("关闭")},  {"fxaa", QStringLiteral("FXAA")}, {"ssaa", QStringLiteral("SSAA")},
        {"msaa", QStringLiteral("MSAA")}, {"taa", QStringLiteral("TAA")},   {"fsr", QStringLiteral("FSR")}};
#ifdef Q_OS_MACOS
    aaOptions = {{"off", QStringLiteral("关闭")}, {"metalfx", QStringLiteral("MetalFX Temporal")}};
#endif
    // 旧版本保存过 fsr1 / fsr3，统一按合并后的 fsr 显示，避免升级后显示成"关闭"。
    const auto aaSelected = (aaMode == "fsr1" || aaMode == "fsr3") ? QStringLiteral("fsr") : aaMode;
    int aaIndex = 0;
    for (int i = 0; i < aaOptions.size(); ++i) {
        if (aaSelected == aaOptions.at(i).first) {
            aaIndex = i;
            break;
        }
    }
    // FSR 专属两行只在 FSR 模式下出现：档位决定内部渲染分辨率，锐化决定 RCAS 强度。
    const bool fsrActive = aaMode == "fsr" || aaMode == "fsr1" || aaMode == "fsr3";
    const QVector<QPair<QString, QString>> fsrOptions{{"native", QStringLiteral("原生 AA")},
                                                      {"quality", QStringLiteral("高质量")},
                                                      {"balanced", QStringLiteral("平衡")},
                                                      {"performance", QStringLiteral("性能")},
                                                      {"super", QStringLiteral("超级性能")}};
    const auto fsrQuality = m_host->preference("fsr-quality");
    int fsrIndex = 0;
    for (int i = 0; i < fsrOptions.size(); ++i) {
        if (fsrQuality == fsrOptions.at(i).first) {
            fsrIndex = i;
            break;
        }
    }
    const auto fsrSharpnessPref = m_host->preference("fsr-sharpness");
    const int fsrSharpness = fsrSharpnessPref.isEmpty() ? 50 : fsrSharpnessPref.toInt();
    // MSAA 采样数：只有 2/4/8 三档，未设置时用渲染器的默认目标 4x。
    const auto msaaPref = m_host->preference("msaa").toInt();
    const int msaaSamples = msaaPref > 1 ? std::clamp(msaaPref, 2, 8) : 4;
    constexpr double aaOptionStep = 52;
    // 展开时列表占位参与内容总高度，滚动范围随之变长。
    const double aaExtra =
        expandedPreference == QLatin1String("aa-mode") ? aaOptions.size() * aaOptionStep : 0;
    const double fsrExtra =
        expandedPreference == QLatin1String("fsr-quality") ? fsrOptions.size() * aaOptionStep : 0;
    const double gpuExtra =
        expandedPreference == QLatin1String("gpu-index") ? gpuOptions.size() * aaOptionStep : 0;
    const double dropdownExtra = aaExtra + fsrExtra + gpuExtra;
    // 抗锯齿的子设置紧跟主行，按当前模式决定显示哪些：SSAA 只有倍率，MSAA 只有采样数，
    // FSR1/FSR3 有档位与锐化，off/fxaa/taa 没有子设置。不适用的行直接不出现，
    // 避免调了没有任何效果。

#ifndef Q_OS_MACOS
    if (aaMode == "ssaa") {
        rows.append({"AA SCALE / 抗锯齿倍率", "", "aa-scale"});
    } else if (aaMode == "msaa") {
        rows.append({"MSAA SAMPLES / 多重采样倍率", "", "msaa"});
    } else if (fsrActive) {
        rows.append({"FSR QUALITY / FSR 档位", "", "fsr-quality"});
        rows.append({"FSR SHARPNESS / 锐化", "", "fsr-sharpness"});
    }
#endif
    // 帧生成是独立开关，不随抗锯齿模式循环。呈现层在能力可用时常驻接管窗口，
    // 所以这里的开关即时生效、不需要重启；不可用时整行置灰并写明原因。
#ifdef Q_OS_MACOS
    rows.append({"METALFX / 帧生成", fgUi.value, fgUi.clickable ? "fg" : "fg:unavailable"});
#else
    rows.append({"FRAME GENERATION / 帧生成", fgUi.value, fgUi.clickable ? "fg" : "fg:unavailable"});
#endif
    // 内容高度随平台可用选项变化
    constexpr double preferenceTop = 424;
    constexpr double rowStep = 66;
    const auto performanceTop = preferenceTop + rows.size() * rowStep + 76 + dropdownExtra;
    const auto updateTop = performanceTop + 310;
    const auto projectTop = updateTop + 310;
    settingsContentBottom = projectTop + 278;
    const auto viewport =
        QRectF(x + 40, y + SettingsViewportTop, width - 80, SettingsViewportBottom - SettingsViewportTop);
    settingsScroll = std::clamp(settingsScroll, 0., settingsScrollMaximum());
    const auto firstHit = hits.size();
    const auto originalY = y;
    save();
    clip(viewport.x(), viewport.y(), viewport.width(), viewport.height());
    y -= settingsScroll;
    const auto left = x + 53;
    const auto usable = width - 106;
    const auto tint = dark ? QJsonArray{1, 1, 1, 0.025} : QJsonArray{0, 0, 0, 0.025};
    text("PROVIDER ACCESS / 音乐平台", left, y + 188, 16, "demibold");
    fill(left, y + 224, usable, 66, tint);
    text("当前平台 / " + music.providerName(), left + 16, y + 247, 18, "demibold");
    button("切换平台 ▾", left + usable - 280, y + 235, 264, 44, "provider", 16);
    if (music.isLocal()) {
        button("文件夹管理 / 导入与索引", left, y + 308, 340, 44, "discover", 16);
    } else {
        button(music.uid.isEmpty() ? "登录 / " + music.providerName() : "退出登录 / " + music.nickname, left,
               y + 308, 340, 44, music.uid.isEmpty() ? "music:login" : "music:logout", 16);
    }
    const QHash<QString, QString> memberships{
        {"free", "免费账号"}, {"green", "绿钻会员"}, {"super", "超级会员"}, {"unknown", "会员状态未知"}};
    const auto accountNote = music.provider == "qq" && !music.uid.isEmpty()
                                 ? memberships.value(music.vipLevel, "会员状态未知")
                                 : QString("各平台账号独立保存");
    limited(accountNote, left + 365, y + 322, 15, usable - 365);
    rule(left, y + 376, usable, 0.2);
    text("TERMINAL PREFERENCES / 终端偏好", left, y + 392, 16, "demibold");
    // 下拉块绘制：标题行整行可点，右侧显示当前值与箭头；展开后在行下列出全部选项。
    // 返回新增高度，由调用方累加进 rowShift，让后续行整体下移。
    const auto dropdown = [&](const QVector<QPair<QString, QString>> &options, int current,
                              const QString &key, const QString &prefix, double dropdownY,
                              double dropdownLeft, double dropdownWidth, const QJsonArray &dropdownInk,
                              const QJsonArray &dropdownTint) -> double {
        const bool expanded = expandedPreference == key;
        hit(dropdownLeft, dropdownY, dropdownWidth, 56, "expand:" + key, options.at(current).second);
        text(options.at(current).second, dropdownLeft + dropdownWidth - 300, dropdownY + 19, 17, "regular", 0,
             dropdownInk);
        text(expanded ? QStringLiteral("▴") : QStringLiteral("▾"), dropdownLeft + dropdownWidth - 52,
             dropdownY + 19, 16, "regular", 0, dropdownInk);
        if (!expanded) {
            return 0.;
        }
        for (int option = 0; option < options.size(); ++option) {
            const auto optionY = dropdownY + 56 + option * aaOptionStep;
            const bool active = option == current;
            fill(dropdownLeft + 16, optionY, dropdownWidth - 32, aaOptionStep - 4, dropdownTint);
            text(options.at(option).second, dropdownLeft + 40, optionY + 17, 16,
                 active ? "demibold" : "regular", 0, dropdownInk);
            if (active) {
                // 选中项用实心圆点标记，与右侧"当前值"重复一次以便扫读。
                text(QStringLiteral("●"), dropdownLeft + dropdownWidth - 60, optionY + 16, 13, "regular");
            }
            hit(dropdownLeft + 16, optionY, dropdownWidth - 32, aaOptionStep - 4,
                prefix + options.at(option).first, options.at(option).second);
        }
        return options.size() * aaOptionStep;
    };
    double rowShift = 0;
    for (int index = 0; index < rows.size(); ++index) {
        const auto &row = rows.at(index);
        // 下拉块展开后，其后所有行整体下移，避免与选项列表重叠。
        const auto rowY = y + preferenceTop + index * rowStep + rowShift;
        fill(left, rowY, usable, 56, tint);
        // 后端不支持的开关只显示状态：整行置灰且不注册命中区域，避免点了没有效果。
        const bool unavailable = row.at(2).endsWith(":unavailable");
        auto rowInk = ink();
        if (unavailable) {
            rowInk[3] = 0.35;
        }
        text(row.at(0), left + 16, rowY + 18, 18, "demibold", 0, rowInk);
        if (row.at(2) == "gpu-index") {
            // 显卡下拉块：选中即收起（收起与写配置都在 NativeHud::action 的 gpu-index: 分支）。
            rowShift += dropdown(gpuOptions, gpuOptionIndex, QStringLiteral("gpu-index"),
                                 QStringLiteral("gpu-index:"), rowY, left, usable, rowInk, tint);
        } else if (row.at(2) == "aa-mode") {
            // 抗锯齿下拉块：选中即收起（收起逻辑在 NativeHud::action 的 aa-mode: 分支里）。
            rowShift += dropdown(aaOptions, aaIndex, QStringLiteral("aa-mode"), QStringLiteral("aa-mode:"),
                                 rowY, left, usable, rowInk, tint);
        } else if (row.at(2) == "fsr-quality") {
            // FSR 超分档位：同样走下拉块，档位变化会改变内部渲染分辨率。
            rowShift += dropdown(fsrOptions, fsrIndex, QStringLiteral("fsr-quality"),
                                 QStringLiteral("fsr-quality:"), rowY, left, usable, rowInk, tint);
        } else if (row.at(2) == "fsr-sharpness") {
            // 锐化 0–100，步进 10；逐帧生效，不需要重启或重建目标。
            button("−", left + usable - 280, rowY + 6, 48, 44,
                   "fsr-sharpness:" + QString::number(std::max(0, fsrSharpness - 10)), 20);
            centeredText(QString::number(fsrSharpness) + "%", left + usable - 148, rowY + 28, 16, "regular",
                         true);
            button("＋", left + usable - 64, rowY + 6, 48, 44,
                   "fsr-sharpness:" + QString::number(std::min(100, fsrSharpness + 10)), 20);
        } else if (row.at(2) == "msaa") {
            // 采样数固定三档循环，避免出现 3x/5x 这类设备普遍不支持的值。
            static const int steps[] = {2, 4, 8};
            constexpr int count = 3;
            int stepIndex = 1;
            for (int i = 0; i < count; ++i) {
                if (steps[i] == msaaSamples) {
                    stepIndex = i;
                    break;
                }
            }
            button("−", left + usable - 280, rowY + 6, 48, 44,
                   "msaa:" + QString::number(steps[(stepIndex + count - 1) % count]), 20);
            centeredText(QString::number(msaaSamples) + "x", left + usable - 148, rowY + 28, 16, "regular",
                         true);
            button("＋", left + usable - 64, rowY + 6, 48, 44,
                   "msaa:" + QString::number(steps[(stepIndex + 1) % count]), 20);
        } else if (row.at(2) == "aa-scale") {
            const int scale = aaScale > 0 ? aaScale : 125;
            button("−", left + usable - 280, rowY + 6, 48, 44,
                   "aa-scale:" + QString::number(std::max(100, scale - 25)), 20);
            centeredText(QString::number(scale) + "%", left + usable - 148, rowY + 28, 16, "regular", true);
            button("＋", left + usable - 64, rowY + 6, 48, 44,
                   "aa-scale:" + QString::number(std::min(200, scale + 25)), 20);
        } else if (row.at(2) == "render-scale") {
            // 固定档位表：按表前进/后退，避免固定步长在 90 与 100 之间跳跃。
            static const int steps[] = {50, 60, 75, 90, 100};
            constexpr int count = 5;
            const int scale = renderScale > 0 ? renderScale : 100;
            int index = count - 1;
            for (int i = 0; i < count; ++i) {
                if (steps[i] == scale) {
                    index = i;
                    break;
                }
            }
            button("−", left + usable - 280, rowY + 6, 48, 44,
                   "render-scale:" + QString::number(steps[std::max(0, index - 1)]), 20);
            centeredText(scale == 100 ? QString("100% · 原生") : QString::number(scale) + "%",
                         left + usable - 148, rowY + 28, 16, "regular", true);
            button("＋", left + usable - 64, rowY + 6, 48, 44,
                   "render-scale:" + QString::number(steps[std::min(count - 1, index + 1)]), 20);
        } else if (row.at(2) == "archive-mask") {
            button("−", left + usable - 280, rowY + 6, 48, 44,
                   "archive-mask:" + QString::number(std::max(0, archiveMaskStrength - 10)), 20);
            const auto label =
                archiveMaskStrength == 0 ? QString("0 · 关闭") : QString::number(archiveMaskStrength) + "%";
            centeredText(label, left + usable - 148, rowY + 28, 16, "regular", true);
            button("＋", left + usable - 64, rowY + 6, 48, 44,
                   "archive-mask:" + QString::number(std::min(100, archiveMaskStrength + 10)), 20);
        } else if (unavailable) {
            text(row.at(1), left + usable - 280, rowY + 16, 16, "regular", 0, rowInk);
        } else {
            button(row.at(1), left + usable - 280, rowY + 6, 264, 44, row.at(2), 16);
        }
    }
    const auto enterHint = m_host->preference("detail-autoplay") == "on" ? "ENTER 查看并播放" : "ENTER 查看";
    text("↑ ↓ 选曲 / " + QString(enterHint) + " / " + m_host->modifierKey() + " ENTER 播放 / ESC 返回", left,
         y + performanceTop - 64, 15);
    rule(left, y + performanceTop - 20, usable, 0.2);
    text("PERFORMANCE / 性能与诊断", left, y + performanceTop, 16, "demibold");
    fill(left, y + performanceTop + 40, usable, 56, tint);
    text("帧数显示 / 性能面板", left + 16, y + performanceTop + 58, 18, "demibold");
    button("显示 / 隐藏 · F10", left + usable - 280, y + performanceTop + 46, 264, 44, "performance:toggle",
           16);
    text("在性能面板内手动收集、导出诊断文件。", left, y + performanceTop + 112, 15);
    fill(left, y + performanceTop + 160, usable, 56, tint);
    text("DISC ROTATION / 唱片旋转", left + 16, y + performanceTop + 178, 18, "demibold");
    button(discRotation ? "开启 / 点击关闭" : "关闭 / 点击了解风险", left + usable - 280,
           y + performanceTop + 166, 264, 44, "disc-rotation", 16);
    text("默认关闭；开启会增加持续渲染、耗电和发热。", left, y + performanceTop + 232, 15);
    rule(left, y + updateTop - 20, usable, 0.2);
    text("SOFTWARE UPDATE / 软件更新", left, y + updateTop, 16, "demibold");
    const auto &updater = m_host->updater;
    const auto buildLabel = RHINE_RELEASE_BUILD ? QString() : QString(" · 开发版");
    limited("当前版本 / " + AppUpdater::currentVersion() + buildLabel, left, y + updateTop + 42, 18,
            usable - 300, "demibold");
    if (!RHINE_RELEASE_BUILD) {
        limited(AppUpdater::commitTitle(), left, y + updateTop + 74, 15, usable);
    }
    button(m_host->preference("auto-update") == "off" ? "启动检查 / 关闭" : "启动检查 / 开启",
           left + usable - 280, y + updateTop + 30, 264, 44, "update:auto", 16);
    limited(updater.status(), left, y + updateTop + 104, 16, usable);
    button(updater.busy() ? "取消" : "检查更新", left, y + updateTop + 148, 160, 44,
           updater.busy() ? "update:cancel" : "update:check", 16);
    if (!updater.busy() && updater.available()) {
        button("前往更新 ↗", left + 176, y + updateTop + 148, 200, 44, "update:release", 16);
    }
    button("发布说明 ↗", left + usable - 200, y + updateTop + 148, 200, 44, "update:release", 16);
    text("更新将打开 GitHub 发布页面，请在浏览器中下载并安装。", left, y + updateTop + 220, 15);
    rule(left, y + projectTop - 20, usable, 0.2);
    text("PROJECT / 项目与开源参考", left, y + projectTop, 16, "demibold");
    const QVector<QPair<QString, QString>> links{{"本项目 / Rhine Music Database ↗", "project-home"},
                                                 {"网易云音乐 API / api-enhanced ↗", "project-author"},
                                                 {"QQ 音乐 API / qq-music-api ↗", "project-player"},
                                                 {"酷狗音乐 API / KuGouMusicApi ↗", "project-kugou"},
                                                 {"界面原项目 / RhineLabUI ↗", "project-rhine"},
                                                 {"歌词参考 / LyricsX ↗", "project-lyricsx"},
                                                 {"格式移植 / LyricsKit ↗", "project-lyricskit"},
                                                 {"同步与匹配参考 / Lyrimuse ↗", "project-lyrimuse"}};
    constexpr double linkGap = 16;
    const auto linkWidth = (usable - linkGap) / 2;
    for (int index = 0; index < links.size(); ++index) {
        button(links.at(index).first, left + (index % 2) * (linkWidth + linkGap),
               y + projectTop + 48 + (index / 2) * 54, linkWidth, 44, "music:" + links.at(index).second, 16);
    }
    restore();
    // QML 的透明输入层不会继承绘制裁切，必须同步裁剪命中区域，避免隐藏按钮拦截点击。
    QJsonArray clippedHits;
    for (qsizetype index = 0; index < hits.size(); ++index) {
        auto entry = hits.at(index).toObject();
        if (index >= firstHit) {
            const QRectF area(entry["x"].toDouble(), entry["y"].toDouble(), entry["width"].toDouble(),
                              entry["height"].toDouble());
            const auto visible = area.intersected(viewport);
            if (visible.isEmpty()) {
                continue;
            }
            entry["x"] = visible.x();
            entry["y"] = visible.y();
            entry["width"] = visible.width();
            entry["height"] = visible.height();
        }
        clippedHits.append(entry);
    }
    hits = clippedHits;
    const auto railX = x + width - 24;
    const auto railTop = originalY + SettingsViewportTop + 30;
    const auto railHeight = viewport.height() - 60;
    const auto thumbHeight = railHeight * viewport.height() / (settingsContentBottom - SettingsViewportTop);
    fill(railX, railTop, 3, railHeight, dark ? QJsonArray{1, 1, 1, 0.1} : QJsonArray{0, 0, 0, 0.1});
    fill(railX, railTop + settingsScroll / settingsScrollMaximum() * (railHeight - thumbHeight), 3,
         thumbHeight, dark ? QJsonArray{1, 1, 1, 0.45} : QJsonArray{0, 0, 0, 0.4});
    button("↑", railX - 10, originalY + SettingsViewportTop, 23, 25, "settings:scroll-up", 14);
    button("↓", railX - 10, originalY + SettingsViewportBottom - 25, 23, 25, "settings:scroll-down", 14);
}
