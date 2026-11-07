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
#ifdef Q_OS_LINUX
#include <QElapsedTimer>
#include <QStringList>
#include <algorithm>
#endif
#include <QRadialGradient>
#include <QRegularExpression>
#include <cmath>
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
    // 缓存键原来是「把四个参数序列化成一份 JSON」。width() 在每帧的 fit / inset / 裁剪判断里
    // 被调很多次，JSON 序列化 + UTF-8 往返比查缓存本身还贵。改成定界符拼接：'g',17 保证
    // double 往返精确，文本放最后且数字字段不含 U+001F，因此与原来逐项等价、不会碰撞。
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
    // 同 width()：别再用「序列化成 JSON」当键。歌词整段文本做键时，序列化本身
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
    QMutexLocker lock(&mutex);
    c.setRenderHints(QPainter::Antialiasing | QPainter::SmoothPixmapTransform);
#ifdef Q_OS_LINUX
    // 分段探针（RHINE_HUD_PROBE=1）：按操作类型累计 QPainter 耗时，判断该缓存哪一类。
    static const bool opTiming = qEnvironmentVariableIntValue("RHINE_HUD_PROBE") == 1;
    static QHash<QString, double> opMs;
    static int opFrames = 0;
    QElapsedTimer opClock;
#endif
    for (auto v : commands) {
        const auto a = v.toArray();
        auto op = a[0].toString();
        auto n = [&](int i) { return a[i].toDouble(); };
#ifdef Q_OS_LINUX
        if (opTiming) {
            opClock.start();
        }
#endif
        if (op == "save") {
            c.save();
        } else if (op == "restore") {
            c.restore();
        } else if (op == "alpha") {
            c.setOpacity(c.opacity() * n(1));
        } else if (op == "translate") {
            c.translate(n(1), n(2));
        } else if (op == "scale") {
            c.scale(n(1), n(2));
        } else if (op == "rotate") {
            c.rotate(n(1) * 180 / 3.14159265358979323846);
        } else if (op == "clip") {
            c.setClipRect(QRectF(n(1), n(2), n(3), n(4)), Qt::IntersectClip);
        } else if (op == "fill") {
            c.fillRect(QRectF(n(2), n(3), n(4), n(5)), color(a[1]));
        } else if (op == "ellipse") {
            c.setPen(Qt::NoPen);
            c.setBrush(color(a[1]));
            c.drawEllipse(QRectF(n(2), n(3), n(4), n(5)));
        } else if (op == "text") {
            text(c, a[1].toString(), n(2), n(3), n(4), a[5].toString(), n(6), color(a[7]));
        } else if (op == "art") {
            c.setBrush(color(a[7]));
            art(c, a[1].toString(), n(2), n(3), n(4), a[5].toInt(-1), n(6));
        } else if (op == "fill-path") {
            // 实心几何图标不受字体字形边距影响。
            c.fillPath(path(a[1].toString()), color(a[2]));
        } else if (op == "path") {
            QPen pen(color(a[3]), n(2), Qt::SolidLine, Qt::FlatCap, Qt::MiterJoin);
            auto dash = a[4].toArray();
            QList<qreal> d;
            for (auto x : dash) {
                d << x.toDouble() / qMax(n(2), .0001);
            }
            if (!d.isEmpty()) {
                pen.setDashPattern(d);
                pen.setDashOffset(n(5) / qMax(n(2), .0001));
            }
            c.setPen(pen);
            c.setBrush(Qt::NoBrush);
            c.drawPath(path(a[1].toString()));
        } else if (op == "arc") {
            QPainterPath p;
            QRectF r(n(1) - n(3), n(2) - n(3), n(3) * 2, n(3) * 2);
            p.arcMoveTo(r, -n(4) * 180 / 3.14159265358979323846);
            p.arcTo(r, -n(4) * 180 / 3.14159265358979323846, -n(5) * 180 / 3.14159265358979323846);
            c.setPen(QPen(color(a[7]), n(6), Qt::SolidLine, Qt::RoundCap));
            c.setBrush(Qt::NoBrush);
            c.drawPath(p);
        } else if (op == "right-mask") {
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
            auto img = image(a[1].toString());
            if (!img.isNull()) {
                c.drawImage(QRectF(n(2), n(3), n(4), n(5)), img);
            }
        }
#ifdef Q_OS_LINUX
        if (opTiming) {
            opMs[op] += double(opClock.nsecsElapsed()) / 1e6;
        }
    }
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
#endif
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
