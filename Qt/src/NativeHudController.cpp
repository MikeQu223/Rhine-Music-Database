#include "fg/FgConfig.h"
#include "GraphicsBackend.h"
#include "NativeHud.h"
#include "MusicData.h"
#include "MusicDiscover.h"
#include <QJsonDocument>
#include <QPointer>
#include <QUrl>
#include <algorithm>
#include <cmath>

namespace {
int wrap(int value, int count) {
    return count > 0 ? (value % count + count) % count : 0;
}

QString cycle(const QStringList &values, const QString &value) {
    return values.at(wrap(values.indexOf(value) + 1, values.size()));
}

QString decode(const QString &value) {
    return QUrl::fromPercentEncoding(value.toUtf8());
}
}

/** 建立原生界面状态与音乐通知；所有延迟动作都绑定控制器生命周期和查询代数。 */
NativeHud::NativeHud(Host *host, Glyphs *glyphs, MusicLibrary *music, HudSceneActions scene, QObject *parent)
    : QObject(parent), m_host(host), m_glyphs(glyphs), m_music(music), m_scene(std::move(scene)) {
    themeMode = host->preference("theme");
    if (themeMode.isEmpty()) {
        themeMode = "light";
    }
    dark = themeMode == "system" ? host->systemDark() : themeMode == "dark";
    reduced = host->preference("motion") == "reduced";
    startupAnimation = host->preference("startup-animation") == "on";
#ifdef Q_OS_MACOS
    // macOS 的呈现节奏由系统合成器固定，设置页不提供该开关，状态恒为关闭。
    vsync = false;
#else
    vsync = host->preference("vsync") != "off";
#endif
    discRotation = host->preference("disc-rotation") == "on";
    bool hasMaskStrength = false;
    const auto savedMaskStrength = host->preference("archive-mask-strength").toInt(&hasMaskStrength);
    if (hasMaskStrength) {
        archiveMaskStrength = std::clamp(savedMaskStrength, 0, 100);
    }
    connect(&host->updater, &AppUpdater::updateAvailable, this, [this] {
        m_music->status = "发现新版本 " + m_host->updater.latestVersion() + "，可在设置中前往发布页面更新";
    });
    connect(music, &MusicLibrary::invalidated, this, &NativeHud::finishPage);
}

void NativeHud::openModal(QString kind) {
    if (m_music->isLocal() &&
        QStringList{"login", "quality", "playlist-picker", "playlist-form"}.contains(kind)) {
        return;
    }
    if (kind == "discover" && m_music->isLocal()) {
        kind = "local";
    }
    ++m_searchGeneration;
    if (m_scene.pointer) {
        m_scene.pointer("pointercancel", 0, 0, 0);
        m_scene.pointer("pointerleave", 0, 0, 0);
    }
    modal = kind;
    closing = false;
    // 换页时收起所有下拉块，避免展开状态跨页面残留。
    expandedPreference.clear();
    motion.set(true, lastTime, reduced);
    query.clear();
    listOffset = 0;
    settingsScroll = 0;
    activeGroup.clear();
    artistTab = "songs";
    categoryPicker = false;
    categoryPage = 0;
    if (kind == "saved") {
        musicCollection = std::max(1, m_music->selectedLane);
        if (m_music->provider == "kugou" && musicCollection == 4) {
            musicCollection = 2;
        }
        if (m_music->lists[musicCollection].isEmpty()) {
            m_music->loadMoreSource(musicCollection);
        }
    }
    if (kind == "search") {
        query = m_music->keyword;
    }
}

void NativeHud::closeModal() {
    ++m_searchGeneration;
    if (modal == "login") {
        m_music->cancelLogin();
    }
    closing = true;
    motion.set(false, lastTime, reduced);
}

void NativeHud::setQuery(QString value) {
    query = value;
    listOffset = 0;
    activeGroup.clear();
    const auto token = ++m_searchGeneration;
    if (modal == "search") {
        const QPointer<NativeHud> owner(this);
        m_host->schedule(700, [owner, token, value]() {
            if (!owner || token != owner->m_searchGeneration) {
                return;
            }
            owner->m_music->search(value);
            if (owner->m_music->provider == "netease" && !owner->m_host->fromLink(value).isEmpty()) {
                owner->closeModal();
            }
        });
    }
}

void NativeHud::form(QJsonObject fields) {
    if (modal == "login" && m_music->loginMethod == "phone" && fields["account"].isString() &&
        fields["captcha"].isString() && fields["account"].toString().size() <= 100 &&
        fields["captcha"].toString().size() <= 8) {
        m_music->captchaLogin(fields["account"].toString(), fields["captcha"].toString());
    }
    if (modal == "playlist-form" && fields["name"].isString()) {
        const QPointer<NativeHud> owner(this);
        const auto token = m_searchGeneration;
        m_music->playlistForm(formKind, fields["name"].toString(), formPID, [owner, token](bool ok) {
            if (ok && owner && owner->m_searchGeneration == token && owner->modal == "playlist-form") {
                owner->closeModal();
            }
        });
    }
}

/** 查询分组只缓存当前修订；原始索引保留给资料库选择，合唱曲目可进入多个组。 */
QVector<NativeHud::Row> NativeHud::rows(int lane) {
    if (lane < 0 || lane >= 5) {
        return {};
    }
    const auto filter = modal == "saved" ? query.toLower() : QString();
    const auto key =
        QString::fromUtf8(QJsonDocument(QJsonArray{lane, double(m_music->revision),
                                                   m_music->lists[lane].size(), filter, groupBy, activeGroup})
                              .toJson(QJsonDocument::Compact));
    if (key == m_rowsKey) {
        return m_rows;
    }
    QVector<Row> values;
    for (int index = 0; index < m_music->lists[lane].size(); ++index) {
        const auto value = m_music->lists[lane].at(index).toObject();
        const auto title = value["title"].toString() + value["artist"].toString() + value["id"].toString();
        if (filter.isEmpty() || title.toLower().contains(filter)) {
            values.append({index, value, {}});
        }
    }
    const bool songs = std::any_of(values.cbegin(), values.cend(),
                                   [](const Row &row) { return row.value["kind"] == "song"; });
    if (groupBy != "none" && songs) {
        QVector<Row> groups;
        QVector<QVector<Row>> entries;
        QHash<QString, int> indices;
        for (const auto &row : values) {
            const auto value = row.value;
            if (value["kind"] != "song") {
                continue;
            }
            QVector<QPair<QString, QString>> labels;
            if (groupBy == "artist") {
                for (const auto &entry : value["artists"].toArray()) {
                    const auto artist = entry.toObject();
                    const auto id = artist["id"].toString();
                    const auto name = artist["name"].toString();
                    labels.append({id.isEmpty() ? "name:" + name : "artist:" + id, name});
                }
                if (labels.isEmpty()) {
                    auto name = value["artist"].toString();
                    labels.append({"name:" + name, name.isEmpty() ? "未知歌手" : name});
                }
            } else {
                const auto id = value["albumID"].toString();
                const auto album = value["album"].toString();
                labels.append({id.isEmpty() ? "album-name:" + album : "album:" + id,
                               album.isEmpty() ? "未知专辑" : album});
            }
            QSet<QString> seen;
            for (const auto &[label, title] : labels) {
                if (seen.contains(label)) {
                    continue;
                }
                seen.insert(label);
                if (!indices.contains(label)) {
                    indices.insert(label, groups.size());
                    groups.append(
                        {-1,
                         {{"kind", "group"}, {"key", label}, {"title", title}, {"album", "点击展开分组"}},
                         {}});
                    entries.append(QVector<Row>{});
                }
                const auto index = indices[label];
                entries[index].append(row);
                groups[index].indices.append(row.index);
            }
        }
        for (auto &group : groups) {
            group.value["id"] = QString::number(group.indices.size());
            group.value["artist"] = QString::number(group.indices.size()) + " 首已载入";
        }
        if (activeGroup.isEmpty()) {
            values = groups;
        } else {
            values = entries.value(indices.value(activeGroup, -1));
            if (m_music->groupLane == lane) {
                m_music->groupIndices.clear();
                for (const auto &row : values) {
                    m_music->groupIndices.append(row.index);
                }
            }
        }
    }
    m_rowsKey = key;
    m_rows = values;
    return values;
}

/** 分页等待音乐状态通知；弹窗、来源或查询变化后丢弃原来的翻页目标。 */
void NativeHud::pageResults(int direction) {
    if (closing || !QStringList{"search", "saved"}.contains(modal)) {
        return;
    }
    const auto lane = modal == "saved" ? musicCollection : 0;
    const auto desired = std::max(0, listOffset + direction * 5);
    m_page = Page{modal, lane, m_searchGeneration, desired};
    if (direction > 0 && desired > std::max(0, int(rows(lane).size()) - 5) && m_music->hasMore[lane] &&
        !m_music->sourceLoading()) {
        m_music->loadMoreSource(lane);
    }
    finishPage();
}

void NativeHud::finishPage() {
    if (!m_page) {
        return;
    }
    const auto page = *m_page;
    if (modal != page.modal || closing || m_searchGeneration != page.generation ||
        (modal == "saved" && page.lane != musicCollection)) {
        m_page.reset();
        return;
    }
    if (m_music->sourceLoading()) {
        return;
    }
    m_page.reset();
    listOffset = std::min(page.desired, std::max(0, int(rows(page.lane).size()) - 5));
}

void NativeHud::playerAction(const QStringList &parts) {
    auto &music = *m_music;
    auto &player = music.player;
    const auto name = parts.value(1);
    const auto value = parts.value(2).toDouble();
    const auto index = int(value);
    if (name == "lyrics") {
        if (!player.current.isEmpty()) {
            modal.clear();
            closing = false;
            lyricsMode = true;
            m_lyricsBrowse.reset();
            music.followPlayback(player.current);
            m_scene.mode("detail");
            frame["mode"] = "detail";
        }
    } else if (name == "lyrics-close") {
        lyricsMode = false;
    } else if (name == "lyrics-follow") {
        m_lyricsBrowse.reset();
    } else if (name == "lyrics-offset") {
        if (modal == "lyrics-offset" && !closing) {
            closeModal();
        } else {
            openModal("lyrics-offset");
        }
    } else if (name == "lyrics-earlier" || name == "lyrics-later") {
        player.lyrics.adjustOffset(name == "lyrics-earlier" ? 200 : -200);
    } else if (name == "lyrics-reset") {
        player.lyrics.resetOffset();
    } else if (name == "lyrics-apply-global") {
        player.lyrics.applyGlobalOffset();
    } else if (name == "lyrics-sources" && music.isLocal() && player.current.value("provider") == "local") {
        if (modal == "lyrics-source" && !closing) {
            closeModal();
        } else {
            openModal("lyrics-source");
        }
    } else if (name == "lyrics-source" && music.isLocal()) {
        player.lyrics.selectLocalSource(player.current, parts.value(2));
        m_lyricsBrowse.reset();
        closeModal();
    } else if (name == "lyrics-retry") {
        if (!player.current.isEmpty()) {
            player.lyrics.load(player.current, true);
        }
    } else if (name == "lyric-line") {
        const auto document = player.lyrics.document();
        const auto lines = document["lines"].toArray();
        if (index >= 0 && index < lines.size() && player.state["seekable"].toBool()) {
            const auto position = lines.at(index).toObject()["startMs"].toDouble() -
                                  document["offsetMs"].toDouble() - player.lyrics.offsetMs;
            m_host->mediaControl("seek", std::clamp(position, 0.0, player.state["duration"].toDouble()));
            m_lyricsBrowse.reset();
        }
    } else if (name == "open") {
        if (modal == "player" && !closing) {
            closeModal();
        } else {
            openModal("player");
        }
    } else if (name == "toggle") {
        player.toggle();
    } else if (name == "prev" || name == "next") {
        player.next(name == "prev" ? -1 : 1);
    } else if (name == "seek" || name == "seek-fraction") {
        player.seek(name == "seek" ? value / 20 : value);
    } else if (name == "volume" || name == "volume-fraction") {
        player.volume(name == "volume" ? value / 10 : value);
    } else if (name == "mode") {
        player.mode = cycle({"off", "all", "one", "shuffle"}, player.mode);
    } else if (name == "queue") {
        if (index >= 0 && index < player.queue.size()) {
            player.play(player.queue.at(index).toObject(), std::nullopt, index);
        }
    } else if (name == "remove") {
        player.remove(index);
    } else if (name == "clear") {
        player.clearUpcoming();
    } else if (name == "official") {
        music.playOfficial(player.current);
    }
}

/** 动作字符串保持原有输入协议，控制器直接更新原生音乐状态和场景。 */
void NativeHud::action(QString value) {
    if ((!PlatformFeatures::LocalMusic && (value.startsWith("local:") || value == "provider:local")) ||
        (!PlatformFeatures::OfficialPlayback &&
         (value == "music:official" || value == "player:official" || value == "music:activate")) ||
        (!PlatformFeatures::ApplicationVolume && value.startsWith("player:volume"))) {
        return;
    }
    if (modal == "settings" && !closing &&
        (value == "settings:scroll-up" || value == "settings:scroll-down")) {
        const auto movement = value == "settings:scroll-down" ? 120. : -120.;
        settingsScroll = std::clamp(settingsScroll + movement, 0., settingsScrollMaximum());
        return;
    }

    if (value.startsWith("update:")) {
        auto &updater = m_host->updater;
        if (value == "update:check") {
            updater.check();
        } else if (value == "update:cancel") {
            updater.cancel();
        } else if (value == "update:release") {
            updater.openRelease();
        } else if (value == "update:auto") {
            const bool enabled = m_host->preference("auto-update") != "off";
            m_host->setPreference("auto-update", enabled ? "off" : "on");
        }
        return;
    }
    auto &music = *m_music;
    const auto parts = value.split(':');
    if (value == "detail:copy") {
        if (music.current.value("kind") == "song" && (tab == "overview" || tab == "notes")) {
            // 复制详情
            m_host->copy(body());
        }
        return;
    }
    if (value == "archive:tab-mode") {
        if (modal.isEmpty() && supportsTrackList()) {
            trackListMode = !trackListMode;
        }
        return;
    }
    if (value.startsWith("tab:")) {
        trackOffset = 0;
        bodyOffset = 0;
        tab = value.mid(4);
        if (music.current.value("kind") == "song" && tab != "overview") {
            music.sameAlbum();
        }
        return;
    }
    if (value == "provider") {
        openModal("provider");
        return;
    }
    if (value.startsWith("provider:")) {
        const auto provider = value.mid(9);
        if (music.provider != provider) {
            ++m_searchGeneration;
            activeGroup.clear();
            query.clear();
            listOffset = 0;
            trackOffset = 0;
            music.switchProvider(provider);
        }
        return;
    }
    if (value == "confirm:yes") {
        const auto run = std::exchange(m_confirm, {});
        closeModal();
        if (run) {
            run();
        }
        return;
    }
    if (value.startsWith("local:") && music.isLocal()) {
        const auto name = parts.value(1);
        const auto roots = music.local->roots();
        if ((name == "folder" || name == "files") && !music.local->busy) {
            emit localImportRequested(name == "folder");
        } else if (name == "rescan") {
            music.local->rescan();
        } else if (name == "cancel") {
            music.local->cancel();
        } else if (name == "remove") {
            const auto index = parts.value(2).toInt();
            if (index >= 0 && index < roots.size()) {
                confirmTitle = "移除索引：" + roots.at(index).toObject()["name"].toString();
                const QPointer<MusicLibrary> owner(&music);
                // 回调跨越确认面板的生命周期，必须复制字符串，不能捕获临时 JSON 字段引用。
                const auto path = roots.at(index).toObject()["path"].toString();
                m_confirm = [owner, path] {
                    if (!owner || !owner->isLocal()) {
                        return;
                    }
                    const auto current = owner->local->roots();
                    for (int index = 0; index < current.size(); ++index) {
                        if (current.at(index).toObject()["path"] == path) {
                            owner->local->removeRoot(index);
                            break;
                        }
                    }
                };
                openModal("confirm");
            }
        } else if (name == "browse") {
            music.showSource(1);
            closeModal();
        } else if (name == "prev" || name == "next") {
            listOffset =
                std::clamp(listOffset + (name == "prev" ? -4 : 4), 0, std::max(0, int(roots.size()) - 4));
        }
        return;
    }
    if (music.isLocal() &&
        (value.startsWith("discover:") || value.startsWith("quality") || value == "alternative")) {
        return;
    }
    if (value.startsWith("discover:")) {
        auto &discover = *music.discover;
        const auto name = parts.value(1);
        if (name == "tab") {
            listOffset = 0;
            categoryPicker = false;
            categoryPage = 0;
            discover.load(parts.value(2));
            if (parts.value(2) == "categories" && discover.categories.isEmpty()) {
                discover.loadCategories();
            }
        } else if (name == "item") {
            discover.open(parts.value(2).toInt());
            closeModal();
        } else if (name == "open") {
            if (music.openDaily()) {
                closeModal();
            }
        } else if (name == "area" && music.provider == "qq") {
            listOffset = 0;
            discover.newSongArea = parts.value(2);
            discover.load("new-songs");
        } else if (name == "categories") {
            categoryPicker = !categoryPicker;
            categoryPage = 0;
            if (categoryPicker && discover.categories.size() <= 1) {
                discover.loadCategories();
            }
        } else if (name == "category-page") {
            const auto pages =
                std::max(1, (int(discover.categories.size()) + CategoryPageSize - 1) / CategoryPageSize);
            const auto step = parts.value(2) == "prev" ? -1 : 1;
            categoryPage = std::clamp(categoryPage + step, 0, pages - 1);
        } else if (name == "category") {
            listOffset = 0;
            categoryPicker = false;
            discover.category = decode(parts.value(2));
            discover.load("categories");
        } else if (name == "more") {
            discover.load(discover.tab, true);
        } else if (name == "prev" || name == "next") {
            const auto maximum = std::max(0, int(discover.items.size()) - 6);
            listOffset = std::clamp(listOffset + (name == "prev" ? -6 : 6), 0, maximum);
        }
        return;
    }
    if (value.startsWith("player:")) {
        playerAction(parts);
        return;
    }
    if (value == "open") {
        if (music.current.isEmpty() && !music.directory && music.selectedLane == 0) {
            openModal("search");
        } else if (!music.current.isEmpty()) {
            if (music.current.value("kind") != "song") {
                music.enterDirectory(music.current);
            } else {
                m_scene.mode("detail");
                music.loadSongWiki();
                if (m_host->preference("detail-autoplay") == "on") {
                    // 自动播放不触发“替换播放列表”
                    music.play(false);
                }
            }
        }
        return;
    }
    if (value == "back") {
        lyricsMode = false;
        if (music.directory) {
            if (frame["mode"] == "detail") {
                music.returnToDirectory();
            } else {
                music.leaveDirectory();
            }
            return;
        }
    }
    if ((value == "column-prev" || value == "column-next") && music.directory) {
        music.navigateDirectory(value == "column-next" ? 8 : -8);
        return;
    }
    if (value == "prev" || value == "next") {
        music.next(value == "next" ? 1 : -1);
        return;
    }
    if (value == "column-prev" || value == "column-next") {
        const auto sources = music.sourceOrder();
        const auto index = sources.indexOf(music.selectedLane);
        music.showSource(sources.at(wrap(index + (value == "column-next" ? 1 : -1), sources.size())));
        return;
    }
    if (value.startsWith("music:")) {
        musicAction(parts, value);
        return;
    }
    if (value.startsWith("viewer:")) {
        m_scene.viewer(value.mid(7));
        return;
    }
    if (value == "discover") {
        openModal("discover");
        if (!music.isLocal()) {
            music.discover->load();
        }
    } else if (value == "skip" || value == "back") {
        m_scene.mode("archive");
    } else if (QStringList{"search", "saved", "settings"}.contains(value)) {
        openModal(value);
    } else if (value == "close-modal") {
        closeModal();
    } else if (value == "viewer") {
        m_scene.openViewer();
    } else if (value == "replay") {
        if (!modal.isEmpty()) {
            closeModal();
        }
        m_scene.mode("boot");
    } else if (value == "alternative") {
        music.player.alternative = !music.player.alternative;
        m_host->setPreference("alternate-source", music.player.alternative ? "on" : "off");
    } else if (value == "quality") {
        QStringList qualities;
        for (const auto &option : MusicPlayer::qualityOptions(music.provider)) {
            qualities.append(option.first);
        }
        music.player.setQuality(cycle(qualities, music.player.quality));
    } else if (value == "quality:open") {
        openModal("quality");
    } else if (value.startsWith("quality:set:")) {
        music.player.setQuality(value.mid(12));
    } else if (value == "disc-rotation") {
        if (discRotation) {
            discRotation = false;
            m_host->setPreference("disc-rotation", "off");
        } else {
            openModal("disc-rotation-warning");
        }
    } else if (value == "disc-rotation:enable") {
        discRotation = true;
        m_host->setPreference("disc-rotation", "on");
        openModal("settings");
    } else if (value == "disc-rotation:cancel") {
        openModal("settings");
    } else if (value == "theme") {
        themeMode = cycle({"light", "dark", "system"}, themeMode);
        dark = themeMode == "system" ? m_host->systemDark() : themeMode == "dark";
        m_scene.theme(dark);
        m_host->setPreference("theme", themeMode);
    } else if (value.startsWith("archive-mask:")) {
        bool valid = false;
        const auto strength = value.mid(13).toInt(&valid);
        if (valid) {
            archiveMaskStrength = std::clamp(strength, 0, 100);
            m_host->setPreference("archive-mask-strength", QString::number(archiveMaskStrength));
        }
    } else if (value == "detail-autoplay") {
        const bool enabled = m_host->preference("detail-autoplay") == "on";
        m_host->setPreference("detail-autoplay", enabled ? "off" : "on");
    // 【功能暂未完成】Filament 开关已从设置界面移除，此处一并停用。
    // } else if (value == "filament") {
    //     与后端切换一致：只写配置，由下次启动的 resolveConfig 应用；失败码另行记录。
    //     const auto current = m_host->preference("filament");
    //     m_host->setPreference("filament", current == "on" ? QString() : QStringLiteral("on"));
    } else if (value == "graphics-backend") {
        // 后端切换需要重启生效：仅写入配置，由下次启动的 selectGraphicsBackend 应用。
        // 顺序：默认（自动探测）→ Vulkan → OpenGL → 默认
        const auto current = m_host->preference("graphics-backend");
        QString next;
        if (current.isEmpty()) {
            next = QStringLiteral("vulkan");
        } else if (current == "vulkan") {
            next = QStringLiteral("opengl");
#if defined(Q_OS_WIN) && RHINE_ENABLE_D3D12_BACKEND
        } else if (current == "opengl") {
            next = QStringLiteral("d3d12");
#endif
        }
        m_host->setPreference("graphics-backend", next);
    } else if (value.startsWith("gpu-index:")) {
#if defined(Q_OS_LINUX)
        // Linux 显卡选择：只写配置，下次启动由 initializeLinuxGraphics 校验序号并注入
        // 驱动变量。"default" 表示清回默认——清空后启动不再注入任何厂商变量。
        // 序号越界就丢弃：界面上本来不会出现这种项，防的是配置被外部改坏后传到启动侧。
        const auto chosen = value.mid(10).trimmed();
        bool numeric = false;
        const int index = chosen.toInt(&numeric);
        const int gpuCount = RhineGraphics::gpuDeviceCount();
        if (chosen == QLatin1String("default")) {
            m_host->setPreference("gpu-index", QString());
        } else if (numeric && index >= 0 && index < gpuCount) {
            m_host->setPreference("gpu-index", QString::number(index));
        }
        expandedPreference.clear();
#endif
    } else if (value.startsWith("expand:")) {
        // 设置页下拉块：点标题行展开/收起对应选项列表（抗锯齿与 FSR 档位共用）。
        // 列表高度参与内容总高度，所以展开后立即重新夹紧滚动位置，避免停在超出末尾的位置。
        const auto key = value.mid(7);
        expandedPreference = expandedPreference == key ? QString() : key;
        settingsScroll = std::clamp(settingsScroll, 0., std::max(0., settingsScrollMaximum()));
    } else if (value.startsWith("fsr-quality:")) {
        // FSR 超分档位：渲染器每帧读取，下一帧生效（内部尺寸变化会触发渲染目标重建）。
        const auto quality = value.mid(12);
        if (quality == "super" || quality == "performance" || quality == "balanced" || quality == "quality" ||
            quality == "native") {
            m_host->setPreference("fsr-quality", quality);
            qputenv("RHINE_FSR_QUALITY", quality.toUtf8());
            expandedPreference.clear();
        }
    } else if (value.startsWith("fsr-sharpness:")) {
        // 锐化强度 0–100，逐帧生效：FSR1 换算成 RCAS 的档，FSR3 直接取 0–1。
        bool valid = false;
        const auto percent = value.mid(14).toInt(&valid);
        if (valid) {
            const auto clamped = std::clamp(percent, 0, 100);
            m_host->setPreference("fsr-sharpness", QString::number(clamped));
            qputenv("RHINE_FSR_SHARPNESS", QByteArray::number(clamped));
        }
    } else if (value.startsWith("aa-mode:")) {
        // 抗锯齿互斥单选，渲染器每帧读取该环境变量，切换后下一帧生效。
        const auto mode = value.mid(8);
        // fsr 是合并后的唯一超分选项；fsr1 / fsr3 仍接受，兼容旧偏好。
        if (mode == "off" || mode == "fxaa" || mode == "ssaa" || mode == "msaa" || mode == "taa" ||
            mode == "fsr" || mode == "fsr1" || mode == "fsr3"
#ifdef Q_OS_MACOS
            || mode == "metalfx"
#endif
        ) {
            m_host->setPreference("aa-mode", mode);
            qputenv("RHINE_AA_MODE", mode.toUtf8());
            // 选中即收起，与原生下拉菜单的行为一致。
            expandedPreference.clear();
        }
    } else if (value.startsWith("msaa:")) {
        // MSAA 采样数：渲染器每帧读取，改变会触发渲染目标重建，不需要重启。
        bool valid = false;
        const auto samples = value.mid(5).toInt(&valid);
        if (valid && (samples == 2 || samples == 4 || samples == 8)) {
            m_host->setPreference("msaa", QString::number(samples));
            qputenv("RHINE_MSAA", QByteArray::number(samples));
        }
    } else if (value.startsWith("aa-scale:")) {
        bool valid = false;
        const auto percent = value.mid(9).toInt(&valid);
        if (valid) {
            const auto clamped = std::clamp(percent, 100, 200);
            m_host->setPreference("aa-scale", QString::number(clamped));
            qputenv("RHINE_AA_SCALE", QByteArray::number(clamped));
        }
    } else if (value.startsWith("render-scale:")) {
        // 渲染分辨率重启生效：内部目标按百分比创建，最终合成通道再缩放回窗口。
        // 小于 100 换帧率，大于 100 是超采样换抗锯齿。
        bool valid = false;
        const auto percent = value.mid(13).toInt(&valid);
        if (valid) {
            const auto clamped = std::clamp(percent, 50, 100);
            m_host->setPreference("render-scale", QString::number(clamped));
            // 渲染器每帧读取该环境变量，改完下一帧即生效，不需要重启。
            qputenv("RHINE_RENDER_SCALE", QByteArray::number(clamped));
        }
    } else if (value == "fg") {
        // 帧生成与抗锯齿模式互不影响；呈现层每帧读取 RHINE_FG，切换后下一帧生效，
        // 所以这个开关是设置页里唯一不需要重启的偏好。转换规则与 Host::setPreference
        // 共用同一个函数，免得两处对"什么才算 on"产生分歧。
        const auto enabled = m_host->preference("fg") == "on";
        const auto next = enabled ? QStringLiteral("off") : QStringLiteral("on");
        m_host->setPreference("fg", next);
        RhineFg::applyInterpolationPreference(next);
    } else if (value == "single-play-mode") {
        const bool append = m_host->preference("single-play-mode") == "append";
        m_host->setPreference("single-play-mode", append ? "replace" : "append");
    } else if (value == "startup-animation") {
        startupAnimation = !startupAnimation;
        m_host->setPreference("startup-animation", startupAnimation ? "on" : "off");
    } else if (value == "vsync") {
#ifdef Q_OS_MACOS
        // macOS 固定关闭垂直同步，设置页不显示该行；外部动作也不改变任何状态。
#else
        vsync = !vsync;
        m_host->setPreference("vsync", vsync ? "on" : "off");
#endif
    } else if (value == "motion") {
        reduced = !reduced;
        m_scene.reduced(reduced);
        m_host->setPreference("motion", reduced ? "reduced" : "full");
    }
}

void NativeHud::key(QString value, bool command) {
    if (frame.isEmpty()) {
        return;
    }
    if (modal == "settings" && !closing && (value == "ArrowDown" || value == "ArrowUp")) {
        const auto movement = value == "ArrowDown" ? 50. : -50.;
        settingsScroll = std::clamp(settingsScroll + movement, 0., settingsScrollMaximum());
        return;
    }
    if (value == "Enter" && command) {
        m_music->play();
        return;
    }
    if (frame["viewer"].toBool()) {
        m_scene.viewerKey(value);
        return;
    }
    if (value == "Escape") {
        action(modal.isEmpty() ? "back" : "close-modal");
        return;
    }
    if (!modal.isEmpty()) {
        return;
    }
    if (value == "Tab" && !command) {
        action("archive:tab-mode");
        return;
    }
    if (value == " ") {
        m_music->player.toggle();
        return;
    }
    static const QHash<QString, QString> actions{{"ArrowLeft", "column-prev"},
                                                 {"ArrowRight", "column-next"},
                                                 {"ArrowUp", "prev"},
                                                 {"ArrowDown", "next"},
                                                 {"Enter", "open"},
                                                 {"/", "search"}};
    if (actions.contains(value)) {
        action(actions[value]);
    }
}

bool NativeHud::supportsTrackList() const {
    return modal.isEmpty() && frame["mode"] == "archive" && !frame["viewer"].toBool() && !lyricsMode &&
           m_music->current.value("kind") == "song";
}

bool NativeHud::animating(double time) const {
    if (reduced) {
        return !motion.finished() || closing;
    }
    const bool lyrics = lyricsMode && modal.isEmpty() && m_lyricsCurve &&
                        time - m_lyricsCurve->start < m_lyricsCurve->duration;
    const bool trackList = trackListMode && frame["mode"] == "archive" && modal.isEmpty() &&
                           m_trackListCurve && time - m_trackListCurve->start < m_trackListCurve->duration;
    if (!motion.finished() || lyrics || trackList || closing || time - m_resultStart < 0.5) {
        return true;
    }
    return std::any_of(m_rolling.cbegin(), m_rolling.cend(),
                       [time](const auto &entry) { return entry.second.active(time); });
}
