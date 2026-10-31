// C03：Qt Quick 同步阶段「这份场景快照还能不能复用」的判断。渲染器与用例共用同一份实现。
//
// 同步阶段原来每帧无条件地取一遍帧、draw 缓冲区、当前条目、封面与根 key，再往帧里写两个
// 字段（每次写都要 detach 整份对象）。这些内容只在场景版本、几何版本或光照开关变化时才变，
// 所以先比较签名，签名相同就直接复用上一份，省下每帧的复制与两次 detach。
//
// 必须把光照算进签名：开灯/关灯会改变装配体的烘焙结果，但场景版本本身可能没前进；
// 也要把几何版本算进来：装配体在等标签/封面到齐时会重算，版本前进而可见内容不变。
#pragma once

#include <QtGlobal>

namespace RhineRender {

struct SceneSyncSignature {
    quint64 revision = 0;
    quint64 geometryRevision = 0;
    bool lighting = false;

    bool operator==(const SceneSyncSignature &other) const
    {
        return revision == other.revision && geometryRevision == other.geometryRevision
               && lighting == other.lighting;
    }
    bool operator!=(const SceneSyncSignature &other) const { return !(*this == other); }
};

/// 签名完全相同才复用上一份快照；任何一项变化都要重新取，宁可多拷一次也不能画旧画面。
inline bool sceneSyncReusable(const SceneSyncSignature &cached, const SceneSyncSignature &current)
{
    return cached == current;
}

} // namespace RhineRender
