#include "PlaybackQueue.h"
#include <QCoreApplication>
#include <QDebug>
#include <QJsonArray>
#include <QJsonObject>

/**
 * 播放队列核心行为回归。
 * 只覆盖顺序、选中、入队、移除、切歌索引和会话顺序；元数据补全的边界场景不进入常驻测试。
 */
namespace {
QJsonObject song(const QString &id) {
    return QJsonObject{{"kind", "song"}, {"provider", "alpha"}, {"id", id}, {"title", "测试 " + id}};
}
} // namespace

int main(int argc, char **argv) {
    QCoreApplication application(argc, argv);
    int testCount = 0;
    bool passed = true;
    const auto check = [&](bool value, const char *name) {
        ++testCount;
        if (!value) {
            qCritical() << "Playback queue test failed:" << name;
            passed = false;
        }
    };

    PlaybackQueue queue(nullptr);

    // 替换只接受完整歌曲，按身份去重并保持输入顺序。
    queue.replace(QJsonArray{song("1"), song("2"), song("1"), QJsonObject{{"kind", "playlist"}}, song("3")},
                  song("2"));
    check(queue.size() == 3 && queue.indexOfId("1") == 0 && queue.indexOfId("2") == 1 &&
              queue.indexOfId("3") == 2,
          "replace filters non-songs, dedupes and keeps order");
    check(queue.index() == 1, "replace selects the requested track");
    check(queue.toJson() == queue.items(), "serialized queue matches visible items");

    // 选中与追加：已有曲目切换到原位置，未知曲目追加到队尾。
    queue.selectTrack(song("3"));
    check(queue.index() == 2, "selectTrack finds an existing track");
    queue.selectTrack(song("4"));
    check(queue.size() == 4 && queue.index() == 3, "selectTrack appends an unknown track");

    // 入队插到当前项之后或队尾，并移动已有曲目而不是重复保留。
    queue.replace(QJsonArray{song("1"), song("2"), song("3")}, song("2"));
    check(queue.enqueue(song("4")) && queue.size() == 4 && queue.at(3)["id"] == "4" && queue.index() == 1,
          "enqueue appends without changing the current track");
    check(queue.enqueue(song("1"), true), "play-next accepts an existing track");
    check(queue.at(0)["id"] == "2" && queue.at(1)["id"] == "1" && queue.index() == 0,
          "play-next moves an existing track behind the current one and fixes the index");
    check(queue.enqueue(song("2")) && queue.size() == 5 && queue.at(4)["id"] == "2" && queue.index() == 0,
          "enqueue keeps the playing track when it is added again");

    // 当前曲目不能被移除，移除前面的条目要同步索引。
    queue.replace(QJsonArray{song("1"), song("2"), song("3"), song("4")}, song("3"));
    check(!queue.remove(2), "the playing track cannot be removed");
    check(queue.remove(0) && queue.size() == 3 && queue.index() == 1 && queue.at(0)["id"] == "2",
          "removing an earlier track shifts the current index");
    check(!queue.remove(9), "out-of-range removal is ignored");

    // 清空待播只保留当前曲目。
    queue.clearUpcoming(song("3"));
    check(queue.size() == 1 && queue.at(0)["id"] == "3" && queue.index() == 0,
          "clear upcoming keeps only the current track");
    queue.clearUpcoming({});
    check(queue.isEmpty() && queue.index() == -1, "clear upcoming without a track empties the queue");

    // 切歌索引覆盖顺序、循环、单曲和随机的边界。
    queue.replace(QJsonArray{song("1"), song("2"), song("3")}, song("3"));
    check(queue.navigate(1, "off") == -1 && queue.index() == 2,
          "sequential playback stops after the last track");
    check(queue.navigate(1, "all") == 0 && queue.index() == 0, "list repeat wraps to the first track");
    check(queue.navigate(-1, "one") == 0 && queue.navigate(1, "one") == 0 && queue.index() == 0,
          "single repeat stays on the current track");
    check(queue.navigate(-1, "all") == 2 && queue.index() == 2,
          "previous from the first track wraps to the last");
    check(queue.navigate(-1, "off") == 1 && queue.index() == 1,
          "previous in sequential mode moves one track back");

    // 随机模式只在进入时打乱；预选、实际下一首与返回后的前进沿同一顺序。
    queue.replace(QJsonArray{song("1"), song("2"), song("3"), song("4"), song("5")}, song("2"));
    queue.setShuffle(true);
    const auto shuffled = queue.toJson();
    check(queue.index() == 0 && queue.current()["id"] == "2", "shuffle preserves the playing song");
    const auto upcoming = queue.at(queue.nextIndex("shuffle"));
    check(queue.nextIndex("shuffle") == 1 && queue.at(queue.nextIndex("shuffle")) == upcoming &&
              queue.toJson() == shuffled,
          "shuffle peek is stable and does not modify the queue");
    check(queue.navigate(1, "shuffle") == 1 && queue.current() == upcoming &&
              queue.navigate(-1, "shuffle") == 0 && queue.navigate(1, "shuffle") == 1 &&
              queue.current() == upcoming,
          "shuffle previous and next follow the same permutation");
    for (int index = 2; index < shuffled.size(); ++index) {
        check(queue.navigate(1, "shuffle") == index && queue.current() == shuffled.at(index).toObject(),
              "shuffle walks every song once");
    }
    check(queue.nextIndex("shuffle") == 0, "shuffle wraps along the same order");
    queue.restore(shuffled, 1, true);
    check(queue.toJson() == shuffled && queue.index() == 1, "session restore keeps shuffled order");
    queue.enqueue(song("6"), true);
    check(queue.at(queue.nextIndex("shuffle"))["id"] == "6", "explicit play-next precedes shuffle order");
    queue.setShuffle(false);

    // 服务端快照只同步顺序与索引，不改写曲目内容。
    queue.syncSnapshot(QJsonArray{song("5"), song("6")}, 1);
    check(queue.size() == 2 && queue.index() == 1 && queue.at(1)["id"] == "6",
          "snapshot replaces order and index");
    queue.clear();
    check(queue.isEmpty() && queue.index() == -1, "clear empties the queue");

    // 按 ID 顺序装载已加载曲目，保持当前歌曲身份。
    queue.replace(QJsonArray{song("1")}, song("1"));
    queue.load(QJsonArray{"3", "1", "2"}, QJsonArray{song("1"), song("2"), song("3")});
    check(queue.size() == 3 && queue.at(0)["id"] == "3" && queue.at(1)["id"] == "1" &&
              queue.at(2)["id"] == "2" && queue.index() == 1,
          "load orders known tracks by id list and keeps the current track");

    // 会话恢复使用完整曲目和存档索引。
    queue.restore(QJsonArray{song("1"), song("2")}, 1, false);
    check(queue.size() == 2 && queue.index() == 1 && queue.at(1)["id"] == "2",
          "restore keeps complete tracks and the saved index");

    qInfo() << "Playback queue core tests:" << testCount << (passed ? "passed" : "FAILED");
    return passed ? 0 : 1;
}
