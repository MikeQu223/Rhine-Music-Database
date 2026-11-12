import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'basic/basic_app.dart';

/// Siren 基本版入口：不接三平台账号，不再使用 counter 模板。
///
/// 沉浸式与方向交给宿主：这里只隐藏系统栏，不锁定方向——
/// 横竖屏切换由 [BasicApp] 内的 `LayoutBuilder` 分支处理（见 basic_app.dart）。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const BasicApp());
}
