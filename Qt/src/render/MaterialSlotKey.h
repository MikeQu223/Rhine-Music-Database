// C02：材质槽的键。渲染器用它查「这条 draw 的 uniform/纹理绑定槽」，渲染策略用例用它
// 验证键的等价关系。放在 header 里是因为它必须能被离线用例直接 include（只用 Qt6::Core）。
//
// 原来的键是每帧现拼的 QString（"id/mesh/name"）：一帧二十条 draw、每条每帧一次分配，
// 再对整串做哈希。改成整数 id/mesh 加短名字之后不再有临时分配；名字仍然参与比较，
// 因为同一个装配 draw 换上不同材质时 id/mesh 可能不变。
#pragma once

#include <QHashFunctions>
#include <QString>

namespace RhineRender {

struct MaterialSlotKey {
    int id = 0;
    int mesh = 0;
    QString name;

    bool operator==(const MaterialSlotKey &other) const
    {
        return id == other.id && mesh == other.mesh && name == other.name;
    }
    bool operator!=(const MaterialSlotKey &other) const { return !(*this == other); }
};

inline size_t qHash(const MaterialSlotKey &key, size_t seed = 0)
{
    return qHashMulti(seed, key.id, key.mesh, key.name);
}

} // namespace RhineRender
