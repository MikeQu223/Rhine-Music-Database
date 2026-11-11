/// Named route table for the Qt to Flutter port: the pages of plan §6.1 and the
/// modal layers of plan §6.2, as plain strings.
///
/// This file imports nothing. A route is a kind, a name and a path, so the same
/// table can drive a Flutter Navigator, an offline test, or a host that is not
/// Flutter at all. No Flutter type appears on purpose: the file owns names, not
/// widgets, and says nothing about how a page renders.
///
/// Sources, both in
/// docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:
///
/// * Pages — the nineteen rows of §6.1, kept in row order (:331-349). A page's
///   path is '/' plus its name.
/// * Modals — the sixteen entries of §6.2 (:351-353), where "player/queue" is
///   one entry but two modals here. A modal's path is '/modal/' plus its name;
///   for the eight prefixed names that is literally '/modal/modal-...', and the
///   doubling is the rule, not a typo.
///
/// Eight of the seventeen modals carry a `modal-` prefix: a §6.2 name that
/// would also be a page name (`search`, `login`, `settings`, `discover`,
/// `player`, `queue`, `desktop-lyrics`) or that names the same surface under
/// another word (`saved` is the page `library`; §6.2 itself writes "saved/
/// 个人库") has to be told apart from the page it opens above. The prefix
/// belongs to this table alone. The engine's `modal` value and every protocol
/// string keep the bare §6.2 literal, because Qt copies the `kind` argument
/// straight into `modal` (Qt/src/NativeHudController.cpp:64-88) and compares
/// it with 'search' (:626), 'saved' (:106, :684), 'player' (:363), 'queue'
/// (:381), 'settings' (:408, :721), 'discover' (:678), 'login'
/// (Qt/src/NativeHudMusic.cpp:284) and 'desktop-lyrics'
/// (Qt/src/NativeHudDesktopLyrics.cpp:130). Nothing may send a `modal-` name
/// across the bridge.
///
/// T16 is undecided. docs/flutter-migration/02-adjudication.md records
/// 未裁决 (PENDING_DEVICE_EVIDENCE) with every metric UNMEASURED; plan:167
/// forbids filling metrics for a candidate that never ran, plan:168 forbids
/// naming a winner in advance, and plan:170 with :510 stops P2 page work if all
/// five candidates fail. A route table is not evidence for any candidate, so
/// this one selects none: in particular it does not choose candidate A (Flutter
/// host carrying the Qt view through a PlatformView, plan:135) and introduces
/// no host class, QtPlatformView or lib/platform/qt_platform_view.dart
/// included (plan:463), because naming one would decide T16 from a file that
/// only records names.
///
/// Two invariants are carried here:
///
/// * Back is adjudicated outside Flutter routing. Qt derives the return key
///   from its own state, and T20 keeps that decision (plan:518); these routes
///   are names, not a pop stack.
/// * A name is rotation-stable identity, not layout. Rotation keeps the modal
///   name and the close progress unchanged (plan:376,
///   docs/flutter-migration/contracts/layout.md:365), so these strings are
///   fixed identifiers and are never renamed per orientation.
library;

/// Which namespace a [RhineRoute] belongs to.
enum RhineRouteKind {
  /// A page: one row of plan §6.1, path '/name'.
  page,

  /// A modal layer above the current page: one entry of plan §6.2, path
  /// '/modal/name'. The page beneath keeps rendering; the modal is a layer,
  /// not a replacement (plan:180).
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
/// can be read against the plan without a sorting step. [all] is [pages] then
/// [modals], and every name and every path in it is unique. The two path
/// prefixes ('/' and '/modal/') keep the namespaces disjoint before the
/// `modal-` rename even applies, so [byPath] never has to prefer a kind.
///
/// A namespace only: every member is static and nothing here is instantiated,
/// hence `abstract final`.
abstract final class RhineRoutes {
  /// The nineteen pages of plan §6.1 (:331-349), in row order.
  static const List<RhineRoute> pages = [
    // Consent 隐私门槛 (plan:331).
    RhineRoute(kind: RhineRouteKind.page, name: 'consent', path: '/consent'),
    // Boot (plan:332).
    RhineRoute(kind: RhineRouteKind.page, name: 'boot', path: '/boot'),
    // Archive/首页, five lanes and the directory stack (plan:333).
    RhineRoute(kind: RhineRouteKind.page, name: 'archive', path: '/archive'),
    // 目录空态, the empty directory state (plan:334).
    RhineRoute(
      kind: RhineRouteKind.page,
      name: 'directory-empty',
      path: '/directory-empty',
    ),
    // 歌曲详情, one song (plan:335).
    RhineRoute(
      kind: RhineRouteKind.page,
      name: 'song-detail',
      path: '/song-detail',
    ),
    // 歌单/专辑/歌手详情 (plan:336).
    RhineRoute(
      kind: RhineRouteKind.page,
      name: 'collection-detail',
      path: '/collection-detail',
    ),
    // 3D 查看器, the cover viewer (plan:337).
    RhineRoute(kind: RhineRouteKind.page, name: 'viewer', path: '/viewer'),
    // 搜索, the full search page (plan:338).
    RhineRoute(kind: RhineRouteKind.page, name: 'search', path: '/search'),
    // 个人库/收藏 (plan:339).
    RhineRoute(kind: RhineRouteKind.page, name: 'library', path: '/library'),
    // 登录面板 (plan:340).
    RhineRoute(kind: RhineRouteKind.page, name: 'login', path: '/login'),
    // 设置 (plan:341).
    RhineRoute(kind: RhineRouteKind.page, name: 'settings', path: '/settings'),
    // 发现 (plan:342).
    RhineRoute(kind: RhineRouteKind.page, name: 'discover', path: '/discover'),
    // 播放栏, the player bar page (plan:343).
    RhineRoute(kind: RhineRouteKind.page, name: 'player', path: '/player'),
    // 播放队列 (plan:344).
    RhineRoute(kind: RhineRouteKind.page, name: 'queue', path: '/queue'),
    // 歌词 (plan:345).
    RhineRoute(kind: RhineRouteKind.page, name: 'lyrics', path: '/lyrics'),
    // 更新 (plan:346).
    RhineRoute(kind: RhineRouteKind.page, name: 'update', path: '/update'),
    // 诊断/性能面板 (plan:347).
    RhineRoute(
      kind: RhineRouteKind.page,
      name: 'diagnostics',
      path: '/diagnostics',
    ),
    // Tab Mode (plan:348).
    RhineRoute(kind: RhineRouteKind.page, name: 'tab-mode', path: '/tab-mode'),
    // 桌面歌词 — 仅桌面，Android 不实施; matrix row only (plan:349).
    RhineRoute(
      kind: RhineRouteKind.page,
      name: 'desktop-lyrics',
      path: '/desktop-lyrics',
    ),
  ];

  /// The seventeen modal layers of plan §6.2 (:353), in entry order.
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
    // 仅桌面，Android 不实施 (plan:349).
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
