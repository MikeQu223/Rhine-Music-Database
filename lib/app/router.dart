/// Qt→Flutter 迁移的路由表：§6.1 的页面与 §6.2 的弹层，均为纯字符串。
///
/// 本文件不 import 任何东西。一条路由只是 kind + name + path，因此同一张表既能
/// 驱动 Flutter Navigator，也能在离线测试或非 Flutter 宿主里使用。这里刻意不出现
/// 任何 Flutter 类型：它只负责命名，不负责渲染。
///
/// 页面 19 行、弹层 16 项；路径分别是 '/' + name 和 '/modal/' + name。其中八个弹层
/// 名带 `modal-` 前缀，用来和同名页面区分（§6.2 自己也写 "saved/个人库"）。
/// 前缀只属于本表：引擎的 `modal` 值与协议字符串必须保持裸 §6.2 字面量，因为 Qt
/// 把 `kind` 原样拷进 `modal`（Qt/src/NativeHudController.cpp:64-88），再按 'search'、
/// 'saved'、'player'、'queue'、'settings'、'discover'、'login'、'desktop-lyrics'
/// 比较（见同文件及 NativeHudMusic.cpp:284、NativeHudDesktopLyrics.cpp:130）。
/// 不允许把 `modal-` 名字发过桥。
///
/// 两条不变量：
/// * 返回键在 Flutter 路由之外裁决。Qt 从自身状态推导返回，这些路由只是名字，
///   不是 pop 栈。
/// * 名字是跨旋转稳定的身份，不是布局。旋转保留 modal 名与关闭进度，因此这些
///   字符串是固定标识，不能按方向改名。
library;

/// Which namespace a [RhineRoute] belongs to.
enum RhineRouteKind {
  /// A page: one row of §6.1, path '/name'.
  page,

  /// A modal layer above the current page: one entry of §6.2, path
  /// '/modal/name'. The page beneath keeps rendering; the modal is a layer,
  /// not a replacement.
  modal,
}

/// One table row: a [kind], a [name] and a [path].
///
/// Routes are const table rows, not value objects: [RhineRoutes.byName] and
/// [RhineRoutes.byPath] return the canonical instances, and `==` stays
/// identity on purpose, so a host cannot mint a look-alike route equal to a
/// table entry.
class RhineRoute {
  /// Const, so the three lists in [RhineRoutes] are const and every entry is
  /// canonical.
  const RhineRoute({
    required this.kind,
    required this.name,
    required this.path,
  });

  /// Page or modal layer.
  final RhineRouteKind kind;

  /// Identifier a host navigates by; unique across [RhineRoutes.all].
  final String name;

  /// Location a host exposes; unique across [RhineRoutes.all].
  final String path;
}

/// The port's single route table, as const data.
///
/// Pages keep §6.1 row order and modals keep §6.2 entry order, so this file
/// can be read against the spec without a sorting step. [all] is [pages] then
/// [modals], and every name and every path in it is unique. The two path
/// prefixes ('/' and '/modal/') keep the namespaces disjoint before the
/// `modal-` rename even applies, so [byPath] never has to prefer a kind.
///
/// A namespace only: every member is static and nothing here is instantiated,
/// hence `abstract final`.
abstract final class RhineRoutes {
  /// The nineteen pages of §6.1 (:331-349), in row order.
  static const List<RhineRoute> pages = [
    // Consent 隐私门槛.
    RhineRoute(kind: RhineRouteKind.page, name: 'consent', path: '/consent'),
    // Boot.
    RhineRoute(kind: RhineRouteKind.page, name: 'boot', path: '/boot'),
    // Archive/首页, five lanes and the directory stack.
    RhineRoute(kind: RhineRouteKind.page, name: 'archive', path: '/archive'),
    // 目录空态, the empty directory state.
    RhineRoute(
      kind: RhineRouteKind.page,
      name: 'directory-empty',
      path: '/directory-empty',
    ),
    // 歌曲详情, one song.
    RhineRoute(
      kind: RhineRouteKind.page,
      name: 'song-detail',
      path: '/song-detail',
    ),
    // 歌单/专辑/歌手详情.
    RhineRoute(
      kind: RhineRouteKind.page,
      name: 'collection-detail',
      path: '/collection-detail',
    ),
    // 3D 查看器, the cover viewer.
    RhineRoute(kind: RhineRouteKind.page, name: 'viewer', path: '/viewer'),
    // 搜索, the full search page.
    RhineRoute(kind: RhineRouteKind.page, name: 'search', path: '/search'),
    // 个人库/收藏.
    RhineRoute(kind: RhineRouteKind.page, name: 'library', path: '/library'),
    // 登录面板.
    RhineRoute(kind: RhineRouteKind.page, name: 'login', path: '/login'),
    // 设置.
    RhineRoute(kind: RhineRouteKind.page, name: 'settings', path: '/settings'),
    // 发现.
    RhineRoute(kind: RhineRouteKind.page, name: 'discover', path: '/discover'),
    // 播放栏, the player bar page.
    RhineRoute(kind: RhineRouteKind.page, name: 'player', path: '/player'),
    // 播放队列.
    RhineRoute(kind: RhineRouteKind.page, name: 'queue', path: '/queue'),
    // 歌词.
    RhineRoute(kind: RhineRouteKind.page, name: 'lyrics', path: '/lyrics'),
    // 更新.
    RhineRoute(kind: RhineRouteKind.page, name: 'update', path: '/update'),
    // 性能面板已停用（不属于产品需求），保留路由位但不注册。
    // Tab Mode.
    RhineRoute(kind: RhineRouteKind.page, name: 'tab-mode', path: '/tab-mode'),
    // 桌面歌词 — 仅桌面，Android 不实施; matrix row only.
    RhineRoute(
      kind: RhineRouteKind.page,
      name: 'desktop-lyrics',
      path: '/desktop-lyrics',
    ),
  ];

  /// The seventeen modal layers of §6.2 (:353), in entry order.
  ///
  /// 'player/queue' is one §6.2 entry and two routes here, because the player
  /// bar and the queue are separate layers in Qt (NativeHudController.cpp:363,
  /// :381).
  static const List<RhineRoute> modals = [
    // §6.2 'search' over the page; Qt modal 'search'
    // (NativeHudController.cpp:626).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'modal-search',
      path: '/modal/modal-search',
    ),
    // §6.2 'saved/个人库' over the page 'library'; Qt modal
    // 'saved' (:106, :684).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'modal-saved',
      path: '/modal/modal-saved',
    ),
    // §6.2 'login' over the page; Qt modal 'login'
    // (NativeHudMusic.cpp:284).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'modal-login',
      path: '/modal/modal-login',
    ),
    // §6.2 'settings' over the page; Qt modal 'settings'
    // (NativeHudController.cpp:408).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'modal-settings',
      path: '/modal/modal-settings',
    ),
    // §6.2 'discover' over the page; Qt modal 'discover' (:678).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'modal-discover',
      path: '/modal/modal-discover',
    ),
    // §6.2 'player/queue', first half; Qt modal 'player' (:363).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'modal-player',
      path: '/modal/modal-player',
    ),
    // §6.2 'player/queue', second half; Qt modal 'queue' (:381).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'modal-queue',
      path: '/modal/modal-queue',
    ),
    // §6.2 'quality'; Qt modal 'quality' (NativeHudController.cpp:708).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'quality',
      path: '/modal/quality',
    ),
    // §6.2 'provider'; Qt modal 'provider' (:509).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'provider',
      path: '/modal/provider',
    ),
    // §6.2 'playlist-form'; Qt modal 'playlist-form'
    // (NativeHudMusic.cpp:317).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'playlist-form',
      path: '/modal/playlist-form',
    ),
    // §6.2 'playlist-picker'; Qt modal 'playlist-picker'
    // (NativeHudMusic.cpp:353).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'playlist-picker',
      path: '/modal/playlist-picker',
    ),
    // §6.2 'confirm'; Qt modal 'confirm' (:561).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'confirm',
      path: '/modal/confirm',
    ),
    // §6.2 'disc-rotation-warning'; Qt modal (:716).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'disc-rotation-warning',
      path: '/modal/disc-rotation-warning',
    ),
    // §6.2 'lyrics-offset'; Qt modal (:328).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'lyrics-offset',
      path: '/modal/lyrics-offset',
    ),
    // §6.2 'lyrics-source'; Qt modal (:340).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'lyrics-source',
      path: '/modal/lyrics-source',
    ),
    // §6.2 'detail-sort'; Qt modal (NativeHudMusic.cpp:42).
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'detail-sort',
      path: '/modal/detail-sort',
    ),
    // §6.2 'desktop-lyrics' over the page; Qt modal
    // 'desktop-lyrics' (NativeHudDesktopLyrics.cpp:130).
    // 仅桌面，Android 不实施.
    RhineRoute(
      kind: RhineRouteKind.modal,
      name: 'modal-desktop-lyrics',
      path: '/modal/modal-desktop-lyrics',
    ),
  ];

  /// Everything, [pages] first and [modals] second.
  ///
  /// A const spread over the two const lists, so this list cannot fall out of
  /// step with them.
  static const List<RhineRoute> all = [...pages, ...modals];

  /// The route called [name], or null when the table has no such name.
  ///
  /// Scans [all] in table order; names are unique, so the order cannot change
  /// the answer. A miss is null rather than a throw so a host can validate a
  /// name that arrives from storage or from a test without catching.
  static RhineRoute? byName(String name) {
    for (final RhineRoute route in all) {
      if (route.name == name) {
        return route;
      }
    }
    return null;
  }

  /// The route at [path], or null when the table has no such path.
  ///
  /// Exact string match, no normalisation: '/search/' and 'search' are misses,
  /// so a typo cannot silently resolve to a neighbouring route.
  static RhineRoute? byPath(String path) {
    for (final RhineRoute route in all) {
      if (route.path == path) {
        return route;
      }
    }
    return null;
  }
}
