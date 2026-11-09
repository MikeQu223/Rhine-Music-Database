/// T24-S04 账号凭据存储：对齐 Qt 的 cookie 会话文件与逐来源登出。
///
/// 契约来源（逐条带 Qt 行号）：
/// - Qt/src/PlatformAndroid.cpp:10-46：account.credential 的路径、读、写（空串=成功）、
///   ReadOwner|WriteOwner 权限、删除。
/// - Qt/src/Host.cpp:541-553：hasCredential 逐来源判定（qq=qqmusic_session、
///   netease=MUSIC_U、kugou=__kugou[edition].token 且 userid>0，其余来源恒 false）。
/// - Qt/src/Host.cpp:599-605：saveCredential 返回空串表示成功，非空是给用户看的提示。
/// - Qt/src/Host.cpp:609-662：logout 逐来源清理；清理后 cookies 为空才删文件，否则重写。
/// - Qt/src/Host.cpp:517-530：cookie 更新后若任一来源仍已认证则立即持久化。
///
/// 任务契约禁止执行 flutter/dart test/analyze；本文件只编写、不运行，RED/GREEN 均未执行。
library;

import 'dart:convert';
import 'dart:io';

import 'login_session.dart';

/// 凭据文件的系统边界（Qt 的 PlatformAndroid.cpp 三个自由函数）。
///
/// 独立端口便于注入假实现，避免测试触碰真实文件系统。
abstract class CredentialStorage {
  /// PlatformAndroid.cpp:14-19 platformCredential()：打不开时返回空字节。
  List<int> read(String path);

  /// PlatformAndroid.cpp:23-33：把 bytes 写进 path（WriteOnly|Truncate 语义）。
  /// 返回实际写入字节数；无法创建/打开目标文件时返回 -1。
  int write(String path, List<int> bytes);

  /// PlatformAndroid.cpp:35：QFile::setPermissions(ReadOwner|WriteOwner)。
  void setOwnerReadWrite(String path);

  /// PlatformAndroid.cpp:44-46 platformDeleteCredential()。
  void remove(String path);

  /// PlatformAndroid.cpp:25 QDir().mkpath(directory)。
  bool ensureDirectory(String path);
}

/// 使用 dart:io 的生产实现；不引入任何新依赖。
class FileCredentialStorage implements CredentialStorage {
  const FileCredentialStorage();

  @override
  List<int> read(String path) {
    try {
      final File file = File(path);
      if (!file.existsSync()) {
        return const <int>[];
      }
      return file.readAsBytesSync();
    } on FileSystemException {
      return const <int>[];
    }
  }

  @override
  int write(String path, List<int> bytes) {
    try {
      final RandomAccessFile handle = File(path).openSync(mode: FileMode.write);
      try {
        handle.writeFromSync(bytes);
      } finally {
        handle.closeSync();
      }
      return bytes.length;
    } on FileSystemException {
      return -1;
    }
  }

  @override
  void setOwnerReadWrite(String path) {
    try {
      // Dart 没有 chmod API；沿用 Qt 的 ReadOwner|WriteOwner 语义（0600）。
      Process.runSync('chmod', <String>['600', path]);
    } on ProcessException {
      // 无 chmod 的平台保持默认权限，与 Qt 在无权限接口平台的行为一致。
    } on FileSystemException {
      // 同上。
    }
  }

  @override
  void remove(String path) {
    try {
      final File file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } on FileSystemException {
      // Qt QFile::remove 失败同样静默。
    }
  }

  @override
  bool ensureDirectory(String path) {
    try {
      Directory(path).createSync(recursive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }
}

/// Qt Host 的 cookie 会话文件（Host.cpp:159 cookies + PlatformAndroid.cpp:10-46）。
class CredentialStore implements CredentialPort {
  CredentialStore({required this.storage, required this.directory});

  /// PlatformAndroid.cpp:11 的文件名。
  static const String credentialFileName = 'account.credential';

  /// PlatformAndroid.cpp:22 的失败提示；空串才是成功。
  static const String unwritableNote = '登录成功，但 Android 凭据当前不可写';

  final CredentialStorage storage;

  /// AppStorage::dataDirectory() 的对应物。
  final String directory;

  /// Host.cpp:159 cookies。
  Map<String, Object?> cookies = <String, Object?>{};

  /// Host.cpp:586 kugouEdition；hasCredential("kugou") 依赖当前版本。
  KugouEdition edition = KugouEdition.standard;

  /// Host.cpp:600/603 offline 与远端分支在本卡不接线，默认离线直写文件。
  bool offline = false;

  /// PlatformAndroid.cpp:11 的 credentialPath()。
  String get path => '$directory/$credentialFileName';

  /// Host.cpp:62-63：启动时读取既有 cookie 文件（缺失/损坏即空 jar）。
  void load() {
    final List<int> bytes = storage.read(path);
    if (bytes.isEmpty) {
      cookies = <String, Object?>{};
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      decoded = null;
    }
    cookies = decoded is Map ? Map<String, Object?>.from(decoded) : <String, Object?>{};
  }

  /// Host.cpp:541-553 hasCredential（remote 分支不属本卡）。
  @override
  bool hasCredential(AccountProvider source) {
    switch (source) {
      case AccountProvider.qq:
        return _text(cookies['qqmusic_session']).isNotEmpty;
      case AccountProvider.netease:
        return _text(cookies['MUSIC_U']).isNotEmpty;
      case AccountProvider.kugou:
        final Object? editions = cookies['__kugou'];
        if (editions is! Map) {
          return false;
        }
        final Object? credential = editions[edition.wire];
        if (credential is! Map) {
          return false;
        }
        return _text(credential['token']).isNotEmpty && _unsigned(credential['userid']) > 0;
      case AccountProvider.local:
      case AccountProvider.siren:
        return false;
    }
  }

  /// Host.cpp:599-605 saveCredential：空串=成功。
  @override
  String saveCredential() {
    if (offline) {
      return '';
    }
    final List<int> bytes = utf8.encode(jsonEncode(cookies));
    if (!storage.ensureDirectory(directory)) {
      return unwritableNote;
    }
    final int written = storage.write(path, bytes);
    if (written < 0) {
      return unwritableNote;
    }
    storage.setOwnerReadWrite(path);
    return written == bytes.length ? '' : unwritableNote;
  }

  /// PlatformAndroid.cpp:44-46。
  @override
  void deleteCredential() => storage.remove(path);

  /// Host.cpp:609-662 的逐来源清理（不含 Qt 的媒体/列表副作用，那些属其它卡）。
  @override
  void logoutSource(AccountProvider source, KugouEdition kugouEdition) {
    switch (source) {
      case AccountProvider.qq:
        cookies.remove('qqmusic_session');
        cookies.remove('__qqSessions');
        break;
      case AccountProvider.kugou:
        final Object? raw = cookies['__kugou'];
        final Map<String, Object?> editions =
            raw is Map ? Map<String, Object?>.from(raw) : <String, Object?>{};
        editions.remove(kugouEdition.wire);
        if (editions.isEmpty) {
          cookies.remove('__kugou');
        } else {
          cookies['__kugou'] = editions;
        }
        break;
      case AccountProvider.netease:
      case AccountProvider.local:
      case AccountProvider.siren:
        // Host.cpp:631-641：保留其它来源会话，仅清空其余 cookie。
        final Object? kugou = cookies['__kugou'];
        final Object? token = cookies['qqmusic_session'];
        final Object? sessions = cookies['__qqSessions'];
        cookies.clear();
        if (kugou != null) {
          cookies['__kugou'] = kugou;
        }
        if (token != null) {
          cookies['qqmusic_session'] = token;
        }
        if (sessions != null) {
          cookies['__qqSessions'] = sessions;
        }
        break;
    }
    persistAfterLogout();
  }

  /// Host.cpp:655-661：offline 时整段跳过（Qt 的 if (!offline) 守卫）；
  /// cookies 为空 → 删文件，否则重写文件。
  void persistAfterLogout() {
    if (offline) {
      return;
    }
    if (cookies.isEmpty) {
      deleteCredential();
      return;
    }
    saveCredential();
  }

  /// Host.cpp:517-530：cookie 变化后，只要任一来源仍已认证就立即落盘，
  /// 避免下次启动读到过期会话。返回值同 saveCredential（空串=未写或成功）。
  String setCookie(String name, Object? value) {
    final Object? previous = cookies[name];
    final bool changed = !_sameValue(previous, value);
    if (value == null) {
      cookies.remove(name);
    } else {
      cookies[name] = value;
    }
    if (!changed) {
      return '';
    }
    if (hasCredential(AccountProvider.qq) ||
        hasCredential(AccountProvider.netease) ||
        hasCredential(AccountProvider.kugou)) {
      return saveCredential();
    }
    return '';
  }

  /// 供 cookie 容器类调用：整块替换后按 Host.cpp:517-530 决定是否落盘。
  /// 与 Qt 相同，内容没有变化时不写盘（Host.cpp:510/522/527 都以 changed 为前提）。
  String replaceCookies(Map<String, Object?> next) {
    if (_sameJar(cookies, next)) {
      return '';
    }
    cookies = Map<String, Object?>.from(next);
    if (hasCredential(AccountProvider.qq) ||
        hasCredential(AccountProvider.netease) ||
        hasCredential(AccountProvider.kugou)) {
      return saveCredential();
    }
    return '';
  }
}

String _text(Object? value) => value is String ? value : '';

bool _sameValue(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return jsonEncode(a) == jsonEncode(b);
  }
  return a == b;
}

/// 顶层键序无关的 jar 比较：QJsonObject 的相等与插入顺序无关，
/// 因此整块替换后"值未变"必须按内容判断，不能只看 jsonEncode 的字节。
bool _sameJar(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) {
    return false;
  }
  for (final String key in a.keys) {
    if (!b.containsKey(key) || !_sameValue(a[key], b[key])) {
      return false;
    }
  }
  return true;
}

/// Host.cpp:541-553：userid 经 toString().toULongLong()，数字与字符串都要接受。
int _unsigned(Object? value) {
  if (value is int) {
    return value > 0 ? value : 0;
  }
  if (value is num) {
    final int truncated = value.toInt();
    return truncated > 0 ? truncated : 0;
  }
  if (value is String) {
    return int.tryParse(value) ?? 0;
  }
  return 0;
}
