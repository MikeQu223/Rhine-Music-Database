#include "NativeHud.h"
#include "AppUpdater.h"
#include "Host.h"
#include "MusicLibrary.h"
#include "MusicPlayer.h"
#include "SettingsCard.h"
#include "SettingsSchema.h"
#include <QHash>
#include <algorithm>

namespace {
// 图标
constexpr auto AppleMusicIcon =
    R"(M 23.994 6.124 C 24.002 5.387 23.921 4.652 23.754 3.934 C 23.437 2.624 22.692 1.624 21.574 0.891 C 21.004 0.525 20.365 0.278 19.697 0.165 C 19.18 0.076 18.657 0.026 18.133 0.015 C 18.093 0.012 18.05 0.005 18.009 0.002 L 5.986 0.002 C 5.834 0.012 5.683 0.019 5.531 0.028 C 4.784 0.071 4.041 0.151 3.338 0.428 C 2.002 0.958 1.038 1.88 0.473 3.208 C 0.281 3.656 0.181 4.133 0.11 4.616 C 0.054 5.008 0.022 5.401 0.01 5.796 C 0.01 5.828 0.003 5.858 0 5.889 L 0 18.112 C 0.01 18.252 0.017 18.395 0.027 18.536 C 0.077 19.351 0.181 20.16 0.524 20.909 C 1.174 22.329 2.262 23.262 3.758 23.71 C 4.178 23.837 4.614 23.897 5.051 23.938 C 5.606 23.991 6.161 23.998 6.718 23.998 L 17.748 23.998 C 18.273 23.998 18.797 23.964 19.318 23.898 C 20.14 23.792 20.914 23.548 21.613 23.088 C 22.442 22.552 23.096 21.785 23.493 20.881 C 23.679 20.461 23.786 20.011 23.863 19.557 C 23.976 18.882 24.001 18.199 24 17.517 C 23.998 13.717 24 9.922 23.997 6.124 Z)";
constexpr auto AppleMusicNote =
    R"(M 17.571 10.114 L 17.571 15.826 C 17.571 16.243 17.513 16.653 17.327 17.032 C 17.037 17.622 16.567 17.994 15.939 18.172 C 15.589 18.272 15.233 18.329 14.869 18.345 C 13.919 18.39 13.096 17.745 12.926 16.809 C 12.779 15.978 13.204 15.152 13.964 14.787 C 14.287 14.627 14.634 14.537 14.982 14.463 C 15.36 14.381 15.74 14.31 16.116 14.223 C 16.39 14.16 16.573 13.993 16.626 13.707 C 16.64 13.644 16.646 13.579 16.646 13.514 C 16.646 11.699 16.646 9.884 16.644 8.071 C 16.643 8.008 16.635 7.946 16.618 7.886 C 16.578 7.736 16.468 7.643 16.314 7.652 C 16.154 7.662 15.996 7.687 15.839 7.718 C 15.079 7.868 14.319 8.021 13.559 8.174 L 11.234 8.644 L 9.86 8.922 C 9.844 8.925 9.828 8.932 9.812 8.935 C 9.535 9.012 9.435 9.138 9.422 9.425 C 9.42 9.467 9.422 9.511 9.422 9.555 C 9.42 12.157 9.422 14.759 9.419 17.36 C 9.419 17.78 9.372 18.196 9.204 18.587 C 8.926 19.227 8.434 19.627 7.77 19.82 C 7.42 19.92 7.06 19.98 6.695 19.992 C 5.735 20.028 4.94 19.392 4.775 18.448 C 4.635 17.636 5.005 16.763 5.929 16.373 C 6.286 16.223 6.659 16.141 7.037 16.063 C 7.324 16.003 7.612 15.947 7.897 15.886 C 8.28 15.803 8.48 15.563 8.497 15.172 L 8.497 15.022 C 8.497 12.062 8.497 9.1 8.499 6.14 C 8.499 6.017 8.512 5.89 8.541 5.77 C 8.611 5.485 8.814 5.322 9.087 5.252 C 9.342 5.186 9.602 5.14 9.861 5.087 C 10.594 4.937 11.327 4.791 12.061 4.643 L 14.331 4.183 C 15.001 4.049 15.671 3.913 16.341 3.78 C 16.561 3.737 16.783 3.692 17.004 3.674 C 17.314 3.649 17.527 3.844 17.558 4.156 C 17.566 4.229 17.57 4.304 17.57 4.379 C 17.572 6.289 17.572 8.201 17.57 10.111 Z)";

QJsonArray fade(const QJsonArray &color, double alpha) {
    auto value = color;
    value[3] = alpha;
    return value;
}

QVector<int> numericValues(const SettingsSchema::SettingDescriptor &descriptor) {
    if (!descriptor.steps.isEmpty()) {
        return descriptor.steps;
    }
    QVector<int> values;
    if (descriptor.step > 0) {
        for (int value = descriptor.minimum; value <= descriptor.maximum; value += descriptor.step) {
            values.append(value);
        }
    }
    return values;
}

SettingsCard::Model buildSettingsModel(const SettingsSchema::SettingsContext &context, const QRectF &viewport,
                                       double scroll, const QString &expandedId) {
    SettingsCard::Model model;
    model.viewport = viewport;
    model.scroll = scroll;
    model.expandedId = expandedId;
    for (const auto &section : SettingsSchema::sections()) {
        if (section.visible && !section.visible(context)) {
            continue;
        }
        SettingsCard::SectionModel sectionModel;
        sectionModel.meta = &section;
        if (section.customRenderer.isEmpty()) {
            for (const auto &descriptor : SettingsSchema::descriptors()) {
                if (descriptor.section != section.id || !SettingsSchema::visible(descriptor, context)) {
                    continue;
                }
                SettingsCard::RowModel row;
                row.descriptor = &descriptor;
                row.value = SettingsSchema::read(descriptor, context);
                row.label = SettingsSchema::displayLabel(descriptor, context);
                row.choices = SettingsSchema::choices(descriptor, context);
                row.targetValue = SettingsSchema::switchTarget(descriptor, context);
                row.decrementValue = SettingsSchema::nextValue(descriptor, context, -1);
                row.incrementValue = SettingsSchema::nextValue(descriptor, context, 1);
                row.numericValues = numericValues(descriptor);
                row.enabled = SettingsSchema::enabled(descriptor, context);
                row.expanded = expandedId == descriptor.id && row.enabled;
                sectionModel.rows.append(row);
            }
            std::sort(sectionModel.rows.begin(), sectionModel.rows.end(),
                      [](const SettingsCard::RowModel &left, const SettingsCard::RowModel &right) {
                          return left.descriptor->order < right.descriptor->order;
                      });
        }
        model.sections.append(sectionModel);
    }
    return model;
}
}

SettingsSchema::SettingsContext NativeHud::settingsContext() const {
    SettingsSchema::SettingsContext context;
    context.host = m_host;
    context.music = m_music;
    context.dark = dark;
    context.themeMode = themeMode;
    context.reduced = reduced;
    context.startupAnimation = startupAnimation;
    context.discRotation = discRotation;
    context.vsync = vsync;
    context.archiveMaskStrength = archiveMaskStrength;
    context.expandedId = expandedPreference;
    context.cacheMessage = cacheMessage;
    return context;
}

void NativeHud::refreshSettingsLayout() {
    if (modal != "settings") {
        return;
    }
    const auto bounds = modalBounds(width);
    const QRectF viewport(bounds.x() + 40, bounds.y() + SettingsViewportTop, bounds.width() - 80,
                          SettingsViewportBottom - SettingsViewportTop);
    const auto model = buildSettingsModel(settingsContext(), viewport, settingsScroll, expandedPreference);
    const auto layout = SettingsCard::layout(model);
    settingsContentBottom = SettingsViewportTop + layout.contentHeight;
    settingsScroll = HudScroll::clampOffset(settingsScroll, layout.contentHeight, viewport.height());
}

void NativeHud::beginSettingEdit(const QString &id) {
    const auto *descriptor = SettingsSchema::find(id);
    if (!descriptor || descriptor->kind != SettingsSchema::SettingKind::TextInput) {
        return;
    }
    const auto bounds = modalBounds(width);
    const QRectF viewport(bounds.x() + 40, bounds.y() + SettingsViewportTop, bounds.width() - 80,
                          SettingsViewportBottom - SettingsViewportTop);
    auto model = buildSettingsModel(settingsContext(), viewport, settingsScroll, expandedPreference);
    const auto layout = SettingsCard::layout(model);
    for (const auto &section : layout.sections) {
        for (const auto &row : section.rows) {
            if (row.row->descriptor->id != id || !row.row->enabled) {
                continue;
            }
            editingSettingId = id;
            editingSettingText = row.row->value.canonical;
            editingSettingRect = row.control.translated(0, -settingsScroll);
            m_host->invalidate();
            return;
        }
    }
}

void NativeHud::setSettingEditText(const QString &text) {
    if (!editingSettingId.isEmpty()) {
        editingSettingText = text;
    }
}

void NativeHud::commitSettingEdit() {
    if (editingSettingId.isEmpty()) {
        return;
    }
    const auto id = editingSettingId;
    const auto text = editingSettingText;
    editingSettingId.clear();
    editingSettingText.clear();
    editingSettingRect = QRectF();
    applySettingValue(id, text);
    refreshSettingsLayout();
    m_host->invalidate();
}

void NativeHud::cancelSettingEdit() {
    if (editingSettingId.isEmpty()) {
        return;
    }
    editingSettingId.clear();
    editingSettingText.clear();
    editingSettingRect = QRectF();
    m_host->invalidate();
}

void NativeHud::settingsPanel(double x, double y, double width) {
    const QRectF viewport(x + 40, y + SettingsViewportTop, width - 80,
                          SettingsViewportBottom - SettingsViewportTop);
    auto model = buildSettingsModel(settingsContext(), viewport, settingsScroll, expandedPreference);
    const auto layout = SettingsCard::layout(model);
    settingsContentBottom = SettingsViewportTop + layout.contentHeight;
    settingsScroll = HudScroll::clampOffset(settingsScroll, layout.contentHeight, viewport.height());
    model.scroll = settingsScroll;

    SettingsCard::Colors colors;
    colors.ink = ink();
    colors.muted = fade(colors.ink, 0.55);
    colors.faint = fade(colors.ink, 0.12);
    colors.line = fade(colors.ink, 0.25);
    colors.soft = dark ? QJsonArray{1, 1, 1, 0.05} : QJsonArray{0, 0, 0, 0.04};
    colors.gold = {0.835, 0.639, 0.282, 1};
    colors.panel = dark ? QJsonArray{0.15, 0.15, 0.15, 1} : QJsonArray{0.929, 0.922, 0.894, 1};

    SettingsCard::Canvas canvas;
    canvas.fill = [this](double left, double top, double width, double height, QJsonArray color) {
        fill(left, top, width, height, color);
    };
    canvas.text = [this](QString value, double left, double top, double size, QString weight, double tracking,
                         QJsonArray color) { text(value, left, top, size, weight, tracking, color); };
    canvas.fit = [this](QString value, double size, double width, QString weight) {
        return fit(value, size, width, weight);
    };
    canvas.hit = [this](double left, double top, double width, double height, QString action, QString label) {
        hit(left, top, width, height, action, label);
    };
    canvas.centered = [this](QString value, double x, double cy, double size, QString weight,
                             bool horizontal) { centeredText(value, x, cy, size, weight, horizontal); };
    canvas.stroke = [this](const QRectF &rect, QJsonArray color) {
        fill(rect.left(), rect.top(), rect.width(), 1, color);
        fill(rect.left(), rect.bottom() - 1, rect.width(), 1, color);
        fill(rect.left(), rect.top(), 1, rect.height(), color);
        fill(rect.right() - 1, rect.top(), 1, rect.height(), color);
    };
    canvas.custom = [this](QString renderer, const QRectF &body, double scroll) {
        paintSettingsCustomSection(renderer, body, scroll);
    };

    const auto firstHit = hits.size();
    save();
    clip(viewport.x(), viewport.y(), viewport.width(), viewport.height());
    SettingsCard::paint(model, layout, colors, canvas);
    restore();
    HudScroll::clipHits(hits, int(firstHit), viewport);

    const auto railX = x + width - 24;
    const auto railTop = y + SettingsViewportTop + 30;
    const auto railHeight = viewport.height() - 60;
    const auto track = QRectF(railX, railTop, 3, railHeight);
    const auto rail = HudScroll::rail(track, layout.contentHeight, viewport.height(), settingsScroll);
    fill(track.x(), track.y(), track.width(), track.height(),
         dark ? QJsonArray{1, 1, 1, 0.1} : QJsonArray{0, 0, 0, 0.1});
    if (rail.visible) {
        fill(rail.thumb.x(), rail.thumb.y(), rail.thumb.width(), rail.thumb.height(),
             dark ? QJsonArray{1, 1, 1, 0.45} : QJsonArray{0, 0, 0, 0.4});
    }
    button("↑", railX - 10, y + SettingsViewportTop, 23, 25, "settings:scroll-up", 14);
    button("↓", railX - 10, y + SettingsViewportBottom - 25, 23, 25, "settings:scroll-down", 14);
}

void NativeHud::paintSettingsCustomSection(const QString &renderer, const QRectF &body, double scroll) {
    Q_UNUSED(scroll);
    const auto baseInk = ink();
    const auto muted = fade(baseInk, 0.55);
    const auto line = fade(baseInk, 0.25);
    const auto soft = dark ? QJsonArray{1, 1, 1, 0.05} : QJsonArray{0, 0, 0, 0.04};
    const auto gold = QJsonArray{0.835, 0.639, 0.282, 1};
    const auto panel = dark ? QJsonArray{0.15, 0.15, 0.15, 1} : QJsonArray{0.929, 0.922, 0.894, 1};

    auto stroke = [this](const QRectF &rect, QJsonArray color) {
        fill(rect.left(), rect.top(), rect.width(), 1, color);
        fill(rect.left(), rect.bottom() - 1, rect.width(), 1, color);
        fill(rect.left(), rect.top(), 1, rect.height(), color);
        fill(rect.right() - 1, rect.top(), 1, rect.height(), color);
    };
    auto actionBlock = [this, &stroke, &soft, &line, &baseInk](const QRectF &rect, const QString &label,
                                                               const QString &action, const QString &hitLabel,
                                                               bool centeredLabel = false) {
        fill(rect.left(), rect.top(), rect.width(), rect.height(), soft);
        stroke(rect, line);
        const auto shown = fit(label, 14, rect.width() - 26, "regular");
        if (centeredLabel) {
            centeredText(shown, rect.center().x(), rect.center().y(), 14, "regular", true);
        } else {
            text(shown, rect.left() + 12, rect.top() + 15, 14, "regular", 0, baseInk);
        }
        hit(rect.left(), rect.top(), rect.width(), rect.height(), action, hitLabel);
    };

    if (renderer == "provider-card") {
        const auto card = QRectF(body.left(), body.top() + 4, body.width(), 80);
        fill(card.left(), card.top(), card.width(), card.height(), soft);
        fill(card.left(), card.top(), 3, card.height(), gold);
        const auto mark = QRectF(card.left() + 14, card.top() + 17, 46, 46);
        // 所有平台统一使用单色 Apple Music 图标，保持卡片配色一致。
        save();
        translate(mark.left(), mark.top());
        scale(mark.width() / 24, mark.height() / 24);
        op({"fill-path", QString::fromUtf8(AppleMusicIcon), baseInk});
        op({"fill-path", QString::fromUtf8(AppleMusicNote), panel});
        restore();
        text("CURRENT PROVIDER / 当前平台", card.left() + 74, card.top() + 10, 10, "regular", 0.08, muted);
        text(m_music->providerName(), card.left() + 74, card.top() + 24, 20, "demibold", -0.02, baseInk);
        text(m_music->provider.toUpper(), card.left() + 74, card.top() + 52, 10, "regular", 0.07, muted);
        const auto switchRect = QRectF(card.right() - 126, card.top() + 23, 110, 34);
        actionBlock(switchRect, QStringLiteral("切换平台 ▾"), "provider", QStringLiteral("切换平台"), true);

        QString accountLabel;
        QString accountAction;
        if (m_music->isLocal()) {
            accountLabel = QStringLiteral("文件夹管理 / 导入与索引");
            accountAction = "discover";
        } else if (m_music->isSiren()) {
            // 塞壬唱片使用官网曲库，没有账号登录入口。
            accountLabel = QStringLiteral("塞壬唱片");
        } else if (m_music->uid.isEmpty()) {
            accountLabel = QStringLiteral("登录 / ") + m_music->providerName();
            accountAction = "music:login";
        } else {
            accountLabel = QStringLiteral("退出登录 / ") + m_music->nickname;
            accountAction = "music:logout";
        }
        const auto account = QRectF(body.left(), body.top() + 98, 320, 46);
        if (accountAction.isEmpty()) {
            text(fit(accountLabel, 15, account.width(), "regular"), account.left() + 2, account.top() + 15,
                 15, "regular", 0, baseInk);
        } else {
            actionBlock(account, accountLabel, accountAction, accountLabel);
        }
        static const QHash<QString, QString> memberships{{"free", QStringLiteral("免费账号")},
                                                         {"green", QStringLiteral("绿钻会员")},
                                                         {"super", QStringLiteral("超级会员")},
                                                         {"unknown", QStringLiteral("会员状态未知")}};
        const auto note = m_music->isSiren()
                              ? QStringLiteral("官网曲库 / 无需登录")
                              : (m_music->provider == "qq" && !m_music->uid.isEmpty()
                                     ? memberships.value(m_music->vipLevel, QStringLiteral("会员状态未知"))
                                     : QStringLiteral("各平台账号独立保存"));
        text(fit(note, 12, body.right() - account.right() - 20, "regular"), account.right() + 16,
             body.top() + 114, 12, "regular", 0, muted);
        return;
    }

    if (renderer == "performance") {
        const auto row = [this, &body, &muted, &baseInk, &line, &actionBlock](
                             double top, const QString &en, const QString &zh, const QString &label,
                             const QString &action, const QString &hitLabel) {
            const auto control = QRectF(body.right() - 300, body.top() + top + 8, 300, 48);
            text(en, body.left(), body.top() + top + 10, 11, "regular", 0.08, muted);
            text(zh, body.left(), body.top() + top + 25, 17, "demibold", -0.01, baseInk);
            actionBlock(control, label, action, hitLabel);
            fill(body.left(), body.top() + top + 62, body.width(), 1, line);
        };
        row(4, "PERFORMANCE", QStringLiteral("性能面板"), QStringLiteral("显示 / 隐藏 · F10"),
            "performance:toggle", QStringLiteral("性能面板"));
        text(QStringLiteral("在性能面板内手动收集、导出诊断文件。"), body.left(), body.top() + 78, 13,
             "regular", 0, muted);
        row(102, "DISC ROTATION", QStringLiteral("唱片旋转"),
            discRotation ? QStringLiteral("开启 / 点击关闭") : QStringLiteral("关闭 / 点击了解风险"),
            "disc-rotation", QStringLiteral("唱片旋转"));
        text(QStringLiteral("默认关闭；开启会增加持续渲染、耗电和发热。"), body.left(), body.top() + 176, 13,
             "regular", 0, muted);
        return;
    }

    if (renderer == "storage") {
        const auto control = QRectF(body.right() - 300, body.top() + 8, 300, 48);
        text("STORAGE", body.left(), body.top() + 10, 11, "regular", 0.08, muted);
        text(QStringLiteral("存储与缓存"), body.left(), body.top() + 25, 17, "demibold", -0.01, baseInk);
        actionBlock(control, cacheMessage.isEmpty() ? QStringLiteral("清除缓存") : cacheMessage,
                    "cache:clear", QStringLiteral("清除缓存"));
        fill(body.left(), body.top() + 62, body.width(), 1, line);
        text(QStringLiteral("清理元数据、歌词、封面与列表缓存，保留主题和账号。"), body.left(),
             body.top() + 72, 13, "regular", 0, muted);
        return;
    }

    if (renderer == "update") {
        const auto buildLabel = RHINE_RELEASE_BUILD ? QString() : QStringLiteral(" · 开发版");
        text(QStringLiteral("当前版本 / ") + AppUpdater::currentVersion() + buildLabel, body.left(),
             body.top() + 4, 18, "demibold", 0, baseInk);
        if (!RHINE_RELEASE_BUILD) {
            text(AppUpdater::commitTitle(), body.left(), body.top() + 32, 12, "regular", 0, muted);
        }
        const auto autoUpdate = QRectF(body.right() - 300, body.top() + 50, 300, 48);
        actionBlock(autoUpdate,
                    m_host->preference("auto-update") == "off" ? QStringLiteral("启动检查 / 关闭")
                                                               : QStringLiteral("启动检查 / 开启"),
                    "update:auto", QStringLiteral("启动检查"));
        text(fit(m_host->updater.status(), 13, body.width() - 340, "regular"), body.left(), body.top() + 68,
             13, "regular", 0, muted);
        const auto check = QRectF(body.left(), body.top() + 112, 170, 46);
        actionBlock(check, m_host->updater.busy() ? QStringLiteral("取消") : QStringLiteral("检查更新"),
                    m_host->updater.busy() ? "update:cancel" : "update:check", QStringLiteral("检查更新"));
        if (!m_host->updater.busy() && m_host->updater.available()) {
            actionBlock(QRectF(body.left() + 186, body.top() + 112, 210, 46), QStringLiteral("前往更新 ↗"),
                        "update:release", QStringLiteral("前往更新"));
        }
        actionBlock(QRectF(body.right() - 210, body.top() + 112, 210, 46), QStringLiteral("发布说明 ↗"),
                    "update:release", QStringLiteral("发布说明"));
        text(QStringLiteral("更新将打开 GitHub 发布页面，请在浏览器中下载并安装。"), body.left(),
             body.top() + 176, 12, "regular", 0, muted);
        return;
    }

    if (renderer == "defaults") {
        const auto restore = QRectF(body.left(), body.top() + 6, 300, 46);
        actionBlock(restore, QStringLiteral("恢复默认设置"), "settings:restore-defaults",
                    QStringLiteral("恢复默认设置"));
        text(QStringLiteral("仅重置终端偏好，平台、账号与更新状态保持不变。"), body.left() + 316,
             body.top() + 20, 12, "regular", 0, muted);
        return;
    }
}

void NativeHud::applySettingValue(const QString &id, const QString &value) {
    const auto *descriptor = SettingsSchema::find(id);
    if (!descriptor) {
        return;
    }
    const auto context = settingsContext();
    const auto current = SettingsSchema::read(*descriptor, context);
    const auto target = SettingsSchema::normalize(*descriptor, context, value);
    if (target == current.canonical) {
        return;
    }

    // 主题需要同时更新缓存、磁盘与场景波形，不能只写偏好。
    if (id == "theme") {
        themeMode = target;
        dark = target == "dark" || (target == "system" && m_host->systemDark());
        m_host->setPreference("theme", target);
        if (m_scene.theme) {
            m_scene.theme(dark);
        }
        m_host->invalidate();
        return;
    }
    if (id == "graphics-backend") {
        m_host->setPreference("graphics-backend", target);
        m_host->invalidate();
        return;
    }
    // 二元项复用旧动作，保持托盘、播放器、场景与偏好写入的原顺序。
    if (id == "motion") {
        action("motion");
        return;
    }
    if (id == "startup-animation") {
        action("startup-animation");
        return;
    }
    if (id == "vsync") {
        action("vsync");
        return;
    }
    if (id == "detail-autoplay") {
        action("detail-autoplay");
        return;
    }
    if (id == "single-play-mode") {
        action("single-play-mode");
        return;
    }
    if (id == "close-behavior") {
        action("close-behavior");
        return;
    }
    if (id == "alternative") {
        action("alternative");
        return;
    }
    if (id == "official-player") {
        action("music:activate");
        return;
    }
    // 关闭帧生成
#if 0
    if (id == "fg") {
        action("fg");
        return;
    }
#endif
    if (id == "archive-mask") {
        action("archive-mask:" + target);
        return;
    }
    if (id == "render-scale") {
        action("render-scale:" + target);
        return;
    }
    if (id == "aa-mode") {
        action("aa-mode:" + target);
        return;
    }
    if (id == "aa-scale") {
        action("aa-scale:" + target);
        return;
    }
    if (id == "msaa") {
        action("msaa:" + target);
        return;
    }
    if (id == "fsr-quality") {
        action("fsr-quality:" + target);
        return;
    }
    if (id == "fsr-sharpness") {
        action("fsr-sharpness:" + target);
        return;
    }
    if (id == "gpu-index") {
        action("gpu-index:" + target);
        return;
    }
    if (id == "quality") {
        action("quality:set:" + target);
        return;
    }
    // 新加入的普通偏好只需 descriptor + Host key，通用路径即可持久化。
    if (descriptor->binding.kind == SettingsSchema::BindingKind::Preference) {
        m_host->setPreference(descriptor->binding.preferenceKey, target);
        m_host->invalidate();
    }
}

void NativeHud::restoreSettingsDefaults() {
    expandedPreference.clear();
    const auto context = settingsContext();
    for (const auto &descriptor : SettingsSchema::descriptors()) {
        if (descriptor.kind == SettingsSchema::SettingKind::Action ||
            descriptor.kind == SettingsSchema::SettingKind::Link ||
            descriptor.kind == SettingsSchema::SettingKind::Custom ||
            descriptor.binding.kind == SettingsSchema::BindingKind::CustomSection ||
            !SettingsSchema::visible(descriptor, context)) {
            continue;
        }
        // GPU 的默认值是清空偏好，不经过数值动作。
        if (descriptor.id == "gpu-index") {
            m_host->setPreference("gpu-index", QString());
            continue;
        }
        applySettingValue(descriptor.id, descriptor.defaultValue);
    }
    // 唱片旋转与自动更新由自定义区块绘制，不在 descriptor 表中，单独恢复默认。
    if (discRotation) {
        action("disc-rotation");
    }
    m_host->setPreference("auto-update", QString());
    settingsScroll = 0;
    refreshSettingsLayout();
    m_music->status = QStringLiteral("已恢复默认设置");
    m_host->invalidate();
}
