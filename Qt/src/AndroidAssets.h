#pragma once
#include <QString>

// Android 把随包资源装在 APK 的 assets/ 里，只有 Qt 的 asset 文件引擎能直接读；
// Node 运行时与 QFontDatabase 需要真实路径，所以要解包到应用私有目录。
//
// 返回值是解包后的资源根目录（含 slots.json 的那一层），失败时为空字符串。
// 同一进程内只解包一次，后续调用直接返回缓存结果。
QString androidResourceRoot();

// 解包目标目录（应用私有目录下的 resources），供日志与诊断使用。
QString androidResourceTarget();
