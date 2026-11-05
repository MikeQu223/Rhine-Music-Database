#include "NativeHud.h"
#include "HudScroll.h"
#include <algorithm>
#include <cmath>

namespace {
constexpr double LibraryInset = 53;
constexpr double LibraryBarTop = 172;
constexpr double LibraryBarHeight = 66;
constexpr double LibraryTabTop = 252;
constexpr double LibraryTabHeight = 36;
constexpr double LibraryTableY = 302;
constexpr double LibraryFooterY = 786;
constexpr double LibraryCreateWidth = 150;
constexpr double LibraryRefreshWidth = 110;
constexpr double LibraryActionGap = 10;
constexpr double LibraryTitleX = 107;
constexpr double LibraryActionWidth = 136;

QJsonArray accent() {
    return {0.835, 0.639, 0.282, 1};
}

QJsonArray mutedInk(const QJsonArray &ink) {
    auto value = ink;
    value[3] = 0.55;
    return value;
}

QJsonArray faintInk(const QJsonArray &ink, double alpha) {
    auto value = ink;
    value[3] = alpha;
    return value;
}

QJsonArray libraryBarFill(bool dark) {
    return dark ? QJsonArray{0.169, 0.200, 0.173, 1} : QJsonArray{0.898, 0.906, 0.855, 1};
}

QJsonArray libraryPanelFill(bool dark) {
    return dark ? QJsonArray{0.15, 0.15, 0.15, 1} : QJsonArray{0.929, 0.922, 0.894, 1};
}
}

void NativeHud::libraryPanel(double x, double y, double width) {
    if (modal == "search") {
        searchPanel(x, y, width);
        return;
    }
    savedPanel(x, y, width);
}

/** 个人资料库沿用检索页的视觉结构；外框尺寸和输入框位置由弹窗宿主保持。 */
void NativeHud::savedPanel(double x, double y, double width) {
    libraryToolbar(x, y, width);
    libraryResultList(x, y, width);
    libraryFooter(x, y, width);
}

double NativeHud::libraryToolbarActionWidth() const {
    if (modal != "saved") {
        return 0;
    }
    double total = 0;
    if (m_music->editable()) {
        total += LibraryCreateWidth;
    }
    if (m_music->provider == "qq") {
        total += (total > 0 ? LibraryActionGap : 0) + LibraryRefreshWidth;
    }
    return total > 0 ? total + LibraryActionGap : 0;
}

void NativeHud::libraryOutlineButton(const QRectF &rect, const QString &label, const QString &action,
                                     double size, bool plus) {
    const auto line = faintInk(ink(), 0.25);
    fill(rect.left(), rect.top(), rect.width(), rect.height(), libraryPanelFill(dark));
    fill(rect.left(), rect.top(), rect.width(), 1, line);
    fill(rect.left(), rect.bottom() - 1, rect.width(), 1, line);
    fill(rect.left(), rect.top(), 1, rect.height(), line);
    fill(rect.right() - 1, rect.top(), 1, rect.height(), line);
    if (plus) {
        // 原型按钮的小加号图标；与文字作为一个整体居中。
        const auto textWidth = m_glyphs->width(label, size, "regular");
        const auto start = rect.center().x() - (12 + 8 + textWidth) / 2;
        fill(start + 5.25, rect.center().y() - 6, 1.5, 12, faintInk(ink(), 0.55));
        fill(start, rect.center().y() - 0.75, 12, 1.5, faintInk(ink(), 0.55));
        centeredText(label, start + 20, rect.center().y(), size, "regular", false);
    } else {
        centeredText(label, rect.center().x(), rect.center().y(), size, "regular", true);
    }
    hit(rect.left(), rect.top(), rect.width(), rect.height(), action, label);
}

void NativeHud::libraryToolbar(double x, double y, double width) {
    const auto left = x + LibraryInset;
    const auto usable = width - LibraryInset * 2;
    const auto muted = mutedInk(ink());
    const auto gold = accent();
    const auto barWidth = usable - libraryToolbarActionWidth();

    fill(left, y + LibraryBarTop, barWidth, LibraryBarHeight, libraryBarFill(dark));
    fill(left, y + LibraryBarTop, 3, LibraryBarHeight, gold);
    text("QUERY / 检索词", left + 18, y + LibraryBarTop + 10, 9, "regular", 0.08, muted);

    double right = x + width - LibraryInset;
    if (m_music->editable()) {
        const QRectF create(right - LibraryCreateWidth, y + LibraryBarTop, LibraryCreateWidth,
                            LibraryBarHeight);
        libraryOutlineButton(create, QStringLiteral("创建歌单"), "music:create-playlist", 12, true);
        right = create.left() - LibraryActionGap;
    }
    if (m_music->provider == "qq") {
        const QRectF refresh(right - LibraryRefreshWidth, y + LibraryBarTop, LibraryRefreshWidth,
                             LibraryBarHeight);
        libraryOutlineButton(refresh, QStringLiteral("刷新个人库"), "music:refresh-personal", 12);
    }

    const QStringList filters = m_music->columns.mid(1, m_music->provider == "kugou" ? 3 : 4);
    const auto selected = musicCollection - 1;
    double cursor = left;
    for (int index = 0; index < filters.size(); ++index) {
        const auto label = filters.at(index);
        const auto labelWidth = m_glyphs->width(label, 13, "regular");
        const bool active = index == selected;
        hit(cursor - 4, y + LibraryTabTop, labelWidth + 8, LibraryTabHeight,
            "music:collection:" + QString::number(index + 1), label);
        text(label, cursor, y + LibraryTabTop + 10, 13, active ? "demibold" : "regular", 0,
             active ? ink() : muted);
        if (active) {
            fill(cursor, y + LibraryTabTop + LibraryTabHeight - 3, labelWidth, 3, gold);
        }
        cursor += labelWidth + 26;
    }

    const auto lane = musicCollection;
    const bool songs =
        std::any_of(m_music->lists[lane].cbegin(), m_music->lists[lane].cend(),
                    [](const QJsonValue &value) { return value.toObject()["kind"].toString() == "song"; });
    if (songs) {
        const QStringList labels{"原序", "歌手分组", "专辑分组"};
        const QStringList keys{"none", "artist", "album"};
        QVector<double> widths;
        double total = 0;
        for (const auto &label : labels) {
            const auto labelWidth = m_glyphs->width(label, 11, "regular");
            widths.append(labelWidth);
            total += labelWidth;
        }
        total += 20 * (labels.size() - 1);
        double sortX = x + width - LibraryInset - total;
        fill(sortX - 16, y + LibraryTabTop + 6, 1, LibraryTabHeight - 12, faintInk(ink(), 0.18));
        for (int index = 0; index < labels.size(); ++index) {
            const auto label = labels.at(index);
            const bool active = groupBy == keys.at(index);
            hit(sortX - 4, y + LibraryTabTop, widths.at(index) + 8, LibraryTabHeight,
                "music:group:" + QString::number(index), label);
            text(label, sortX, y + LibraryTabTop + 11, 11, active ? "demibold" : "regular", 0,
                 active ? ink() : muted);
            if (active) {
                fill(sortX, y + LibraryTabTop + LibraryTabHeight - 2, widths.at(index), 2, gold);
            }
            sortX += widths.at(index) + 20;
        }
    }

    rule(left, y + LibraryTabTop + LibraryTabHeight, usable, 0.18);
    text("ID / 编号", left, y + LibraryTableY, 9, "regular", 0.07, muted);
    text("TITLE / 音乐", left + LibraryTitleX, y + LibraryTableY, 9, "regular", 0.07, muted);
    text("OPEN", x + width - LibraryActionWidth, y + LibraryTableY, 9, "regular", 0.07, muted);
    rule(left, y + LibraryTableY + 16, usable, 0.24);

    if (!activeGroup.isEmpty()) {
        const auto label = QStringLiteral("← 全部分组");
        const auto labelWidth = m_glyphs->width(label, 11, "regular") + 16;
        const auto actionX = x + width - LibraryInset - 150 - labelWidth;
        hit(actionX, y + LibraryTableY - 7, labelWidth, 28, "music:group-back", "全部分组");
        text(label, actionX + 8, y + LibraryTableY, 11, "regular", 0, ink());
    }
}

void NativeHud::libraryResultList(double x, double y, double width) {
    const auto left = x + LibraryInset;
    const auto usable = width - LibraryInset * 2;
    const auto muted = mutedInk(ink());
    const QRectF viewport(left, y + ResultListTop, usable, ResultListBottom - ResultListTop);
    const auto lane = musicCollection;
    const auto values = rows(lane);
    savedRowCount = int(values.size());
    savedScroll = std::clamp(savedScroll, 0., savedScrollMaximum());

    if (values.isEmpty()) {
        const auto message = m_music->sourceMessage(lane);
        text(fit(message, 18, usable, "demibold"), left, y + ResultListTop + 92, 18, "demibold");
        if (!m_music->isLocal() && !m_music->isSiren() && lane > 0 && m_music->uid.isEmpty() &&
            !m_music->restoringAccount) {
            libraryOutlineButton(QRectF(left, y + ResultListTop + 132, 300, 44),
                                 QStringLiteral("登录") + m_music->providerName() + " →", "music:login", 14);
        }
        return;
    }

    const auto firstHit = hits.size();
    save();
    clip(viewport.x(), viewport.y(), viewport.width(), viewport.height());
    const auto first = std::max(0, int(std::floor(savedScroll / ResultRowHeight)) - 1);
    const auto last = std::min(int(values.size()) - 1,
                               int(std::ceil((savedScroll + viewport.height()) / ResultRowHeight)) + 1);
    for (int index = first; index <= last; ++index) {
        const auto rowY = y + ResultListTop + index * ResultRowHeight - savedScroll;
        resultListRow(values.at(index), x, rowY, width, query, lane);
    }
    restore();
    HudScroll::clipHits(hits, int(firstHit), viewport);

    const auto railX = x + width - 24;
    const auto railTop = viewport.top() + 8;
    const auto railHeight = viewport.height() - 16;
    const auto track = QRectF(railX, railTop, 3, railHeight);
    const auto rail =
        HudScroll::rail(track, savedRowCount * ResultRowHeight, viewport.height(), savedScroll, 30.);
    fill(track.x(), track.y(), track.width(), track.height(), faintInk(ink(), 0.10));
    if (rail.visible) {
        fill(rail.thumb.x(), rail.thumb.y(), rail.thumb.width(), rail.thumb.height(), faintInk(ink(), 0.45));
    }
}

void NativeHud::libraryFooter(double x, double y, double width) {
    const auto muted = mutedInk(ink());
    fill(x + LibraryInset, y + LibraryFooterY + 3, 5, 5, accent());
    text(fit(m_music->status, 10, width - 320, "regular"), x + LibraryInset + 13, y + LibraryFooterY, 10,
         "regular", 0, muted);

    const auto lane = musicCollection;
    const auto loaded = int(m_music->lists[lane].size());
    if (loaded == 0 && !m_music->sourceLoading()) {
        return;
    }
    const auto total = std::max(m_music->totals[lane], loaded);
    QString hint = QStringLiteral("全部已载入");
    if (m_music->sourceLoading()) {
        hint = QStringLiteral("正在加载…");
    } else if (m_music->hasMore[lane]) {
        hint = QStringLiteral("SCROLL / 滚动加载");
    }
    const auto label =
        QStringLiteral("已载入 ") + QString::number(loaded) + " / " + QString::number(total) + " · " + hint;
    const auto labelWidth = m_glyphs->width(label, 9, "regular");
    text(label, x + width - LibraryInset - labelWidth, y + LibraryFooterY, 9, "regular", 0.04, muted);
}

double NativeHud::savedScrollMaximum() const {
    return HudScroll::maximum(savedRowCount * ResultRowHeight, ResultListBottom - ResultListTop);
}

void NativeHud::ensureSavedFilled() {
    if (modal != "saved" || closing || m_music->sourceLoading() || !m_music->hasMore[musicCollection]) {
        return;
    }
    const auto count = int(rows(musicCollection).size());
    if (count <= m_savedAutoFillSize) {
        return;
    }
    m_savedAutoFillSize = count;
    if (count * ResultRowHeight < ResultListBottom - ResultListTop) {
        m_music->loadMoreSource(musicCollection);
    }
}

void NativeHud::loginPanel(double x, double y, double width) {
    const auto &music = *m_music;
    QStringList methods{"qr"};
    if (music.provider == "qq") {
        methods = {"qr", "wechat"};
    } else if (music.provider == "netease") {
        methods = {"qr", "phone"};
    }
    if (music.provider == "kugou") {
        const QStringList editions{"standard", "lite"};
        for (int index = 0; index < editions.size(); ++index) {
            const auto edition = editions.at(index);
            const QString label = edition == "lite" ? "酷狗概念版" : "酷狗标准版";
            button((music.kugouEdition == edition ? "✓ " : "") + label, x + 53 + index * 190, y + 207, 180,
                   35, "music:kugou-edition:" + edition, 13);
        }
        methods.clear();
    }
    const QHash<QString, QString> labels{
        {"qr", music.provider == "qq" ? "手机 QQ 扫码" : music.providerName() + "扫码"},
        {"wechat", "微信扫码"},
        {"phone", "短信验证码"}};
    for (int index = 0; index < methods.size(); ++index) {
        const auto method = methods.at(index);
        button(labels.value(method), x + 53 + index * 145, y + 207, 140, 35, "music:login-method:" + method,
               13);
    }
    if (QStringList{"qr", "wechat"}.contains(music.loginMethod)) {
        image(music.qr, x + width / 2 - 120, y + 260, 240, 240);
        if (music.provider == "qq") {
            const auto lines = m_glyphs->wrap(
                "QQ 音乐账号只允许本人 7 天内在最多 5 台设备上登录，如登录失败，请在设备管理中删除无用设备。",
                width - 106, 13);
            for (int index = 0; index < lines.size(); ++index) {
                text(lines.at(index), x + 53, y + 520 + index * 18, 13);
            }
        }
        if (music.canRegenerateLogin()) {
            button("重新生成二维码", x + 53, y + 626, 260, 40, "music:qr", 15);
        } else {
            const auto seconds = music.loginRetrySeconds();
            const auto label =
                seconds > 0 ? "请等待 " + QString::number(seconds) + " 秒后重新生成" : "正在处理扫码登录…";
            text(label, x + 53, y + 636, 15);
        }
    } else {
        if (m_contentSink) {
            m_contentSink->field("account", "手机号码（中国大陆）");
            m_contentSink->field("captcha", "短信验证码");
            m_contentSink->field("submit", "登录");
        }
        text("手机号码（中国大陆）", x + 53, y + 278, 14);
        text("短信验证码", x + 53, y + 391, 14);
        text("按 ENTER 登录", x + 53, y + 532, 12);
    }
    limited(music.loginStatus, x + 53, y + 600, 15, width - 106);
    button("本轮跳过账号验证", x + 53, y + 709, 350, 45, "close-modal", 16);
    text("凭据仅保存至本机钥匙串，不读取官方 App 的登录信息。", x + 53, y + 785, 11);
}
