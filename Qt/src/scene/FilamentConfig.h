#pragma once

#include "FilamentContract.h"

#include <QString>

namespace RhineFilament {

/** 三层开关的判定结果。判定顺序见 resolveConfig() 的实现注释。 */
struct Config {
    bool requested = false;   // 是否走 Filament 链路
    bool legacyForced = false;  // 是否被自检/离线参数强制回旧链路
    QString source;           // "cmake-off" | "legacy-forced" | "env" | "preference" | "off"
    QString describe() const;
};

/**
 * 解析当前是否启用 Filament。
 *
 * 优先级（高到低）：强制旧链路（--self-test/--visual-fixtures/--ui-self-test/--offline）
 *                → 编译期 RHINE_FILAMENT（未编入则永远关闭）
 *                → 环境变量 RHINE_FILAMENT
 *                → 偏好 filament。
 */
Config resolveConfig(const QString &preferenceValue, bool legacyOnly);
/** 编译期是否带 Filament。 */
bool compiledIn();

}  // namespace RhineFilament
