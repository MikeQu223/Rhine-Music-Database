/**
 * 149：可见格业务资源投影的离线回归（Qt6::Core，无 GUI、无 GPU、无 QtTest）。
 *
 * 这些用例对应的都是真机上"看一眼就知道错了"的后果，所以判据必须能证伪：
 *   - 身份：位置（lane/row）绝不参与 key 计算，否则同一行换内容会沿用旧图。
 *   - 绝对行号：r 是窗口内偏移，原生 row=12+r，不许取模当成 0..7 的槽位。
 *   - 迟到完成：A→B→A 期间 B 的结果必须作废，否则旧封面贴到新身份上。
 *   - 准入：同一 key 重复上报不重置计时；滚动中一个都不开始；隐藏后待定作废、已准入保留。
 *   - 上界：待定数量、投影数量、淘汰规则都必须有界，且绝不淘汰还在窗口里的格。
 *
 * 运行（由 148 执行；149 不执行任何命令）：
 *   cmake --build <build-dir> --target RhineEmbeddedCellResources149Test
 *   ctest -R qt_embedded_cell_resources_149 --output-on-failure
 */
#include "render/EmbeddedCellResources.h"

#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonObject>
#include <QSet>
#include <QString>
#include <QStringList>

#include <initializer_list>

namespace {
int g_checks = 0;
int g_failures = 0;

QString num(qint64 value) {
    return QString::number(value);
}

bool check(bool result, const QString &what, const QString &expected, const QString &actual) {
    ++g_checks;
    if (!result) {
        ++g_failures;
        qWarning("[FAIL] %s expected=%s actual=%s", qPrintable(what), qPrintable(expected),
                 qPrintable(actual));
    }
    return result;
}

QJsonObject cell(int lane, int offset, const QString &kind, const QJsonValue &id,
                 const QString &title = {}, const QString &cover = {}, const QString &artist = {},
                 const QString &album = {}) {
    QJsonObject value{{"l", lane}, {"r", offset}, {"k", kind}, {"i", id}, {"t", title}};
    if (!cover.isEmpty()) {
        value["c"] = cover;
    }
    if (!artist.isEmpty()) {
        value["a"] = artist;
    }
    if (!album.isEmpty()) {
        value["b"] = album;
    }
    return value;
}

QStringList keysOf(const RhineRender::EmbeddedCellProjection &projection) {
    QStringList keys;
    for (const auto &entry : projection.cells) {
        keys.append(entry.key);
    }
    return keys;
}

// 1. 基本投影：身份、绝对行号、字段、顺序。
bool projectionBasics() {
    bool ok = true;
    QJsonArray cells{cell(2, 0, "song", 42, "夜航", "https://example.test/a.jpg", "歌手甲", "专辑乙"),
                     cell(3, 7, "album", "abc", "唱片")};
    const auto projection = RhineRender::projectEmbeddedCells(cells, 5);
    ok &= check(projection.cells.size() == 2, "projection size", "2",
                num(projection.cells.size()));
    ok &= check(projection.dropped == 0, "projection dropped", "0", num(projection.dropped));
    ok &= check(keysOf(projection) == QStringList({"siren:song:42", "siren:album:abc"}),
                "canonical keys", "siren:song:42,siren:album:abc", keysOf(projection).join(','));
    ok &= check(projection.cells.at(0).row == 12, "r=0 → row=12", "12",
                num(projection.cells.at(0).row));
    // 绝对行号：r=7 是第 19 行，不是 7 % 8 = 7。
    ok &= check(projection.cells.at(1).row == 19, "r=7 → row=19", "19",
                num(projection.cells.at(1).row));
    ok &= check(projection.cells.at(0).title == QStringLiteral("夜航"), "title kept", "夜航",
                projection.cells.at(0).title);
    ok &= check(projection.cells.at(0).artist == QStringLiteral("歌手甲"), "artist kept", "歌手甲",
                projection.cells.at(0).artist);
    ok &= check(projection.cells.at(0).album == QStringLiteral("专辑乙"), "album kept", "专辑乙",
                projection.cells.at(0).album);
    ok &= check(projection.cells.at(0).cover == QStringLiteral("https://example.test/a.jpg"),
                "cover kept", "https://example.test/a.jpg", projection.cells.at(0).cover);
    ok &= check(projection.cells.at(1).cover.isEmpty(), "missing cover is empty", "",
                projection.cells.at(1).cover);
    ok &= check(projection.signature.startsWith(QStringLiteral("ctx:5")), "signature carries context",
                "ctx:5", projection.signature.left(5));
    ok &= check(projection.cells.at(0).valid(), "projected cell valid", "true", "false");
    return ok;
}

// 2. 位置不是身份：同一行换内容有不同 key；重复 key 只留第一条。
bool identityIsNotPosition() {
    bool ok = true;
    // 同一个 (lane,row) 出现在两份不同内容里：key 由身份决定，与位置无关。
    const auto first = RhineRender::projectEmbeddedCells(
        QJsonArray{cell(1, 3, "song", 7, "第一首", "u1")}, 1);
    const auto second = RhineRender::projectEmbeddedCells(
        QJsonArray{cell(1, 3, "song", 9, "第二首", "u2")}, 1);
    ok &= check(first.cells.at(0).key != second.cells.at(0).key, "same position, different identity",
                "different", first.cells.at(0).key + " vs " + second.cells.at(0).key);
    // 同一个 key 出现在两个位置：保留第一条，第二条计入 dropped。
    const auto duplicate = RhineRender::projectEmbeddedCells(
        QJsonArray{cell(0, 0, "song", 7, "甲", "u1"), cell(4, 6, "song", 7, "乙", "u1")}, 1);
    ok &= check(duplicate.cells.size() == 1, "duplicate key collapsed", "1",
                num(duplicate.cells.size()));
    ok &= check(duplicate.cells.at(0).title == QStringLiteral("甲"), "duplicate keeps first", "甲",
                duplicate.cells.at(0).title);
    ok &= check(duplicate.dropped == 1, "duplicate counted", "1", num(duplicate.dropped));
    return ok;
}

// 3. 无效条目与上界：缺身份/位置越界不入表；超过 40 条只留前 40。
bool boundsAndRejects() {
    bool ok = true;
    QJsonObject noIdentity = cell(0, 0, "song", QJsonValue::Null, "无身份");
    QJsonObject noKind{{"l", 0}, {"r", 0}, {"i", 3}, {"t", "无 kind"}};
    QJsonObject badLane = cell(7, 0, "song", 1, "越界列");
    QJsonObject noOffset{{"l", 0}, {"k", "song"}, {"i", 2}, {"t", "无偏移"}};
    const auto rejected = RhineRender::projectEmbeddedCells(
        QJsonArray{noIdentity, noKind, badLane, noOffset}, 1);
    ok &= check(rejected.cells.isEmpty(), "rejected entries dropped", "0",
                num(rejected.cells.size()));
    ok &= check(rejected.dropped == 4, "rejected counted", "4", num(rejected.dropped));

    QJsonArray many;
    for (int index = 0; index < RhineRender::EmbeddedCellMaxCount + 5; ++index) {
        many.append(cell(index % 5, index / 5, "song", index, QStringLiteral("曲 %1").arg(index)));
    }
    const auto capped = RhineRender::projectEmbeddedCells(many, 1);
    ok &= check(capped.cells.size() == RhineRender::EmbeddedCellMaxCount, "projection capped", "40",
                num(capped.cells.size()));
    ok &= check(capped.dropped == 5, "capped overflow counted", "5", num(capped.dropped));
    ok &= check(capped.cells.first().key == QStringLiteral("siren:song:0"), "cap keeps first key",
                "siren:song:0", capped.cells.first().key);
    return ok;
}

// 4. 空内容：空快照是合法的，投影为空且签名仍带上下文（调用方据此清空原生侧身份）。
bool emptySnapshot() {
    bool ok = true;
    const auto empty = RhineRender::projectEmbeddedCells(QJsonArray{}, 9);
    ok &= check(empty.cells.isEmpty(), "empty projection", "0", num(empty.cells.size()));
    ok &= check(empty.signature == QStringLiteral("ctx:9"), "empty signature", "ctx:9",
                empty.signature);
    ok &= check(empty.empty(), "empty() true", "true", "false");
    return ok;
}

// 5. 迟到完成：A→B→A 必须只接受与"当前地址"一致的结果。
bool lateCompletionGuard() {
    bool ok = true;
    auto current = RhineRender::embeddedCellFrom(cell(0, 0, "song", 1, "甲", "urlA"));
    ok &= check(current.has_value(), "cell parsed", "true", "false");
    if (!current) {
        return false;
    }
    // 同一格先要 A（已发出），期间变成 B：A 的结果作废，B 的才有效。
    current->cover = QStringLiteral("urlB");
    ok &= check(!RhineRender::embeddedCellCoverStillWanted(&*current, QStringLiteral("urlA")),
                "late A after switch to B is rejected", "false", "true");
    ok &= check(RhineRender::embeddedCellCoverStillWanted(&*current, QStringLiteral("urlB")),
                "B accepted while current", "true", "false");
    // A→B→A：回到 A 之后，A 那次的结果重新有效，B 的结果必须丢弃。
    current->cover = QStringLiteral("urlA");
    ok &= check(RhineRender::embeddedCellCoverStillWanted(&*current, QStringLiteral("urlA")),
                "A again accepted after A→B→A", "true", "false");
    ok &= check(!RhineRender::embeddedCellCoverStillWanted(&*current, QStringLiteral("urlB")),
                "B rejected after A→B→A", "false", "true");
    // 空的"请求地址"永远不写回：那不是一次真实请求。
    ok &= check(!RhineRender::embeddedCellCoverStillWanted(&*current, QString()), "empty request",
                "false", "true");
    // 条目已经被移出投影（这一格没身份了）：任何结果都不许写回。
    ok &= check(!RhineRender::embeddedCellCoverStillWanted(nullptr, QStringLiteral("urlA")),
                "missing cell rejected", "false", "true");
    return ok;
}

// 6. 准入计时：同 key 重复上报不重置；到点才准入；计时在滚动中冻结。
bool admissionTiming() {
    bool ok = true;
    RhineRender::EmbeddedCellAdmission admission(500, 24, 8);
    const QStringList visible{QStringLiteral("siren:song:1"), QStringLiteral("siren:song:2")};
    auto report = admission.report(visible, 1, false, 1000);
    ok &= check(report.admitted == 0 && report.pending == 2, "nothing admitted at start", "0/2",
                num(report.admitted) + "/" + num(report.pending));
    ok &= check(report.started == 2, "two timers started", "2", num(report.started));
    // 反复上报（每帧一次）不能把起点往后推。
    for (qint64 now = 1016; now < 1499; now += 16) {
        admission.report(visible, 1, false, now);
    }
    ok &= check(admission.admittedCount() == 0, "still pending just before delay", "0",
                num(admission.admittedCount()));
    report = admission.report(visible, 1, false, 1500);
    ok &= check(report.admitted == 2, "both admitted at 500ms", "2", num(report.admitted));
    ok &= check(report.pending == 0, "no pending after admit", "0", num(report.pending));
    ok &= check(admission.nextAdmissionInMs(1500) == -1, "no next admission when idle", "-1",
                num(admission.nextAdmissionInMs(1500)));

    // 滚动中：新出现的格不开始计时，热 key 照常准入。
    const QStringList scrolled{QStringLiteral("siren:song:1"), QStringLiteral("siren:song:3")};
    report = admission.report(scrolled, 1, true, 1600);
    ok &= check(report.started == 0, "no timer starts while scrolling", "0", num(report.started));
    ok &= check(admission.isAdmitted(QStringLiteral("siren:song:1")), "hot key stays admitted",
                "true", "false");
    ok &= check(!admission.isPending(QStringLiteral("siren:song:3")), "no pending while scrolling",
                "false", "true");
    // 停下来才开始计时。
    report = admission.report(scrolled, 1, false, 2000);
    ok &= check(report.started == 1, "timer starts after scroll stops", "1", num(report.started));
    report = admission.report(scrolled, 1, false, 2500);
    ok &= check(admission.isAdmitted(QStringLiteral("siren:song:3")), "admitted after stop + delay",
                "true", "false");
    return ok;
}

// 7. 上下文切换：待定作废，已准入保留（同一业务身份再出现应立即复用）。
bool contextSwitchKeepsHot() {
    bool ok = true;
    RhineRender::EmbeddedCellAdmission admission(100, 24, 8);
    const QStringList visible{QStringLiteral("siren:song:1")};
    admission.report(visible, 1, false, 0);
    auto report = admission.report(visible, 1, false, 100);
    ok &= check(report.admitted == 1, "admitted in first context", "1", num(report.admitted));
    // 另一个目录：新 key 先待定，然后上下文又换回来。
    report = admission.report({QStringLiteral("siren:song:2")}, 2, false, 200);
    ok &= check(report.started == 1, "new context starts fresh timer", "1", num(report.started));
    report = admission.report(visible, 1, false, 220);
    ok &= check(admission.isAdmitted(QStringLiteral("siren:song:1")),
                "admitted key survives context switch", "true", "false");
    ok &= check(!admission.isPending(QStringLiteral("siren:song:2")),
                "pending dropped on context switch", "false", "true");
    return ok;
}

// 8. 隐藏：待定作废、已准入保留；恢复后重新计时。
bool hiddenParksAdmission() {
    bool ok = true;
    RhineRender::EmbeddedCellAdmission admission(100, 24, 8);
    const QStringList visible{QStringLiteral("siren:song:1"), QStringLiteral("siren:song:2")};
    admission.report(visible, 1, false, 0);
    admission.report(visible, 1, false, 100);
    ok &= check(admission.admittedCount() == 2, "both admitted before hiding", "2",
                num(admission.admittedCount()));
    admission.setVisible(false, 150);
    ok &= check(admission.pendingCount() == 0, "no pending while hidden", "0",
                num(admission.pendingCount()));
    ok &= check(admission.admittedCount() == 2, "admitted kept while hidden", "2",
                num(admission.admittedCount()));
    admission.setVisible(true, 200);
    // 恢复后新格从头计时：不是接着隐藏前的时间继续数。
    const QStringList restored{QStringLiteral("siren:song:1"), QStringLiteral("siren:song:3")};
    auto report = admission.report(restored, 1, false, 220);
    ok &= check(report.started == 1, "fresh timer after restore", "1", num(report.started));
    report = admission.report(restored, 1, false, 260);
    ok &= check(!admission.isAdmitted(QStringLiteral("siren:song:3")), "not admitted early",
                "false", "true");
    report = admission.report(restored, 1, false, 320);
    ok &= check(admission.isAdmitted(QStringLiteral("siren:song:3")), "admitted after delay",
                "true", "false");
    return ok;
}

// 9. 上界与淘汰：待定名额封顶；名额满时只淘汰窗口外的格，绝不抢在屏上的格。
bool admissionBounds() {
    bool ok = true;
    QStringList six;
    for (int index = 0; index < 6; ++index) {
        six.append(QStringLiteral("siren:song:%1").arg(index));
    }

    // 待定名额 2：先来先得，后四个连计时都不开始。
    RhineRender::EmbeddedCellAdmission capped(0, 8, 2);
    auto report = capped.report(six, 1, false, 10);
    ok &= check(report.started == 2, "only the first two start timing", "2", num(report.started));
    ok &= check(report.pending == 2, "pending capped at maxPending", "2", num(report.pending));
    ok &= check(report.dropped == 4, "overflow past maxPending counted as dropped", "4",
                num(report.dropped));
    ok &= check(report.admitted == 0, "nothing admitted on the starting report", "0",
                num(report.admitted));

    // 名额 2 且六格全在窗口里：到点也进不来，必须报 starved 而不是把在屏的格踢掉。
    RhineRender::EmbeddedCellAdmission full(0, 2, 8);
    report = full.report(six, 1, false, 10);
    ok &= check(report.started == 6, "all six start timing", "6", num(report.started));
    report = full.report(six, 1, false, 20);
    ok &= check(report.admitted == 2, "admitted capped at maxAdmitted", "2", num(report.admitted));
    ok &= check(report.starved == 4, "the rest report starved, not silently dropped", "4",
                num(report.starved));
    ok &= check(report.pending == 4, "starved keys stay pending", "4", num(report.pending));

    // 窗口换成 3、4：它们能进来，被淘汰的必须是已经离开窗口的 0/1。
    const QStringList moved{QStringLiteral("siren:song:3"), QStringLiteral("siren:song:4")};
    report = full.report(moved, 1, false, 30);
    ok &= check(full.admittedCount() == 2, "admitted stays capped", "2",
                num(full.admittedCount()));
    ok &= check(full.isAdmitted(QStringLiteral("siren:song:3")), "visible newcomer 3 admitted",
                "true", "false");
    ok &= check(full.isAdmitted(QStringLiteral("siren:song:4")), "visible newcomer 4 admitted",
                "true", "false");
    ok &= check(!full.isAdmitted(QStringLiteral("siren:song:0")), "offscreen 0 evicted", "false",
                "true");
    ok &= check(!full.isAdmitted(QStringLiteral("siren:song:1")), "offscreen 1 evicted", "false",
                "true");
    ok &= check(report.pending == 0, "no leftover pending after the window moves", "0",
                num(report.pending));

    // 名额被在屏格占满时：保持待定 + starved，且不安排唤醒（否则归档页永远睡不着）。
    RhineRender::EmbeddedCellAdmission tight(0, 1, 4);
    tight.report({QStringLiteral("siren:song:1")}, 1, false, 0);
    const auto tightReport =
        tight.report({QStringLiteral("siren:song:1"), QStringLiteral("siren:song:2")}, 1, false, 5);
    ok &= check(tight.isAdmitted(QStringLiteral("siren:song:1")), "visible admitted key kept",
                "true", "false");
    ok &= check(!tight.isAdmitted(QStringLiteral("siren:song:2")),
                "second visible key stays pending", "false", "true");
    ok &= check(tightReport.admitted == 1, "no overshoot past maxAdmitted", "1",
                num(tightReport.admitted));
    // delay=0 时"首次登记"那一帧只起算不下结论（起算分支直接 continue），所以必须再来一帧
    // 才走得到 admit()：第二帧才可能被判 starved。
    ok &= check(tightReport.starved == 0, "first sighting only starts the timer", "0",
                num(tightReport.starved));
    ok &= check(tightReport.pending == 1, "first sighting counts as pending", "1",
                num(tightReport.pending));
    const auto tightBlocked =
        tight.report({QStringLiteral("siren:song:1"), QStringLiteral("siren:song:2")}, 1, false, 6);
    ok &= check(tightBlocked.starved == 1, "blocked admission reported starved", "1",
                num(tightBlocked.starved));
    ok &= check(tightBlocked.pending == 1, "blocked admission stays pending", "1",
                num(tightBlocked.pending));
    ok &= check(tight.nextAdmissionInMs(6) == -1, "starved entry schedules no wake", "-1",
                num(tight.nextAdmissionInMs(6)));
    return ok;
}

// 10. 时钟回退：起点在未来（重建/回卷）时重新起算，不许"立刻准入"。
bool clockRollback() {
    bool ok = true;
    RhineRender::EmbeddedCellAdmission admission(100, 24, 8);
    const QStringList visible{QStringLiteral("siren:song:1")};
    admission.report(visible, 1, false, 5000);
    auto report = admission.report(visible, 1, false, 40);
    ok &= check(report.admitted == 0, "no admission on rolled-back clock", "0",
                num(report.admitted));
    ok &= check(admission.isPending(QStringLiteral("siren:song:1")), "timer restarted", "true",
                "false");
    report = admission.report(visible, 1, false, 140);
    ok &= check(admission.isAdmitted(QStringLiteral("siren:song:1")), "admitted after full delay",
                "true", "false");
    return ok;
}

// 11. draw id：每格每槽稳定且互不相同，且不会与 actor / 实例缓冲编号相撞。
bool drawIdStable() {
    bool ok = true;
    const auto a = RhineRender::embeddedCellId(0, 12);
    const auto b = RhineRender::embeddedCellId(1, 12);
    const auto same = RhineRender::embeddedCellId(0, 12);
    ok &= check(a == same, "cell id stable", num(a), num(same));
    ok &= check(a != b, "cell id distinct per lane", num(a), num(b));
    ok &= check(a == (0u << 16 | 12u), "cell id encoding = lane<<16|row", "12", num(a));
    ok &= check(RhineRender::embeddedCellId(2, 19) == (2u << 16 | 19u), "cell id row not modulo",
                num(2u << 16 | 19u), num(RhineRender::embeddedCellId(2, 19)));
    const int plate = RhineRender::embeddedCellDrawId(a, 0);
    const int label = RhineRender::embeddedCellDrawId(a, 1);
    ok &= check(plate == RhineRender::embeddedCellDrawId(a, 0), "plate draw id stable", num(plate),
                num(RhineRender::embeddedCellDrawId(a, 0)));
    ok &= check(plate != label, "plate/label draw ids differ", num(plate), num(label));
    ok &= check(plate < -10, "draw id avoids floor(1)/instances(10)", "< -10", num(plate));
    // actor 区间是 -(id*256 + part)，plate 区间必须离得够远（哪怕 id 很大）。
    ok &= check(plate != -int(4096 * 256 + 3), "draw id avoids actor range",
                num(-int(4096 * 256 + 3)), num(plate));
    QSet<int> ids;
    for (int lane = 0; lane < 5; ++lane) {
        for (int row = 12; row < 20; ++row) {
            const auto cellId = RhineRender::embeddedCellId(lane, row);
            ids.insert(RhineRender::embeddedCellDrawId(cellId, 0));
            ids.insert(RhineRender::embeddedCellDrawId(cellId, 1));
        }
    }
    ok &= check(ids.size() == 5 * 8 * 2, "40 cells → 80 distinct draw ids", "80", num(ids.size()));
    return ok;
}

// 12. 一帧记账：真实 = 有自己封面的格；占位 = 没有。这是"本帧 N 真实/M 占位"的唯一口径。
bool bindingCounts() {
    bool ok = true;
    const QStringList order{QStringLiteral("siren:song:1"), QStringLiteral("siren:song:2"),
                            QStringLiteral("siren:song:3"), QString()};
    const QSet<QString> admitted{QStringLiteral("siren:song:1"), QStringLiteral("siren:song:2")};
    const QSet<QString> covers{QStringLiteral("siren:song:1")};
    const QSet<QString> labels{QStringLiteral("siren:song:1"), QStringLiteral("siren:song:2")};
    const auto binding = RhineRender::embeddedCellBinding(order, admitted, covers, labels);
    ok &= check(binding.visible == 3, "visible ignores empty key", "3", num(binding.visible));
    ok &= check(binding.admitted == 2, "admitted count", "2", num(binding.admitted));
    ok &= check(binding.covers == 1, "real covers", "1", num(binding.covers));
    ok &= check(binding.labels == 2, "labels", "2", num(binding.labels));
    // 只有标签、没有封面仍然是占位：用户看到的是一张白纸板。
    ok &= check(binding.placeholders == 2, "placeholders = visible - covers", "2",
                num(binding.placeholders));
    ok &= check(binding.covers + binding.placeholders == binding.visible, "partition", "3",
                num(binding.covers + binding.placeholders));
    return ok;
}

// 13. "URL 共享、身份隔离"：两张不同的格用同一个封面地址，key 必须各是各的。
bool sharedUrlSeparateIdentity() {
    bool ok = true;
    const auto projection = RhineRender::projectEmbeddedCells(
        QJsonArray{cell(0, 0, "song", 1, "甲", "https://example.test/same.jpg"),
                   cell(0, 1, "song", 2, "乙", "https://example.test/same.jpg")},
        1);
    ok &= check(projection.cells.size() == 2, "two cells with shared cover url", "2",
                num(projection.cells.size()));
    ok &= check(projection.cells.at(0).cover == projection.cells.at(1).cover, "same cover url",
                "equal", "different");
    ok &= check(projection.cells.at(0).key != projection.cells.at(1).key,
                "identity stays separate for shared url", "different",
                projection.cells.at(0).key + " vs " + projection.cells.at(1).key);
    // 签名里必须同时带上身份与地址：只改地址（同身份换封面）也要算新的一批。
    const auto urlChanged = RhineRender::projectEmbeddedCells(
        QJsonArray{cell(0, 0, "song", 1, "甲", "https://example.test/other.jpg")}, 1);
    ok &= check(urlChanged.signature != projection.signature, "cover url changes signature",
                "different", "same");
    return ok;
}

// 13b. M2 反例回归：同一格（l/r/k/i/t 全同）只换封面地址，必须算新的一批——
// 否则 projectEmbeddedCells 会把这次 apply 当重复帧直接 no-op，旧封面永久留在屏上。
bool changedCoverSameKey() {
    bool ok = true;
    const auto first = RhineRender::projectEmbeddedCells(
        QJsonArray{cell(2, 3, "song", 7, "同格", "https://example.test/a.jpg")}, 9);
    const auto second = RhineRender::projectEmbeddedCells(
        QJsonArray{cell(2, 3, "song", 7, "同格", "https://example.test/b.jpg")}, 9);
    ok &= check(first.cells.size() == 1 && second.cells.size() == 1, "one cell each", "1",
                num(first.cells.size()) + "/" + num(second.cells.size()));
    ok &= check(first.cells.at(0).key == second.cells.at(0).key, "identity unchanged", "equal",
                first.cells.at(0).key + " vs " + second.cells.at(0).key);
    ok &= check(first.cells.at(0).row == second.cells.at(0).row, "position unchanged", "15",
                num(second.cells.at(0).row));
    ok &= check(first.signature != second.signature, "same identity + new cover url is a new batch",
                "different", "same");
    // 切到 B 以后，A 的迟到结果不许贴回来；切回 A 时反过来同理。
    ok &= check(!RhineRender::embeddedCellCoverStillWanted(&second.cells.at(0),
                                                           QStringLiteral("https://example.test/a.jpg")),
                "late A rejected once B is current", "false", "true");
    ok &= check(RhineRender::embeddedCellCoverStillWanted(&second.cells.at(0),
                                                          QStringLiteral("https://example.test/b.jpg")),
                "current B accepted", "true", "false");
    const auto back = RhineRender::projectEmbeddedCells(
        QJsonArray{cell(2, 3, "song", 7, "同格", "https://example.test/a.jpg")}, 9);
    ok &= check(RhineRender::embeddedCellCoverStillWanted(&back.cells.at(0),
                                                          QStringLiteral("https://example.test/a.jpg")),
                "back to A accepts A again", "true", "false");
    ok &= check(!RhineRender::embeddedCellCoverStillWanted(&back.cells.at(0),
                                                           QStringLiteral("https://example.test/b.jpg")),
                "and rejects B", "false", "true");
    return ok;
}

// 14. 数字身份与字符串身份落成同一种 key 文本（Song.id 可能是 int，Album.id 可能是串）。
bool identityFormats() {
    bool ok = true;
    const auto numeric = RhineRender::embeddedCellFrom(cell(0, 0, "song", 42));
    const auto textual = RhineRender::embeddedCellFrom(cell(0, 0, "song", QStringLiteral("42")));
    ok &= check(numeric.has_value() && textual.has_value(), "both parsed", "true", "false");
    if (!numeric || !textual) {
        return false;
    }
    ok &= check(numeric->key == QStringLiteral("siren:song:42"), "numeric id key",
                "siren:song:42", numeric->key);
    ok &= check(textual->key == QStringLiteral("siren:song:42"), "string id key",
                "siren:song:42", textual->key);
    ok &= check(RhineRender::embeddedCellKey({}, QStringLiteral("1")).isEmpty(), "empty kind → no key",
                "", RhineRender::embeddedCellKey({}, QStringLiteral("1")));
    ok &= check(RhineRender::embeddedCellKey(QStringLiteral("song"), {}) .isEmpty(),
                "empty id → no key", "",
                RhineRender::embeddedCellKey(QStringLiteral("song"), {}));
    return ok;
}

} // namespace

int main(int argc, char **argv) {
    QCoreApplication application(argc, argv);
    bool ok = true;
    ok &= projectionBasics();
    ok &= identityIsNotPosition();
    ok &= boundsAndRejects();
    ok &= emptySnapshot();
    ok &= lateCompletionGuard();
    ok &= admissionTiming();
    ok &= contextSwitchKeepsHot();
    ok &= hiddenParksAdmission();
    ok &= admissionBounds();
    ok &= clockRollback();
    ok &= drawIdStable();
    ok &= bindingCounts();
    ok &= sharedUrlSeparateIdentity();
    ok &= changedCoverSameKey();
    ok &= identityFormats();
    if (g_failures > 0) {
        qWarning("embedded cell resources: %d/%d checks failed", g_failures, g_checks);
        return 1;
    }
    qInfo("embedded cell resources: %d checks passed", g_checks);
    return 0;
}
