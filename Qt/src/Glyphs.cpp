#include <QtGlobal>
#include "Glyphs.h"
#include <QFile>
#include <QCoreApplication>
#include <QThread>
#include <QFontDatabase>
#include <QGlyphRun>
#include <QTextLayout>
#include <QTextBoundaryFinder>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLinearGradient>
#include <QElapsedTimer>
#include <QStringList>
#include <algorithm>
#include <QRadialGradient>
#include <QRegularExpression>
#include <cmath>
#if defined(Q_OS_ANDROID)
#include "render/HudPaintStats.h"
#endif
#ifdef Q_OS_DARWIN
#include <QDataStream>
#include <QColorSpace>
#include <QPaintEngine>
#include <cstring>
#endif
static QJsonObject load(const QString &name) {
    QFile f(name);
    if (!f.open(QIODevice::ReadOnly)) {
        qFatal("Missing glyph resource: %s", qPrintable(name));
    }
    return QJsonDocument::fromJson(f.readAll()).object();
}
static QColor color(const QJsonValue &value) {
    const auto a = value.toArray();
    // 普通 RGBA 只有四项；色彩空间标记是可选的第五项，不能通过可写代理越界读取。
    const bool calibrated = a.size() > 4 && a.at(4).toString().startsWith("calibrated");
    auto channel = [&](int i) {
        double value = a.at(i).toDouble();
        // 原 calibrated 颜色使用 Gamma 1.8；显式转到 sRGB，避免平台默认色彩空间差异。
        if (calibrated) {
            auto linear = std::pow(value, 1.8);
            value = linear <= .0031308 ? 12.92 * linear : 1.055 * std::pow(linear, 1 / 2.4) - .055;
        }
        return value;
    };
    return QColor::fromRgbF(channel(0), channel(1), channel(2), a.size() > 3 ? a[3].toDouble() : 1);
}
/** 直接映射字体源，避免每次重建字体时把四份大型字体文件复制到堆中。 */
QRawFont Glyphs::loadFont(const QString &filename) {
    auto file = std::make_unique<QFile>(filename);
    if (file->open(QIODevice::ReadOnly)) {
        const auto size = file->size();
        if (const auto address = file->map(0, size)) {
            const auto bytes = QByteArray::fromRawData(reinterpret_cast<const char *>(address), size);
            const QRawFont font(bytes, 1000, QFont::PreferNoHinting);
            mappedFonts.push_back(std::move(file));
            return font;
        }
    }
    return QRawFont(filename, 1000, QFont::PreferNoHinting);
}

Glyphs::Glyphs(const QString &root) {
    for (auto weight : {"light", "regular", "demibold", "bold"}) {
        const auto file = root + "/RhineMiSans-" + weight + ".otf";
        fonts[weight] = QRawFont(file, 1000, QFont::PreferNoHinting);
        const int id = QFontDatabase::addApplicationFont(file);
        applicationFonts.append(id);
        const auto families = QFontDatabase::applicationFontFamilies(id);
        layoutFamilies[weight] = families.value(0);
    }
    fonts["symbols"] = loadFont(root + "/NotoSansSymbols2-Regular.ttf");
    const auto data = load(root + "/misans-glyphs.json");
    for (auto font = data.begin(); font != data.end(); ++font) {
        auto entries = font.value().toObject()["glyphs"].toObject();
        for (auto it = entries.begin(); it != entries.end(); ++it) {
            auto o = it.value().toObject();
            glyphs[font.key() + ":" + it.key()] = {o["advance"].toDouble(), path(o["path"].toString())};
        }
    }
    const auto art = load(root + "/boot-lettering-art.json");
    for (auto it = art.begin(); it != art.end(); ++it) {
        for (auto letter : it.value().toObject()["letters"].toArray()) {
            auto o = letter.toObject();
            lettering[it.key()].append({o["width"].toDouble(), path(o["path"].toString())});
        }
    }
}
Glyphs::~Glyphs() {
    const auto removeFonts = [ids = applicationFonts] {
        for (int id : ids) {
            if (id >= 0) {
                QFontDatabase::removeApplicationFont(id);
            }
        }
    };
    const auto application = QCoreApplication::instance();
    if (application && QThread::currentThread() != application->thread()) {
        // 部分平台移除字体会同步刷新窗口事件；渲染线程不能在主线程等待其退出时做这一步。
        QMetaObject::invokeMethod(application, removeFonts, Qt::QueuedConnection);
    } else {
        removeFonts();
    }
}

/** 保留已有轮廓和度量；缺字、组合字符和复杂文字才交给 Qt 排版与系统字体回退。 */
bool Glyphs::needsLayout(const QString &text, const QString &weight) {
    const auto key = weight + ':' + text;
    if (const auto cached = layoutRequired.object(key)) {
        return *cached;
    }
    const auto font = fonts.value(weight, fonts["regular"]);
    const auto symbols = fonts["symbols"];
    bool required = false;
    for (char32_t point : text.toUcs4()) {
        const auto category = QChar::category(point);
        const auto direction = QChar::direction(point);
        const auto script = QChar::script(point);
        const bool combining = category == QChar::Mark_NonSpacing ||
                               category == QChar::Mark_SpacingCombining || category == QChar::Mark_Enclosing;
        const bool hangulJamo = script == QChar::Script_Hangul && (point < 0xac00 || point > 0xd7a3);
        const bool contextual = script != QChar::Script_Common && script != QChar::Script_Inherited &&
                                script != QChar::Script_Latin && script != QChar::Script_Han &&
                                script != QChar::Script_Hiragana && script != QChar::Script_Katakana &&
                                script != QChar::Script_Hangul;
        if (point > 0xffff || combining || hangulJamo || contextual || point == 0x200d ||
            direction == QChar::DirR || direction == QChar::DirAL ||
            (!font.supportsCharacter(point) && !symbols.supportsCharacter(point))) {
            required = true;
            break;
        }
    }
    if (text.size() <= 4096) {
        layoutRequired.insert(key, new bool(required));
    }
    return required;
}

/** 缓存不依赖线程的轮廓，不跨线程保存 QGlyphRun 或其回退 QRawFont。 */
Glyphs::Glyph Glyphs::layoutText(const QString &text, const QString &weight, double spacing) {
    const auto key = weight + ':' + QString::number(spacing, 'g', 17) + ':' + text;
    if (const auto cached = shapedText.object(key)) {
        return *cached;
    }
    const auto raw = fonts.value(weight, fonts["regular"]);
    // 部分平台能直接读取裁剪字库，却不能注册为应用字体，此时使用有效的系统字体族。
    QFont font = QFontDatabase::systemFont(QFontDatabase::GeneralFont);
    const auto family = layoutFamilies.value(weight, layoutFamilies["regular"]);
    if (!family.isEmpty()) {
        font.setFamily(family);
        font.setStyleName(raw.styleName());
    }
    font.setWeight(static_cast<QFont::Weight>(raw.weight()));
    font.setPixelSize(1000);
    font.setHintingPreference(QFont::PreferNoHinting);
    font.setLetterSpacing(QFont::AbsoluteSpacing, spacing);
    QTextLayout layout(text.normalized(QString::NormalizationForm_C), font);
    QTextOption option;
    option.setAlignment(Qt::AlignLeft);
    layout.setTextOption(option);
    layout.beginLayout();
    auto line = layout.createLine();
    if (line.isValid()) {
        line.setLineWidth(1000000);
    }
    layout.endLayout();
    Glyph result;
    result.advance = line.isValid() ? qMax(0., line.horizontalAdvance() - spacing) / 1000 : 0;
    QPainterPath outline;
    outline.setFillRule(Qt::WindingFill);
    for (const auto &run : layout.glyphRuns()) {
        const auto indexes = run.glyphIndexes();
        const auto positions = run.positions();
        const auto fallback = run.rawFont();
        for (qsizetype i = 0; i < indexes.size(); ++i) {
            auto path = fallback.pathForGlyph(indexes[i]);
            path.translate(positions[i].x(), positions[i].y() - line.ascent());
            outline.addPath(path);
        }
    }
    result.path = QTransform::fromScale(1, -1).map(outline);
    if (text.size() <= 4096) {
        shapedText.insert(key, new Glyph(result), qMax(1, text.size()));
    }
    return result;
}

QPainterPath Glyphs::path(const QString &svg) {
    QMutexLocker lock(&mutex);
    if (paths.contains(svg)) {
        return *paths.object(svg);
    }
    static const QRegularExpression re(
        "[a-zA-Z]|[-+]?(?:[0-9]*\\.[0-9]+|[0-9]+\\.?[0-9]*)(?:[eE][-+]?[0-9]+)?");
    QStringList tokens;
    auto matches = re.globalMatch(svg);
    while (matches.hasNext()) {
        tokens << matches.next().captured();
    }
    QPainterPath path;
    path.setFillRule(Qt::WindingFill);
    int i = 0;
    QChar command = 'M';
    QPointF point{}, start{};
    auto number = [&]() { return i < tokens.size() ? tokens[i++].toDouble() : 0.; };
    while (i < tokens.size()) {
        if (tokens[i][0].isLetter()) {
            command = tokens[i++][0];
            if (command.toUpper() == 'Z') {
                path.closeSubpath();
                point = start;
                continue;
            }
        }
        const bool relative = command.isLower();
        const auto origin = relative ? point : QPointF{};
        auto pair = [&]() {
            double x = number() + origin.x();
            double y = number() + origin.y();
            return QPointF(x, y);
        };
        switch (command.toUpper().unicode()) {
        case 'M':
            point = pair();
            path.moveTo(point);
            start = point;
            command = relative ? 'l' : 'L';
            break;
        case 'L':
            point = pair();
            path.lineTo(point);
            break;
        case 'H':
            point.setX(number() + (relative ? point.x() : 0));
            path.lineTo(point);
            break;
        case 'V':
            point.setY(number() + (relative ? point.y() : 0));
            path.lineTo(point);
            break;
        case 'C': {
            auto a = pair();
            auto b = pair();
            auto p = pair();
            path.cubicTo(a, b, p);
            point = p;
            break;
        }
        case 'Q': {
            auto a = pair();
            auto p = pair();
            path.quadTo(a, p);
            point = p;
            break;
        }
        default:
            i = tokens.size();
            break;
        }
    }
    paths.insert(svg, new QPainterPath(path));
    return path;
}
Glyphs::Glyph Glyphs::glyph(QString ch, QString weight) {
    QMutexLocker lock(&mutex);
    const auto key = weight + ":" + ch;
    if (glyphs.contains(key)) {
        return glyphs[key];
    }
    auto font = fonts.value(weight, fonts["regular"]);
    auto ids = font.glyphIndexesForString(ch);
    if (ids.isEmpty() || !ids.first()) {
        font = fonts["symbols"];
        ids = font.glyphIndexesForString(ch);
    }
    if (ids.isEmpty() || !ids.first()) {
        return {};
    }
    auto advances = font.advancesForGlyphIndexes(ids);
    // Qt 字形坐标朝下；资源轮廓保持原始字体朝上的坐标。
    auto outline = QTransform::fromScale(1, -1).map(font.pathForGlyph(ids.first()));
    return glyphs[key] = {advances.first().x() / 1000, outline};
}
double Glyphs::width(QString text, double size, QString weight, double tracking) {
    QMutexLocker lock(&mutex);
    // key 原来是「把四个参数序列化成一份 JSON」。`width()` 在每一帧的 fit / inset / 裁剪判断里
    // 被调很多次，序列化 + UTF-8 往返比查缓存本身还贵。改成定界符拼接：'g',17 保证 double
    // 往返精确，缓存语义与原来逐项等价。
    const auto key = QString::number(size, 'g', 17) + QChar(0x1f) + weight + QChar(0x1f) +
                     QString::number(tracking, 'g', 17) + QChar(0x1f) + text;
    if (const auto cached = widths.object(key)) {
        return *cached;
    }
    if (needsLayout(text, weight)) {
        const auto result = layoutText(text, weight, size > 0 ? tracking * 1000 / size : 0).advance * size;
        widths.insert(key, new double(result));
        return result;
    }
    double result = 0;
    for (auto ch : text) {
        auto g = glyph(QString(ch), weight);
        result += g.advance * size + tracking;
    }
    result = qMax(0., result - tracking);
    if (text.size() <= 4096) {
        widths.insert(key, new double(result));
    }
    return result;
}
QVariantMap Glyphs::bounds(QString value, double size, QString weight) {
    QMutexLocker lock(&mutex);
    if (needsLayout(value, weight)) {
        QTransform transform;
        transform.translate(0, size * 1.044);
        transform.scale(size / 1000, -size / 1000);
        const auto bounds = transform.map(layoutText(value, weight, 0).path).boundingRect();
        return {{"x", bounds.x()}, {"y", bounds.y()}, {"width", bounds.width()}, {"height", bounds.height()}};
    }
    QRectF bounds;
    bool visible = false;
    double x = 0;
    // 使用和实际绘制完全相同的轮廓变换，避免中英文字体基线造成视觉错位。
    for (auto ch : value) {
        const auto g = glyph(QString(ch), weight);
        if (!g.path.isEmpty()) {
            QTransform transform;
            transform.translate(x, size * 1.044);
            transform.scale(size / 1000, -size / 1000);
            const auto rect = transform.map(g.path).boundingRect();
            bounds = visible ? bounds.united(rect) : rect;
            visible = true;
        }
        x += g.advance * size;
    }
    return {{"x", bounds.x()}, {"y", bounds.y()}, {"width", bounds.width()}, {"height", bounds.height()}};
}
double Glyphs::inset(QString text, double size, QString weight) {
    QMutexLocker lock(&mutex);
    if (text.isEmpty()) {
        return 0;
    }
    if (needsLayout(text, weight)) {
        return layoutText(text, weight, 0).path.boundingRect().x() * size / 1000;
    }
    auto g = glyph(text.first(1), weight);
    return !g.path.isEmpty() ? g.path.boundingRect().x() * size / 1000 : 0;
}
QStringList Glyphs::wrap(QString value, double limit, double size, QString weight) {
    QMutexLocker lock(&mutex);
    // 同 width()：别再用「序列化成 JSON」当 key。歌词整段文本做 key 时，序列化本身
    // 就比查缓存贵，而 wrap 在换行布局里是热路径。
    const auto key = QString::number(limit, 'g', 17) + QChar(0x1f) + QString::number(size, 'g', 17) +
                     QChar(0x1f) + weight + QChar(0x1f) + value;
    if (const auto cached = wrapped.object(key)) {
        return *cached;
    }
    QStringList lines;
    QString line;
    if (needsLayout(value, weight)) {
        QTextBoundaryFinder finder(QTextBoundaryFinder::Grapheme, value);
        int start = 0;
        for (int end = finder.toNextBoundary(); end >= 0; end = finder.toNextBoundary()) {
            const auto cluster = value.mid(start, end - start);
            start = end;
            if (cluster.contains('\n')) {
                lines.append(line);
                line.clear();
            } else if (!line.isEmpty() && width(line + cluster, size, weight) > limit) {
                lines.append(line);
                line = cluster;
            } else {
                line += cluster;
            }
        }
        lines.append(line);
        wrapped.insert(key, new QStringList(lines), qMax(1, value.size()));
        return lines;
    }
    double length = 0;
    for (auto ch : value) {
        if (ch == '\n') {
            lines << line;
            line.clear();
            length = 0;
            continue;
        }
        double advance = width(QString(ch), size, weight);
        if (!line.isEmpty() && length + advance > limit) {
            lines << line;
            line.clear();
            length = 0;
        }
        line += ch;
        length += advance;
    }
    lines << line;
    // 有界缓存包含完整布局参数；窗口缩放和内容变化使用不同 key。
    wrapped.insert(key, new QStringList(lines), qMax(1, value.size()));
    return lines;
}
double Glyphs::artWidth(QString key, double size, double tracking, int count) {
    QMutexLocker lock(&mutex);
    double result = 0;
    const auto letters = lettering.value(key);
    const auto visible = letters.mid(0, count < 0 ? letters.size() : count);
    for (auto g : visible) {
        result += g.advance * size + tracking;
    }
    return visible.isEmpty() ? 0 : result - tracking;
}
#if defined(Q_OS_ANDROID)
bool Glyphs::runCacheEnabled() {
    // **默认关闭**（2026-11-06 晚实测翻案）：RHINE_HUD_RUN_CACHE=1 才启用，用于 A/B。
    //
    // 10:35 的采样 sync 均值 41.8ms / 17.2fps；把「整段文本合成一条路径」与
    // 「right-mask 烘图」一起默认打开后重编，11:21 的采样变成 63.0ms / 12.1fps
    // （CPU 154%→183%），而这一轮新增的局部重绘当时因为开关默认值写反并未生效。
    // 原因是 QRasterizer 的覆盖率按**包围盒**算，不是按墨水面积：把一行字并成一条
    // 复合路径后，包围盒变成整行，逐字形时每个字形只有自己的紧包围盒，
    // 合并反而把扫描线工作量放大。缓存省下的“变换次数”抵不过这个放大。
    static const bool enabled = [] {
        const auto value = qEnvironmentVariable("RHINE_HUD_RUN_CACHE");
        return !value.isEmpty() && value != QLatin1String("0");
    }();
    return enabled;
}
/** 把一段文本的字形合成一条 em 单位路径：每帧只做一次 fillPath，而不是逐字符一次。 */
QPainterPath Glyphs::textRunPath(const QString &value, const QString &weight, double trackingEm) {
    const QString key = QStringLiteral("t") + value + QChar(0x1f) + weight + QChar(0x1f) +
                        QString::number(trackingEm, 'g', 8);
    if (const auto *cached = runPaths.object(key)) {
        return *cached;
    }
    QPainterPath run;
    // 字形轮廓是 nonzero 语义；合成后统一按 WindingFill 求并集，重叠处不会互相挖空。
    run.setFillRule(Qt::WindingFill);
    double penX = 0;
    for (const auto ch : value) {
        // Qt 6.12 的 QPainterPath::addPath 只有单参数重载，位移只能先 translate 再 add。
        auto g = glyph(QString(ch), weight);
        if (!g.path.isEmpty()) {
            g.path.translate(penX, 0);
            run.addPath(g.path);
        }
        // advance 以 em 为单位（绘制时乘 size），这里换算回 1000 单位的字形空间。
        penX += g.advance * 1000 + trackingEm;
    }
    runPaths.insert(key, new QPainterPath(run), qMax(1, int(run.elementCount())));
    return run;
}
/** 字形美术（lettering）同理：整串合成一条路径，和文本共用同一个缓存。 */
QPainterPath Glyphs::artRunPath(const QString &key, int count, double trackingEm) {
    const QString cacheKey = QStringLiteral("a") + key + QChar(0x1f) + QString::number(count) +
                             QChar(0x1f) + QString::number(trackingEm, 'g', 8);
    if (const auto *cached = runPaths.object(cacheKey)) {
        return *cached;
    }
    QPainterPath run;
    run.setFillRule(Qt::WindingFill);
    double penX = 0;
    const auto letters = lettering.value(key);
    const auto visible = letters.mid(0, count < 0 ? letters.size() : count);
    for (const auto &source : visible) {
        auto path = source.path;
        if (!path.isEmpty()) {
            path.translate(penX, 0);
            run.addPath(path);
        }
        penX += source.advance * 1000 + trackingEm;
    }
    runPaths.insert(cacheKey, new QPainterPath(run), qMax(1, int(run.elementCount())));
    return run;
}
/**
 * 归档页的右向淡出遮罩是「整块 789×984 的线性渐变」，每帧重画等于每帧对 2.15M 设备像素
 * 做一次渐变求值。这里把它烘成一行 ARGB 图（只有横向变化），之后用 SmoothPixmapTransform
 * 拉伸绘制：纵向所有行完全相同，所以纵向插值没有误差，横向只是把原本就平滑的斜坡放大。
 */
bool Glyphs::drawCachedMask(QPainter &c, const QJsonArray &a) {
    // **默认关闭**（2026-11-06 晚实测翻案）：RHINE_HUD_MASK_CACHE=1 才启用。
    // 789x984 = 776k 像素上，双线性拉伸一张 W×1 图（4 次采样 + 2 次插值）比
    // QLinearGradient 的水平色表查找更贵，与「渐变求值很慢」的假设相反。
    static const bool enabled = [] {
        const auto value = qEnvironmentVariable("RHINE_HUD_MASK_CACHE");
        return !value.isEmpty() && value != QLatin1String("0");
    }();
    if (!enabled || a.size() < 6) {
        return false;
    }
    const auto ink = color(a[1]);
    const double start = a[2].toDouble();
    const double span = a[3].toDouble();
    const double width = a[4].toDouble();
    const double height = a[5].toDouble();
    const double pixels = std::ceil(width - start);
    // 只处理归档页那种「一条横带」；异常参数（负宽、超大矩形）交回原路径，别在这里赌内存。
    if (!std::isfinite(pixels) || pixels < 2 || pixels > 4096 || width <= start || height <= 0 ||
        span < 1) {
        return false;
    }
    const QString key = ink.name(QColor::HexArgb) + QChar(0x1f) + QString::number(start, 'g', 6) +
                        QChar(0x1f) + QString::number(span, 'g', 6) + QChar(0x1f) +
                        QString::number(width, 'g', 6) + QChar(0x1f) + QString::number(height, 'g', 6);
    const QRectF target(start, 0, width - start, height);
    if (const auto *cached = maskGradients.object(key)) {
        c.drawImage(target, *cached);
        return true;
    }
    QImage line(int(pixels), 1, QImage::Format_ARGB32_Premultiplied);
    line.fill(Qt::transparent);
    auto *row = reinterpret_cast<QRgb *>(line.scanLine(0));
    const int red = qRound(ink.redF() * 255);
    const int green = qRound(ink.greenF() * 255);
    const int blue = qRound(ink.blueF() * 255);
    const double baseAlpha = ink.alphaF();
    const double safeSpan = span > 0 ? span : 1;
    for (int i = 0; i < line.width(); ++i) {
        // 与 QRasterPaintEngine 一样按像素中心采样；16 段 smoothstep 在本尺寸上与解析式等价。
        const double progress = std::clamp((i + 0.5) / safeSpan, 0.0, 1.0);
        const double eased = progress * progress * (3 - 2 * progress);
        row[i] = qPremultiply(qRgba(red, green, blue, qRound(255 * baseAlpha * eased)));
    }
    maskGradients.insert(key, new QImage(line), qMax(1, line.sizeInBytes() / 1024));
    c.drawImage(target, line);
    return true;
}
#endif
void Glyphs::text(QPainter &c, QString value, double x, double y, double size, QString weight,
                  double tracking, QColor ink) {
    QMutexLocker lock(&mutex);
    if (needsLayout(value, weight)) {
        const auto shaped = layoutText(value, weight, size > 0 ? tracking * 1000 / size : 0);
        c.save();
        c.translate(x, y + size * 1.044);
        c.scale(size / 1000, -size / 1000);
        c.fillPath(shaped.path, ink);
        c.restore();
        return;
    }
#if defined(Q_OS_ANDROID)
    if (size > 0 && runCacheEnabled()) {
        const auto run = textRunPath(value, weight, tracking * 1000 / size);
        if (!run.isEmpty()) {
            c.save();
            c.translate(x, y + size * 1.044);
            c.scale(size / 1000, -size / 1000);
            c.fillPath(run, ink);
            c.restore();
        }
        return;
    }
#endif
    for (auto ch : value) {
        auto g = glyph(QString(ch), weight);
        c.save();
        c.translate(x, y + size * 1.044);
        c.scale(size / 1000, -size / 1000);
        c.fillPath(g.path, ink);
        c.restore();
        x += g.advance * size + tracking;
    }
}
void Glyphs::art(QPainter &c, QString key, double x, double y, double size, int count, double tracking) {
    QMutexLocker lock(&mutex);
#if defined(Q_OS_ANDROID)
    if (size > 0 && runCacheEnabled()) {
        const auto run = artRunPath(key, count, tracking * 1000 / size);
        if (!run.isEmpty()) {
            c.save();
            c.translate(x, y);
            c.scale(size / 1000, size / 1000);
            c.fillPath(run, c.brush());
            c.restore();
        }
        return;
    }
#endif
    for (auto g : lettering[key].mid(0, count < 0 ? lettering[key].size() : count)) {
        c.save();
        c.translate(x, y);
        c.scale(size / 1000, size / 1000);
        c.fillPath(g.path, c.brush());
        c.restore();
        x += g.advance * size + tracking;
    }
}
void Glyphs::commands(QPainter &c, const QJsonArray &commands, std::function<QImage(QString)> image) {
    renderCommands(c, commands, std::move(image), false);
}
void Glyphs::renderCommands(QPainter &c, const QJsonArray &commands, std::function<QImage(QString)> image,
                            bool cacheText) {
    QMutexLocker lock(&mutex);
    c.setRenderHints(QPainter::Antialiasing | QPainter::SmoothPixmapTransform);
    // 分段探针（RHINE_HUD_PROBE=1）：按操作类型累计 QPainter 耗时，判断该缓存哪一类。
    static const bool opTiming = qEnvironmentVariableIntValue("RHINE_HUD_PROBE") == 1;
    static QHash<QString, double> opMs;
    static int opFrames = 0;
    QElapsedTimer opClock;
#ifdef Q_OS_ANDROID
    // 相交预筛：脏区重画时整条命令流仍会被逐条执行一遍。QPainter 会把裁剪区外的像素丢掉，
    // 但「文字排版、字形查找、路径构造、封面查找」这些跟像素无关的开销一样照付；静态画面
    // （brand / 导航 / footer / 播放栏）在滑列表时一条都没变，却每帧重算一遍。
    // 这里按命令的舞台包围盒先判一次相交，整体落在裁剪区外的直接跳过。
    //
    // 只处理包围盒能精确或保守算出的类型；`gradient` 与未知 op 一律照画。
    // 整窗重画时裁剪区就是整屏，全部相交，行为与改动前一致。
    static const bool cullEnabled = [] {
        const auto value = qEnvironmentVariable("RHINE_HUD_CULL");
        return value.isEmpty() || value != QLatin1String("0");
    }();
    bool cull = cullEnabled && c.hasClipping();
    QRectF clipBox = cull ? c.clipBoundingRect() : QRectF();
    if (clipBox.isEmpty()) {
        // 空裁剪盒会让每一条命令都被判成"在外面"，等于整屏不画。宁可不优化。
        cull = false;
    }
    QList<QRectF> clipStack;
    quint64 culled = 0;
    // 包围盒只做「整体在裁剪区之外」的判定；拿不准就返回 false（照画），宁可多画不漏画。
    auto outside = [&](const QRectF &box) {
        if (!cull || box.isEmpty()) {
            return false;
        }
        return !clipBox.intersects(box);
    };
    // 文本宽度按「每字符 1.1 em + 字距」估：中文是全宽 1 em，拉丁约 0.55 em，
    // 取 1.1 对拉丁是两倍保守、对中文刚好覆盖粗体溢出。纵向按基线 -1.15 / +0.45 em，
    // 覆盖 ascent（不同字体 0.75~1.0 em）与降部。不调 width()：它每次都要拼 key 查缓存，
    // 比这里估一次还贵，而这里只需要「不会漏」而不是精确。
    auto textBox = [&](int length, double x, double y, double size, double tracking) {
        const double wide = length * (size * 1.1 + qMax(0.0, tracking));
        return QRectF(x - size * 0.2, y - size * 1.15, wide + size * 0.4, size * 1.6);
    };
#endif
    for (const auto &v : commands) {
        const auto a = v.toArray();
        auto op = a[0].toString();
        auto n = [&](int i) { return a[i].toDouble(); };
        if (opTiming) {
            opClock.start();
        }
        if (op == "save") {
            c.save();
#ifdef Q_OS_ANDROID
            if (cull) {
                clipStack.append(clipBox);
            }
#endif
        } else if (op == "restore") {
            c.restore();
#ifdef Q_OS_ANDROID
            if (cull && !clipStack.isEmpty()) {
                clipBox = clipStack.takeLast();
            }
#endif
        } else if (op == "alpha") {
            c.setOpacity(c.opacity() * n(1));
        } else if (op == "translate") {
            c.translate(n(1), n(2));
#ifdef Q_OS_ANDROID
            // 坐标系偏离舞台空间后，包围盒与裁剪区不再同一把尺子，本帧剩下的命令一律照画。
            cull = false;
#endif
        } else if (op == "scale") {
            c.scale(n(1), n(2));
#ifdef Q_OS_ANDROID
            cull = false;
#endif
        } else if (op == "rotate") {
            c.rotate(n(1) * 180 / 3.14159265358979323846);
#ifdef Q_OS_ANDROID
            cull = false;
#endif
        } else if (op == "clip") {
            const QRectF next(n(1), n(2), n(3), n(4));
            c.setClipRect(next, Qt::IntersectClip);
#ifdef Q_OS_ANDROID
            if (cull) {
                clipBox = clipBox.intersected(next);
            }
#endif
        } else if (op == "fill") {
#ifdef Q_OS_ANDROID
            if (outside(QRectF(n(2), n(3), n(4), n(5)))) {
                ++culled;
                continue;
            }
#endif
            c.fillRect(QRectF(n(2), n(3), n(4), n(5)), color(a[1]));
        } else if (op == "ellipse") {
#ifdef Q_OS_ANDROID
            if (outside(QRectF(n(2), n(3), n(4), n(5)))) {
                ++culled;
                continue;
            }
#endif
            c.setPen(Qt::NoPen);
            c.setBrush(color(a[1]));
            c.drawEllipse(QRectF(n(2), n(3), n(4), n(5)));
        } else if (op == "text") {
#ifdef Q_OS_ANDROID
            // 越界参数交给原路径处理：这里只判相交，不改语义。
            if (n(4) > 0 && outside(textBox(int(a[1].toString().size()), n(2), n(3), n(4), n(6)))) {
                ++culled;
                continue;
            }
#endif
            bool rasterized = false;
#ifdef Q_OS_DARWIN
            rasterized = cacheText && drawRasterCommand(c, a);
#endif
            if (!rasterized) {
                text(c, a[1].toString(), n(2), n(3), n(4), a[5].toString(), n(6), color(a[7]));
            }
        } else if (op == "art") {
            const int letters = a[5].toInt(-1);
#ifdef Q_OS_ANDROID
            // count < 0 表示整串，长度未知，不筛。
            if (letters >= 0 && outside(textBox(letters, n(2), n(3), n(4), n(6)))) {
                ++culled;
                continue;
            }
#endif
            c.setBrush(color(a[7]));
            art(c, a[1].toString(), n(2), n(3), n(4), letters, n(6));
        } else if (op == "fill-path") {
            // 实心几何图标不受字体字形边距影响。
            const auto shape = path(a[1].toString());
#ifdef Q_OS_ANDROID
            if (outside(shape.boundingRect())) {
                ++culled;
                continue;
            }
#endif
            c.fillPath(shape, color(a[2]));
        } else if (op == "path") {
            const auto shape = path(a[1].toString());
            const double penWidth = n(2);
#ifdef Q_OS_ANDROID
            // 描边会以笔宽向两侧扩张，包围盒要按半个笔宽外扩。
            if (outside(shape.boundingRect().adjusted(-penWidth, -penWidth, penWidth, penWidth))) {
                ++culled;
                continue;
            }
#endif
            QPen pen(color(a[3]), penWidth, Qt::SolidLine, Qt::FlatCap, Qt::MiterJoin);
            auto dash = a[4].toArray();
            QList<qreal> d;
            for (auto x : dash) {
                d << x.toDouble() / qMax(penWidth, .0001);
            }
            if (!d.isEmpty()) {
                pen.setDashPattern(d);
                pen.setDashOffset(n(5) / qMax(penWidth, .0001));
            }
            c.setPen(pen);
            c.setBrush(Qt::NoBrush);
            c.drawPath(shape);
        } else if (op == "arc") {
            QPainterPath p;
            QRectF r(n(1) - n(3), n(2) - n(3), n(3) * 2, n(3) * 2);
#ifdef Q_OS_ANDROID
            if (outside(r.adjusted(-n(6), -n(6), n(6), n(6)))) {
                ++culled;
                continue;
            }
#endif
            p.arcMoveTo(r, -n(4) * 180 / 3.14159265358979323846);
            p.arcTo(r, -n(4) * 180 / 3.14159265358979323846, -n(5) * 180 / 3.14159265358979323846);
            c.setPen(QPen(color(a[7]), n(6), Qt::SolidLine, Qt::RoundCap));
            c.setBrush(Qt::NoBrush);
            c.drawPath(p);
        } else if (op == "right-mask") {
#ifdef Q_OS_ANDROID
            if (drawCachedMask(c, a)) {
                continue;
            }
#endif
#ifdef Q_OS_DARWIN
            if (cacheText && drawRasterCommand(c, a)) {
                continue;
            }
#endif
#ifdef Q_OS_ANDROID
            if (outside(QRectF(n(2), 0, n(4) - n(2), n(5)))) {
                ++culled;
                continue;
            }
#endif
            // 强度沿平滑曲线提升
            const auto baseColor = color(a[1]);
            const auto start = n(2);
            const auto span = n(3);
            QLinearGradient gradient(QPointF(start, 0), QPointF(start + span, 0));
            constexpr int MaskSteps = 16;
            for (int step = 0; step <= MaskSteps; ++step) {
                const auto progress = double(step) / MaskSteps;
                const auto eased = progress * progress * (3 - 2 * progress);
                auto stopColor = baseColor;
                stopColor.setAlphaF(baseColor.alphaF() * eased);
                gradient.setColorAt(progress, stopColor);
            }
            c.fillRect(QRectF(start, 0, n(4) - start, n(5)), gradient);
        } else if (op == "gradient") {
            QRadialGradient gradient(QPointF(979.2, 518.4), 1100);
            const bool dark = a.size() > 1 && a[1].toBool();
            gradient.setColorAt(0, dark ? QColor(32, 42, 47) : QColor(231, 231, 225));
            gradient.setColorAt(.76, dark ? QColor(23, 33, 37) : QColor(227, 225, 220));
            gradient.setColorAt(1, dark ? QColor(17, 24, 27) : QColor(228, 223, 219));
            c.fillRect(QRectF(-4096, -4096, 8192, 8192), gradient);
        } else if (op == "image") {
#ifdef Q_OS_ANDROID
            // 顺带省掉一次封面查找：整块落在裁剪区外时连 image() 都不用调。
            if (outside(QRectF(n(2), n(3), n(4), n(5)))) {
                ++culled;
                continue;
            }
#endif
            auto img = image(a[1].toString());
            if (!img.isNull()) {
                c.drawImage(QRectF(n(2), n(3), n(4), n(5)), img);
            }
        }
        if (opTiming) {
            opMs[op] += double(opClock.nsecsElapsed()) / 1e6;
        }
    }
#ifdef Q_OS_ANDROID
    // 记进性能 JSON，下一份 RHINE Diagnostics 就能看到「这一帧筛掉了多少条命令」，
    // 不用再靠日志猜（设备设不了环境变量，OPPO 的 logcat 配额还会把行挤掉）。
    if (cullEnabled) {
        auto &stats = RhineRender::hudPaintStats();
        stats.cullConsidered.fetch_add(quint64(commands.size()), std::memory_order_relaxed);
        stats.cullSkipped.fetch_add(culled, std::memory_order_relaxed);
    }
#endif
    if (opTiming && ++opFrames % 30 == 0) {
        QStringList parts;
        QList<QPair<double, QString>> sorted;
        for (auto it = opMs.cbegin(); it != opMs.cend(); ++it) {
            sorted.append({it.value(), it.key()});
        }
        std::sort(sorted.begin(), sorted.end(), [](const auto &l, const auto &r) { return l.first > r.first; });
        double total = 0.0;
        for (const auto &row : sorted) {
            total += row.first;
        }
        for (int i = 0; i < sorted.size() && i < 6; ++i) {
            parts << QStringLiteral("%1 %2ms(%3%)")
                         .arg(sorted[i].second)
                         .arg(sorted[i].first / 30.0, 0, 'f', 1)
                         .arg(total > 0 ? sorted[i].first * 100 / total : 0, 0, 'f', 0);
        }
        qWarning().noquote() << "HUD 分项: 每帧共" << QString::number(total / 30.0, 'f', 2) << "ms |" << parts.join(" ");
        opMs.clear();
    }
}
QImage Glyphs::label(const QJsonObject &value) {
    QMutexLocker lock(&mutex);
    QImage img(1024, 440, QImage::Format_RGBA8888_Premultiplied);
    img.fill(QColor::fromRgbF(.902, .886, .851));
    QPainter c(&img);
    c.setRenderHint(QPainter::Antialiasing);
    QColor ink = QColor::fromRgbF(.09, .09, .075);
    c.fillRect(QRectF(12, 12, 1000, 6), ink);
    auto fit = [&](QString s, double y, double maximum, QString weight) {
        double size = maximum;
        while (width(s, size, weight) > 954 && size > 34) {
            size -= 2;
        }
        QString shown = s;
        while (width(shown, size, weight) > 954 && shown.size() > 1) {
            shown.chop(1);
        }
        if (shown != s) {
            shown.chop(1);
            shown += "…";
        }
        text(c, shown, 30, y, size, weight, 0, ink);
    };
    fit(value["title"].toString("音乐资料库"), 40, 125, "bold");
    auto artist = value["artist"].toString();
    fit(artist.isEmpty() ? "暂无歌手" : artist, 210, 78, "demibold");
    fit(value["kind"].toString("MUSIC").toUpper() + " ID " + value["id"].toString("—"), 340, 40, "regular");
    return img;
}
void saveImageNative(const QImage &image, const QString &path) {
    image.save(path);
}

#ifdef Q_OS_DARWIN
/** 用原轮廓和 tracking 求设备像素范围，不猜测字体上升部或侧边距。 */
QRect Glyphs::rasterCommandBounds(const QJsonArray &command, const QTransform &transform) {
    if (command[0].toString() == "right-mask") {
        const QRectF area(command[2].toDouble(), 0, command[4].toDouble() - command[2].toDouble(),
                          command[5].toDouble());
        return transform.mapRect(area).adjusted(-2, -2, 2, 2).toAlignedRect();
    }
    const auto value = command[1].toString();
    const double size = command[4].toDouble();
    const auto weight = command[5].toString();
    const double tracking = command[6].toDouble();
    double x = command[2].toDouble();
    const double y = command[3].toDouble();
    QRectF bounds;
    const auto addBounds = [&](const Glyph &glyph, double origin) {
        QTransform glyphTransform = transform;
        glyphTransform.translate(origin, y + size * 1.044);
        glyphTransform.scale(size / 1000, -size / 1000);
        bounds = bounds.united(glyphTransform.mapRect(glyph.path.controlPointRect()));
    };
    if (needsLayout(value, weight)) {
        addBounds(layoutText(value, weight, size > 0 ? tracking * 1000 / size : 0), x);
    } else {
        for (auto character : value) {
            const auto outline = glyph(QString(character), weight);
            addBounds(outline, x);
            x += outline.advance * size + tracking;
        }
    }
    if (bounds.isEmpty() || !std::isfinite(bounds.width()) || !std::isfinite(bounds.height()) ||
        !std::isfinite(bounds.left()) || !std::isfinite(bounds.top())) {
        return {};
    }
    // 抗锯齿覆盖可能越过轮廓的取整边界；边缘留两个物理像素。
    const auto pixels = bounds.adjusted(-2, -2, 2, 2).toAlignedRect();
    if (pixels.width() > 4096 || pixels.height() > 4096 ||
        qint64(pixels.width()) * pixels.height() > 1024 * 1024) {
        return {};
    }
    return pixels;
}

/** 在原设备坐标栅格化后裁出缓存；保留背景和所有舍入步骤。 */
std::unique_ptr<Glyphs::RasterText> Glyphs::rasterizeCommand(QPainter &ctx, const QJsonArray &command,
                                                             const QImage &image, int pixelBudget) {
    const auto transform = ctx.deviceTransform();
    const bool mask = command[0].toString() == "right-mask";
    auto pixels = rasterCommandBounds(command, transform);
    if (mask) {
        pixels = pixels.intersected(image.rect());
        if (ctx.hasClipping()) {
            pixels = pixels.intersected(transform.map(ctx.clipPath()).boundingRect().toAlignedRect());
        }
    }
    if (pixels.isEmpty() ||
        (!mask && ctx.hasClipping() && !transform.map(ctx.clipPath()).contains(QRectF(pixels)))) {
        return {};
    }
    // 先验证背景与结果的总预算，避免大遮罩每帧栅格化后又被 QCache 拒绝。
    const qint64 pixelBytes = qint64(pixels.width()) * pixels.height() * 8;
    if (pixelBytes > pixelBudget) {
        return {};
    }
    auto entry = std::make_unique<RasterText>();
    entry->origin = pixels.topLeft();
    // 保留原背景一起栅格化，避免半透明遮罩上二次预乘和合成的舍入误差。
    entry->background = image.copy(pixels);
    entry->background.setDevicePixelRatio(1);
    if (rasterScratch.size() != image.size() || rasterScratch.format() != image.format()) {
        rasterScratch = QImage(image.size(), image.format());
        rasterScratch.setColorSpace(image.colorSpace());
        rasterScratch.fill(Qt::transparent);
    }
    QPainter painter(&rasterScratch);
    painter.setCompositionMode(QPainter::CompositionMode_Source);
    painter.drawImage(pixels.topLeft(), entry->background);
    painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
    painter.setRenderHints(ctx.renderHints());
    // 保持完整设备坐标，避免移到小图原点后浮点取整改变边缘覆盖率。
    painter.setWorldTransform(transform);
    if (mask) {
        if (ctx.hasClipping()) {
            painter.setClipPath(ctx.clipPath());
        }
        commands(painter, QJsonArray{command}, {}, false);
    } else {
        text(painter, command[1].toString(), command[2].toDouble(), command[3].toDouble(),
             command[4].toDouble(), command[5].toString(), command[6].toDouble(), color(command[7]));
    }
    painter.end();
    entry->image = rasterScratch.copy(pixels);
    return entry;
}

/** 缓存重复文字与遮罩的完整像素；动态透明度、特殊合成和投影沿用原绘制。 */
bool Glyphs::drawRasterCommand(QPainter &ctx, const QJsonArray &command) {
    const auto transform = ctx.deviceTransform();
    const auto deviceImage = dynamic_cast<QImage *>(ctx.device());
    const bool supportedImage =
        deviceImage && (deviceImage->format() == QImage::Format_ARGB32_Premultiplied ||
                        deviceImage->format() == QImage::Format_RGBA8888_Premultiplied);
    if (!supportedImage || ctx.paintEngine()->type() != QPaintEngine::Raster || !transform.isAffine() ||
        command[1].toString().size() > 4096 || deviceImage->sizeInBytes() > 32 * 1024 * 1024 ||
        ctx.opacity() != 1 || ctx.compositionMode() != QPainter::CompositionMode_SourceOver) {
        return false;
    }
    QByteArray key;
    QDataStream stream(&key, QIODevice::WriteOnly);
    const bool mask = command[0].toString() == "right-mask";
    if (mask && ctx.hasClipping()) {
        const auto clip = transform.map(ctx.clipPath());
        const auto bounds = clip.boundingRect();
        if (clip.elementCount() != 5) {
            return false;
        }
        for (int i = 0; i < clip.elementCount(); ++i) {
            const auto point = clip.elementAt(i);
            const bool corner =
                (std::abs(point.x - bounds.left()) < 1e-6 || std::abs(point.x - bounds.right()) < 1e-6) &&
                (std::abs(point.y - bounds.top()) < 1e-6 || std::abs(point.y - bounds.bottom()) < 1e-6);
            if (!corner || std::abs(point.x - std::round(point.x)) > 1e-6 ||
                std::abs(point.y - std::round(point.y)) > 1e-6) {
                // 分数像素或曲线裁剪重建会再次取整，保留原画笔的覆盖率计算。
                return false;
            }
        }
    }
    stream << command << transform << quint32(ctx.renderHints()) << quint32(deviceImage->format());
    if (mask) {
        stream << deviceImage->size() << ctx.hasClipping() << ctx.clipPath();
    }
    const RasterText *cached = rasterText.object(key);
    if (!cached) {
        if (!rasterCandidates.contains(key)) {
            rasterCandidates.insert(key, new bool(true), qMax(1, int(key.size())));
            return false;
        }
        auto entry = rasterizeCommand(ctx, command, *deviceImage, rasterText.maxCost() - int(key.size()));
        if (!entry) {
            return false;
        }
        const int bytes = int(entry->image.sizeInBytes() + entry->background.sizeInBytes() + key.size());
        rasterText.insert(key, entry.release(), bytes);
        cached = rasterText.object(key);
    }
    if (!cached) {
        return false;
    }
    if (!mask && ctx.hasClipping() &&
        !transform.map(ctx.clipPath()).contains(QRectF(cached->origin, cached->image.size()))) {
        return false;
    }
    const QRect area(cached->origin, cached->image.size());
    bool sameBackground = true;
    if (deviceImage->rect().contains(area)) {
        for (int y = 0; y < area.height(); ++y) {
            const auto pixels = deviceImage->constScanLine(area.top() + y) + area.left() * 4;
            if (std::memcmp(pixels, cached->background.constScanLine(y), size_t(area.width()) * 4) != 0) {
                sameBackground = false;
                break;
            }
        }
    } else {
        auto background = deviceImage->copy(area);
        background.setDevicePixelRatio(1);
        sameBackground = background == cached->background;
    }
    if (!sameBackground) {
        // 背景或前序指令变化时回退原绘制，绝不把旧背景盖回画面。
        return false;
    }
    ctx.save();
    if (mask) {
        // 缓存已包含裁剪边缘覆盖率；整块连同原背景拷贝，不能再次乘裁剪抗锯齿。
        ctx.setClipping(false);
    }
    ctx.setWorldTransform(QTransform());
    bool invertible = false;
    const auto inverse = ctx.deviceTransform().inverted(&invertible);
    if (invertible) {
        // 以物理像素原位拷贝；现有裁剪区域仍由原画笔保留。
        ctx.setWorldTransform(inverse);
        ctx.setRenderHint(QPainter::SmoothPixmapTransform, false);
        ctx.setCompositionMode(QPainter::CompositionMode_Source);
        ctx.drawImage(cached->origin, cached->image);
        ++rasterHits;
    }
    ctx.restore();
    return invertible;
}

void Glyphs::clearRasterCache() {
    QMutexLocker lock(&mutex);
    rasterText.clear();
    rasterCandidates.clear();
    rasterScratch = QImage();
    rasterHits = 0;
}

int Glyphs::rasterCacheBytes() {
    QMutexLocker lock(&mutex);
    return rasterText.totalCost() + int(rasterScratch.sizeInBytes());
}

quint64 Glyphs::rasterCacheHits() {
    QMutexLocker lock(&mutex);
    return rasterHits;
}

void Glyphs::commands(QPainter &c, const QJsonArray &commands, std::function<QImage(QString)> image,
                      bool cacheText) {
    renderCommands(c, commands, std::move(image), cacheText);
}
#endif
