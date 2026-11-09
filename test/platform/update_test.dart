// test/platform/update_test.dart
//
// Qt parity sources (line numbers are the grounds for every assertion):
//   Qt/src/AppUpdater.cpp:14        REPOSITORY = "MikeQu223/Rhine-Music-Database"
//   Qt/src/AppUpdater.cpp:15        MAX_PACKAGE_BYTES = 2 GiB
//   Qt/src/AppUpdater.cpp:17-35     parseVersion (whole-string, optional v, 3 segments, <= 65535)
//   Qt/src/AppUpdater.cpp:37-41     officialUrl (https + github.com + no userinfo/port/query/fragment)
//   Qt/src/AppUpdater.cpp:43-49     request(): User-Agent, NoLessSafe redirects, 30 s transfer timeout
//   Qt/src/AppUpdater.cpp:55-61     destructor: disconnect + abort (never rewrites m_status)
//   Qt/src/AppUpdater.cpp:62-71     currentVersion() / commitTitle()
//   Qt/src/AppUpdater.cpp:72-89     platformAsset() (Android -> empty string)
//   Qt/src/AppUpdater.cpp:90-95     isNewer
//   Qt/src/AppUpdater.cpp:101-137   selectRelease (4 failure texts; Android skips the asset match)
//   Qt/src/AppUpdater.cpp:150-153   fail() only rewrites the status text
//   Qt/src/AppUpdater.cpp:155-158   rateLimitStatus() = prefix + local HH:mm:ss + suffix
//   Qt/src/AppUpdater.cpp:161-185   responseError (rate-limit evidence, 60 s default, 86400 clamp)
//   Qt/src/AppUpdater.cpp:188-202   check()
//   Qt/src/AppUpdater.cpp:204-262   fetchRelease (manifest first, REST fallback, 1 MiB abort)
//   Qt/src/AppUpdater.cpp:245       current = RHINE_RELEASE_BUILD ? currentVersion() : ""
//   Qt/src/AppUpdater.cpp:264-274   cancel()
//   Qt/src/AppUpdater.cpp:275-277   openRelease() -> system browser
//   Qt/src/AppUpdater.h:19-24       static API surface
//   Qt/src/AppUpdater.h:26-28       signals changed / updateAvailable
//   worktrees/T06/test/fixtures/settings_sections.json:858-888  frozen update contract
//
// EXECUTION STATUS: NOT EXECUTED. Running flutter test / dart test / dart analyze is
// forbidden in this tree; the file is written and statically reviewed only. Every suite
// below is recorded as RED/GREEN-unexecuted in reports/T27-C18-A2.json.
//
// Every expectation is a literal. No expectation reuses an implementation constant as its
// own expected value, and negative cases are always paired with a positive one.
import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/platform/update_service.dart';

// ---------------------------------------------------------------------------------------
// Literals restated independently of the implementation (never imported constants).
// ---------------------------------------------------------------------------------------
const String kRepoLiteral = 'MikeQu223/Rhine-Music-Database';
const String kManifestLiteral =
    'https://github.com/MikeQu223/Rhine-Music-Database/releases/latest/download/update.json';
const String kApiLiteral =
    'https://api.github.com/repos/MikeQu223/Rhine-Music-Database/releases/latest';
const String kReleasesLiteral =
    'https://github.com/MikeQu223/Rhine-Music-Database/releases';
const String kLinuxAssetLiteral = 'Linux-x86_64.AppImage';

const String kInvalidReleaseText = '发布版本格式无效，或不是正式版本';
const String kInvalidPageText = '发布页面地址无效';
const String kIncompleteAssetText = '发布产物信息不完整，请查看发布页面';
const String kNoPlatformAssetText = '新版本尚无适合当前架构的更新包，请查看发布页面';
const String kRateLimitPatternText =
    '当前网络出口的 GitHub 更新检查额度已用尽，请在 HH:mm:ss 后重试或查看发布页面';

String tagUrlLiteral(String tag) => 'https://github.com/' + kRepoLiteral + '/releases/tag/' + tag;

String downloadUrlLiteral(String tag, String name) =>
    'https://github.com/' + kRepoLiteral + '/releases/download/' + tag + '/' + name;

String assetNameLiteral(String tag, String platform) =>
    'RhineMusicDatabase-' + tag + '-' + platform;

Map<String, Object?> assetJson({
  String tag = '1.2.0',
  required String name,
  String? downloadUrl,
  Object? size = 134217728,
  Object? state = 'uploaded',
}) =>
    <String, Object?>{
      'name': name,
      'browser_download_url': downloadUrl ?? downloadUrlLiteral(tag, name),
      'size': size,
      'state': state,
    };

Map<String, Object?> releaseJson({
  Object? tag = '1.2.0',
  Object? draft = false,
  Object? prerelease = false,
  Object? htmlUrl,
  Object? assets = const <Object?>[],
}) =>
    <String, Object?>{
      'tag_name': tag,
      'draft': draft,
      'prerelease': prerelease,
      'html_url': htmlUrl ?? tagUrlLiteral(tag is String ? tag : ''),
      'assets': assets,
    };

Map<String, Object?> linuxRelease(String tag) => releaseJson(
      tag: tag,
      assets: <Object?>[
        assetJson(tag: tag, name: assetNameLiteral(tag, kLinuxAssetLiteral)),
      ],
    );

UpdateHttpResponse ok(Map<String, Object?> json) =>
    UpdateHttpResponse(statusCode: 200, bodyBytes: 512, json: json);

// ---------------------------------------------------------------------------------------
// Scripted UpdatePorts. It owns the service under test so it can observe busy() and the
// changed() counter at the exact moment a request is issued (Qt :213 get() vs :261 emit).
// ---------------------------------------------------------------------------------------
class FakeUpdatePorts implements UpdatePorts {
  FakeUpdatePorts({
    this.offline = false,
    this.isReleaseBuild = true,
    this.currentVersion = '1.0.0',
    this.platformAsset = '',
    this.commitTitle = 'test build title',
    this.now = 1700000000,
  });

  @override
  bool offline;
  @override
  bool isReleaseBuild;
  @override
  String currentVersion;
  @override
  String platformAsset;
  @override
  String commitTitle;

  int now;
  @override
  int nowSeconds() => now;

  final List<UpdateRequest> requests = <UpdateRequest>[];
  final List<UpdateHttpResponse> scripted = <UpdateHttpResponse>[];
  final List<String> openedUrls = <String>[];
  final List<int> changedEventsAtFetch = <int>[];
  final List<bool> busyAtFetch = <bool>[];
  int abortCalls = 0;
  bool openResult = true;

  /// The service under test, wired back to this port.
  late final UpdateService service = UpdateService(this);

  int _scriptCursor = 0;

  /// Begin a fresh scripted batch. A service reused across several check() calls must not
  /// keep advancing through the previous batch, so the cursor rewinds with the list.
  void resetScript() {
    scripted.clear();
    _scriptCursor = 0;
  }

  @override
  Future<UpdateHttpResponse> fetch(UpdateRequest request) async {
    requests.add(request);
    changedEventsAtFetch.add(service.changedEvents);
    busyAtFetch.add(service.busy);
    if (_scriptCursor < scripted.length) {
      final UpdateHttpResponse response = scripted[_scriptCursor];
      _scriptCursor += 1;
      return response;
    }
    return const UpdateHttpResponse(statusCode: 0, networkFailed: true);
  }

  @override
  Future<bool> openExternalUrl(String url) async {
    openedUrls.add(url);
    return openResult;
  }

  @override
  void abortInFlight() {
    abortCalls += 1;
  }
}

bool isRateLimitText(String value) => RegExp(
      r'^当前网络出口的 GitHub 更新检查额度已用尽，请在 \d{2}:\d{2}:\d{2} 后重试或查看发布页面$',
    ).hasMatch(value);

void main() {
  group('parseVersion (AppUpdater.cpp:17-35)', () {
    test('accepts exactly three numeric segments with an optional leading v', () {
      expect(UpdateService.parseVersion('1.2.3'), const UpdateVersion(1, 2, 3));
      expect(UpdateService.parseVersion('v1.2.3'), const UpdateVersion(1, 2, 3));
      expect(UpdateService.parseVersion('0.0.0'), const UpdateVersion(0, 0, 0));
      expect(UpdateService.parseVersion('v0.0.0'), const UpdateVersion(0, 0, 0));
      expect(UpdateService.parseVersion('10.200.3000'), const UpdateVersion(10, 200, 3000));
      expect(
        UpdateService.parseVersion('65535.65535.65535'),
        const UpdateVersion(65535, 65535, 65535),
      );
      expect(UpdateService.parseVersion('1.2.3')!.toString(), '1.2.3');
      expect(UpdateVersion.segmentCount, 3); // :26-28, exactly three segments
    });

    test('rejects empty, partial, zero-padded, prefixed and trailing-text input', () {
      expect(UpdateService.parseVersion(''), isNull);
      expect(UpdateService.parseVersion('v'), isNull);
      expect(UpdateService.parseVersion('1'), isNull);
      expect(UpdateService.parseVersion('1.2'), isNull);
      expect(UpdateService.parseVersion('1.2.3.4'), isNull);
      expect(UpdateService.parseVersion('01.2.3'), isNull);
      expect(UpdateService.parseVersion('1.02.3'), isNull);
      expect(UpdateService.parseVersion('1.2.03'), isNull);
      expect(UpdateService.parseVersion('1.2.3.0'), isNull);
      expect(UpdateService.parseVersion('vv1.2.3'), isNull);
      expect(UpdateService.parseVersion('V1.2.3'), isNull); // only a lowercase v :18
      expect(UpdateService.parseVersion('1.2.3 '), isNull);
      expect(UpdateService.parseVersion(' 1.2.3'), isNull);
      // :19 capturedLength() != size -> a whole-string match is required.
      expect(UpdateService.parseVersion('1.2.3\n'), isNull);
      expect(UpdateService.parseVersion('1.2.3-beta'), isNull);
      expect(UpdateService.parseVersion('1.2.x'), isNull);
      expect(UpdateService.parseVersion('-1.2.3'), isNull);
      expect(UpdateService.parseVersion('1.2.-3'), isNull);
      expect(UpdateService.parseVersion('1..2'), isNull);
      expect(UpdateService.parseVersion('1.2.3/'), isNull);
    });

    test('rejects any segment above 65535 (:29-33)', () {
      expect(UpdateService.parseVersion('65535.0.0'), isNotNull);
      expect(UpdateService.parseVersion('65536.0.0'), isNull);
      expect(UpdateService.parseVersion('0.65536.0'), isNull);
      expect(UpdateService.parseVersion('0.0.65536'), isNull);
      expect(UpdateService.parseVersion('99999.99999.99999'), isNull);
    });
  });

  group('officialUrl (AppUpdater.cpp:37-41)', () {
    test('accepts the exact https github release paths', () {
      expect(UpdateService.officialUrl(tagUrlLiteral('1.2.0'), '/releases/tag/'), isTrue);
      expect(
        UpdateService.officialUrl(
          downloadUrlLiteral('1.2.0', 'RhineMusicDatabase-1.2.0-Linux-x86_64.AppImage'),
          '/releases/download/',
        ),
        isTrue,
      );
    });

    test('rejects scheme, host, userinfo, port, query, fragment and path drift', () {
      const String tagPrefix = '/releases/tag/';
      expect(
        UpdateService.officialUrl('http://github.com/' + kRepoLiteral + '/releases/tag/1.2.0',
            tagPrefix),
        isFalse,
      );
      expect(
        UpdateService.officialUrl('https://gitlab.com/' + kRepoLiteral + '/releases/tag/1.2.0',
            tagPrefix),
        isFalse,
      );
      expect(
        UpdateService.officialUrl(
            'https://user@github.com/' + kRepoLiteral + '/releases/tag/1.2.0', tagPrefix),
        isFalse,
      );
      expect(
        UpdateService.officialUrl(
            'https://github.com:8443/' + kRepoLiteral + '/releases/tag/1.2.0', tagPrefix),
        isFalse,
      );
      // Dart's Uri parser drops an explicit default port for https, so hasPort alone would
      // accept this URL while Qt's QUrl::port(-1) returns 443 and rejects it (:39).
      expect(
        UpdateService.officialUrl(
            'https://github.com:443/' + kRepoLiteral + '/releases/tag/1.2.0', tagPrefix),
        isFalse,
      );
      expect(
        UpdateService.officialUrl(
            'https://github.com:8443/' + kRepoLiteral + '/releases/download/1.2.0/x.zip',
            '/releases/download/'),
        isFalse,
      );
      expect(
        UpdateService.officialUrl(
            'https://github.com/' + kRepoLiteral + '/releases/tag/1.2.0?x=1', tagPrefix),
        isFalse,
      );
      expect(
        UpdateService.officialUrl(
            'https://github.com/' + kRepoLiteral + '/releases/tag/1.2.0#f', tagPrefix),
        isFalse,
      );
      expect(
        UpdateService.officialUrl('https://github.com/Other/Repo/releases/tag/1.2.0', tagPrefix),
        isFalse,
      );
      // A look-alike repository name must not satisfy the prefix.
      expect(
        UpdateService.officialUrl(
            'https://github.com/MikeQu223/Rhine-Music-Database-evil/releases/tag/1.2.0',
            tagPrefix),
        isFalse,
      );
      expect(
        UpdateService.officialUrl('https://github.com/' + kRepoLiteral + '/releases', tagPrefix),
        isFalse,
      );
      expect(UpdateService.officialUrl('', tagPrefix), isFalse);
      // The download prefix is not the tag prefix.
      expect(UpdateService.officialUrl(downloadUrlLiteral('1.2.0', 'x.zip'), tagPrefix), isFalse);
    });
  });

  group('isNewer (AppUpdater.cpp:90-95)', () {
    test('compares three segments, never strings or dates', () {
      expect(UpdateService.isNewer('1.2.4', '1.2.3'), isTrue);
      expect(UpdateService.isNewer('1.3.0', '1.2.9'), isTrue);
      expect(UpdateService.isNewer('2.0.0', '1.99.99'), isTrue);
      expect(UpdateService.isNewer('1.2.4', 'v1.2.3'), isTrue);
      expect(UpdateService.isNewer('1.10.0', '1.9.0'), isTrue);
      expect(UpdateService.isNewer('1.2.3', '1.2.3'), isFalse);
      expect(UpdateService.isNewer('1.2.2', '1.2.3'), isFalse);
    });

    test('an empty current version accepts any parseable candidate (:93)', () {
      expect(UpdateService.isNewer('1.2.4', ''), isTrue);
      expect(UpdateService.isNewer('0.0.0', ''), isTrue);
      expect(UpdateService.isNewer('garbage', ''), isFalse);
      expect(UpdateService.isNewer('1.2', ''), isFalse);
    });

    test('a candidate or an installed version that does not parse is never newer', () {
      expect(UpdateService.isNewer('garbage', '1.2.3'), isFalse);
      expect(UpdateService.isNewer('1.2.4', 'garbage'), isFalse);
      expect(UpdateService.isNewer('1.2.4', 'v1.2'), isFalse);
    });
  });

  group('selectRelease (AppUpdater.cpp:101-137)', () {
    test('accepts the exact platform asset and returns version/page/asset (:119-132)', () {
      final Map<String, Object?> release = releaseJson(
        tag: '1.2.0',
        assets: <Object?>[
          assetJson(tag: '1.2.0', name: assetNameLiteral('1.2.0', 'Windows-x64-Setup.exe')),
          assetJson(tag: '1.2.0', name: assetNameLiteral('1.2.0', kLinuxAssetLiteral)),
        ],
      );
      final UpdateReleaseSelection selection =
          UpdateService.selectRelease(release, kLinuxAssetLiteral, '1.0.0');
      expect(selection.isFound, isTrue);
      expect(selection.isFailed, isFalse);
      expect(selection.isEmpty, isFalse);
      expect(selection.error, '');
      expect(selection.release!.version, '1.2.0');
      expect(selection.release!.pageUrl, tagUrlLiteral('1.2.0'));
      expect(selection.release!.asset!.name, 'RhineMusicDatabase-1.2.0-Linux-x86_64.AppImage');
      expect(selection.release!.asset!.size, 134217728);
      expect(selection.release!.asset!.state, 'uploaded');
      expect(selection.release!.asset!.json['name'],
          'RhineMusicDatabase-1.2.0-Linux-x86_64.AppImage');
    });

    test('draft, prerelease and an unparseable tag fail with :106', () {
      expect(UpdateService.selectRelease(releaseJson(draft: true), '', '1.0.0').error,
          kInvalidReleaseText);
      expect(UpdateService.selectRelease(releaseJson(prerelease: true), '', '1.0.0').error,
          kInvalidReleaseText);
      expect(UpdateService.selectRelease(releaseJson(tag: 'v1.2'), '', '1.0.0').error,
          kInvalidReleaseText);
      expect(UpdateService.selectRelease(releaseJson(tag: 'nightly'), '', '1.0.0').error,
          kInvalidReleaseText);
      expect(UpdateService.selectRelease(releaseJson(tag: ''), '', '1.0.0').error,
          kInvalidReleaseText);
      expect(UpdateService.selectRelease(releaseJson(tag: 7), '', '1.0.0').error,
          kInvalidReleaseText);
      expect(
          UpdateService.selectRelease(<String, Object?>{}, '', '1.0.0').error, kInvalidReleaseText);
      final UpdateReleaseSelection selection =
          UpdateService.selectRelease(releaseJson(tag: 'nightly'), '', '1.0.0');
      expect(selection.release, isNull);
      expect(selection.isEmpty, isFalse);
    });

    test('a release that is not newer returns an empty result with no error (:108-111)', () {
      final UpdateReleaseSelection selection =
          UpdateService.selectRelease(releaseJson(tag: '1.0.0'), '', '1.0.0');
      expect(selection.isFound, isFalse);
      expect(selection.isEmpty, isTrue);
      expect(selection.isFailed, isFalse);
      expect(selection.error, '');
      expect(selection.release, isNull);
    });

    test('the newer check precedes the page check (:108-116)', () {
      // Not newer AND a bogus page: the empty result wins and the page error is never built.
      final UpdateReleaseSelection selection = UpdateService.selectRelease(
        releaseJson(tag: '1.0.0', htmlUrl: 'https://evil.example/releases/tag/1.0.0'),
        '',
        '1.0.0',
      );
      expect(selection.isEmpty, isTrue);
      expect(selection.error, '');
    });

    test('a bogus page url or a tag mismatch fails with :114 (:112-115)', () {
      expect(
        UpdateService.selectRelease(
                releaseJson(tag: '1.2.0', htmlUrl: 'https://evil.example/releases/tag/1.2.0'),
                '',
                '1.0.0')
            .error,
        kInvalidPageText,
      );
      expect(
        UpdateService.selectRelease(
                releaseJson(
                    tag: '1.2.0',
                    htmlUrl: 'http://github.com/' + kRepoLiteral + '/releases/tag/1.2.0'),
                '',
                '1.0.0')
            .error,
        kInvalidPageText,
      );
      expect(
        UpdateService.selectRelease(
                releaseJson(
                    tag: '1.2.0',
                    htmlUrl: 'https://github.com/' + kRepoLiteral + '/releases/tag/1.2.1'),
                '',
                '1.0.0')
            .error,
        kInvalidPageText,
      );
      expect(
        UpdateService.selectRelease(
                releaseJson(
                    tag: '1.2.0',
                    htmlUrl: 'https://github.com/' + kRepoLiteral + '/releases/tag/1.2.0/extra'),
                '',
                '1.0.0')
            .error,
        kInvalidPageText,
      );
      expect(
        UpdateService.selectRelease(
                releaseJson(
                    tag: '1.2.0',
                    htmlUrl: 'https://github.com/' + kRepoLiteral + '/releases/tag/1.2.0?x=1'),
                '',
                '1.0.0')
            .error,
        kInvalidPageText,
      );
      expect(
        UpdateService.selectRelease(releaseJson(tag: '1.2.0', htmlUrl: ''), '', '1.0.0').error,
        kInvalidPageText,
      );
      expect(
        UpdateService.selectRelease(releaseJson(tag: '1.2.0', htmlUrl: 42), '', '1.0.0').error,
        kInvalidPageText,
      );
    });

    test('a missing asset, an empty asset list or a non-list assets field falls to :135', () {
      expect(
          UpdateService.selectRelease(releaseJson(tag: '1.2.0'), kLinuxAssetLiteral, '1.0.0').error,
          kNoPlatformAssetText);
      expect(
        UpdateService.selectRelease(
                releaseJson(tag: '1.2.0', assets: const <Object?>[]),
                kLinuxAssetLiteral,
                '1.0.0')
            .error,
        kNoPlatformAssetText,
      );
      // QJsonValue::toArray() on a non-array is empty, so the loop never runs.
      expect(
        UpdateService.selectRelease(
                releaseJson(tag: '1.2.0', assets: 'not-a-list'), kLinuxAssetLiteral, '1.0.0')
            .error,
        kNoPlatformAssetText,
      );
      expect(
        UpdateService.selectRelease(
                releaseJson(tag: '1.2.0', assets: <Object?>['nope']),
                kLinuxAssetLiteral,
                '1.0.0')
            .error,
        kNoPlatformAssetText,
      );
      // A well-formed asset for another platform is skipped, not an error by itself.
      expect(
        UpdateService.selectRelease(
                releaseJson(
                  tag: '1.2.0',
                  assets: <Object?>[
                    assetJson(
                        tag: '1.2.0', name: assetNameLiteral('1.2.0', 'Windows-x64-Setup.exe')),
                  ],
                ),
                kLinuxAssetLiteral,
                '1.0.0')
            .error,
        kNoPlatformAssetText,
      );
    });

    test('Android (platform == "") skips the asset match entirely and fails with :135', () {
      // The release carries a perfectly valid asset for this very platform, yet platform ''
      // skips the whole :117-134 block, so a found release is impossible.
      final Map<String, Object?> release = releaseJson(
        tag: '1.2.0',
        assets: <Object?>[
          assetJson(tag: '1.2.0', name: assetNameLiteral('1.2.0', kLinuxAssetLiteral)),
          assetJson(tag: '1.2.0', name: 'RhineMusicDatabase-1.2.0-android.apk'),
        ],
      );
      final UpdateReleaseSelection selection = UpdateService.selectRelease(release, '', '1.0.0');
      expect(selection.isFound, isFalse);
      expect(selection.isEmpty, isFalse);
      expect(selection.release, isNull);
      expect(selection.error, kNoPlatformAssetText);
    });

    test('every asset validation failure reports :129 (:121-131)', () {
      final String name = assetNameLiteral('1.2.0', kLinuxAssetLiteral);
      UpdateReleaseSelection withAsset(Object? entry) => UpdateService.selectRelease(
            releaseJson(tag: '1.2.0', assets: <Object?>[entry]),
            kLinuxAssetLiteral,
            '1.0.0',
          );

      // download url: wrong host, wrong scheme, wrong tag path, not a download path, empty
      expect(
        withAsset(assetJson(
                tag: '1.2.0',
                name: name,
                downloadUrl: 'https://github.com/Other/Repo/releases/download/1.2.0/' + name))
            .error,
        kIncompleteAssetText,
      );
      expect(
        withAsset(assetJson(
                tag: '1.2.0',
                name: name,
                downloadUrl:
                    'http://github.com/' + kRepoLiteral + '/releases/download/1.2.0/' + name))
            .error,
        kIncompleteAssetText,
      );
      expect(
        withAsset(assetJson(
                tag: '1.2.0', name: name, downloadUrl: downloadUrlLiteral('1.2.1', name)))
            .error,
        kIncompleteAssetText,
      );
      expect(
        withAsset(assetJson(
                tag: '1.2.0',
                name: name,
                downloadUrl: 'https://github.com/' + kRepoLiteral + '/releases/tag/1.2.0'))
            .error,
        kIncompleteAssetText,
      );
      expect(withAsset(assetJson(tag: '1.2.0', name: name, downloadUrl: '')).error,
          kIncompleteAssetText);

      // size: non-positive, fractional, non-numeric, missing, above 2 GiB (:15, :128)
      expect(withAsset(assetJson(tag: '1.2.0', name: name, size: 0)).error, kIncompleteAssetText);
      expect(withAsset(assetJson(tag: '1.2.0', name: name, size: -1)).error, kIncompleteAssetText);
      expect(withAsset(assetJson(tag: '1.2.0', name: name, size: 1024.5)).error,
          kIncompleteAssetText);
      expect(withAsset(assetJson(tag: '1.2.0', name: name, size: '1024')).error,
          kIncompleteAssetText);
      expect(withAsset(assetJson(tag: '1.2.0', name: name, size: 2147483649)).error,
          kIncompleteAssetText);
      expect(
        withAsset(<String, Object?>{
          'name': name,
          'browser_download_url': downloadUrlLiteral('1.2.0', name),
          'state': 'uploaded',
        }).error,
        kIncompleteAssetText,
      );
      // boundary: exactly 2 GiB is still accepted (:128 uses a strict >)
      expect(withAsset(assetJson(tag: '1.2.0', name: name, size: 2147483648)).isFound, isTrue);

      // state must be exactly "uploaded"
      expect(withAsset(assetJson(tag: '1.2.0', name: name, state: 'new')).error,
          kIncompleteAssetText);
      expect(withAsset(assetJson(tag: '1.2.0', name: name, state: 'Uploaded')).error,
          kIncompleteAssetText);
      expect(withAsset(assetJson(tag: '1.2.0', name: name, state: '')).error,
          kIncompleteAssetText);
    });
  });

  group('frozen contract values (AppUpdater.cpp:14-15, :43-49, :204-217; T06 fixture :860-887)',
      () {
    test('repository, urls and byte/time thresholds are verbatim', () {
      expect(kUpdateRepository, kRepoLiteral);
      expect(kManifestUrl, kManifestLiteral);
      expect(kApiUrl, kApiLiteral);
      expect(kReleasePageUrl, kReleasesLiteral);
      expect(kMaxPackageBytes, 2147483648);
      expect(kMaxResponseBytes, 1048576);
      expect(kResponseReadBufferBytes, 1048577);
      expect(kTransferTimeoutMs, 30000);
      expect(kDefaultRetrySeconds, 60);
      expect(kMaxRetryAfterSeconds, 86400);
      expect(kUserAgentPrefix, 'RhineMusicDatabase/');
      expect(UpdateRequest.transferTimeoutMs, 30000);
      expect(UpdateRequest.readBufferBytes, 1048577);
      expect(UpdateRequest.redirectPolicy, UpdateRedirectPolicy.noLessSafe);
      expect(kAssetNamePrefix, 'RhineMusicDatabase-');
      expect(kReleaseTagPrefix, '/releases/tag/');
      expect(kReleaseDownloadPrefix, '/releases/download/');
      expect(kApiAcceptHeader, 'Accept');
      expect(kApiAcceptValue, 'application/vnd.github+json');
      expect(kApiVersionHeader, 'X-GitHub-Api-Version');
      expect(kApiVersionValue, '2022-11-28');
      expect(kRetryAfterHeader, 'Retry-After');
      expect(kRateLimitRemainingHeader, 'X-RateLimit-Remaining');
      expect(kRateLimitResetHeader, 'X-RateLimit-Reset');
      expect(UpdateService.expectedAssetName('1.2.0', kLinuxAssetLiteral),
          'RhineMusicDatabase-1.2.0-Linux-x86_64.AppImage');
      expect(UpdateVersion.segmentCount, 3);
    });

    test('every status string is verbatim Qt', () {
      expect(kInitialStatus, '尚未检查更新'); // .h:36
      expect(kOfflineStatus, '离线模式不检查更新'); // :193
      expect(kCheckingStatus, '正在检查更新…'); // :200
      expect(kNoReleaseStatus, '尚无正式发布版本'); // :231
      expect(kInvalidDataStatus, '更新服务返回了无效数据'); // :241
      expect(kUpToDateStatus, '当前已是最新版本'); // :257
      expect(kUpdateAvailablePrefix, '发现新版本 '); // :254
      expect(kCancelledStatus, '已取消，可重新检查'); // :273
      expect(kNetworkErrorStatus, '检查失败，请检查网络后重试'); // :184
      expect(kForbiddenStatus, 'GitHub 拒绝访问更新服务（HTTP 403），请检查代理或查看发布页面'); // :182
      expect(kRateLimitPrefix, '当前网络出口的 GitHub 更新检查额度已用尽，请在 '); // :157
      expect(kRateLimitSuffix, ' 后重试或查看发布页面'); // :157
      expect(kInvalidReleaseStatus, kInvalidReleaseText); // :106
      expect(kInvalidPageStatus, kInvalidPageText); // :114
      expect(kIncompleteAssetStatus, kIncompleteAssetText); // :129
      expect(kNoPlatformAssetStatus, kNoPlatformAssetText); // :135
      // T06 fixture :883 pins the whole rate-limit sentence.
      expect(kRateLimitPrefix + 'HH:mm:ss' + kRateLimitSuffix, kRateLimitPatternText);
    });
  });

  group('check() (AppUpdater.cpp:188-202)', () {
    test('a fresh service exposes the Qt initial state', () {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      expect(ports.service.status, '尚未检查更新'); // .h:36
      expect(ports.service.busy, isFalse);
      expect(ports.service.available, isFalse);
      expect(ports.service.latestVersion, '');
      expect(ports.service.retryAtUnix, 0);
      expect(ports.service.release, isNull);
      expect(ports.service.changedEvents, 0);
    });

    test('offline short-circuits before any request (:192-195)', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts(offline: true);
      await ports.service.check();
      expect(ports.service.status, '离线模式不检查更新');
      expect(ports.requests, isEmpty);
      expect(ports.service.httpRequests, 0);
      expect(ports.service.busy, isFalse);
      expect(ports.service.changedEvents, 1); // fail() emits once
    });

    test('the retry window short-circuits with the rate-limit text (:196-199)', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.scripted.add(const UpdateHttpResponse(
        statusCode: 429,
        headers: <String, String>{'Retry-After': '90'},
      ));
      await ports.service.check();
      expect(ports.service.retryAtUnix, 1700000000 + 90);
      expect(ports.service.httpRequests, 1);

      // Step just inside the backoff window.
      ports.now = ports.service.retryAtUnix - 1;
      ports.resetScript();
      await ports.service.check();
      expect(ports.service.httpRequests, 1); // no new request was issued
      expect(ports.service.status, startsWith('当前网络出口的 GitHub 更新检查额度已用尽，请在 '));
      expect(isRateLimitText(ports.service.status), isTrue);
    });

    test('the first request is the static manifest with no extra headers (:204-208)', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts(currentVersion: '3.4.5');
      ports.scripted.add(ok(releaseJson(tag: '9.9.9')));
      await ports.service.check();
      expect(ports.requests.length, 1);
      final UpdateRequest first = ports.requests.single;
      expect(first.url, kManifestLiteral);
      expect(first.headers, isEmpty);
      expect(first.userAgent, 'RhineMusicDatabase/3.4.5'); // :45
    });

    test('a 404 manifest falls back to the REST API once, with the API headers (:226-229)',
        () async {
      final FakeUpdatePorts ports = FakeUpdatePorts(
        platformAsset: kLinuxAssetLiteral,
        currentVersion: '1.0.0',
      );
      ports.scripted.add(const UpdateHttpResponse(statusCode: 404));
      ports.scripted.add(ok(linuxRelease('1.2.0')));
      await ports.service.check();
      expect(ports.requests.map((UpdateRequest request) => request.url).toList(), <String>[
        kManifestLiteral,
        kApiLiteral,
      ]);
      expect(ports.requests.first.headers, isEmpty);
      expect(ports.requests.last.headers, <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      });
      expect(ports.service.manifestFallbackCount, 1);
      expect(ports.service.status, '发现新版本 1.2.0');
      expect(ports.service.latestVersion, '1.2.0');
      expect(ports.service.available, isTrue);
      expect(ports.service.updateAvailableEvents, 1); // :255
    });

    test('a manifest that exists is never re-fetched through the API (:226)', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts(currentVersion: '1.0.0');
      ports.scripted.add(ok(releaseJson(tag: '1.0.0')));
      await ports.service.check();
      expect(ports.requests.length, 1);
      expect(ports.service.manifestFallbackCount, 0);
      expect(ports.service.status, '当前已是最新版本');
      expect(ports.service.available, isFalse);
      expect(ports.service.updateAvailableEvents, 0);
    });

    test('a 404 from the API itself reports :231', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.scripted.add(const UpdateHttpResponse(statusCode: 404));
      ports.scripted.add(const UpdateHttpResponse(statusCode: 404));
      await ports.service.check();
      expect(ports.requests.length, 2);
      expect(ports.service.status, '尚无正式发布版本');
      expect(ports.service.manifestFallbackCount, 1);
    });

    test('an undecodable body reports :241 and leaves no release', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.scripted.add(const UpdateHttpResponse(statusCode: 200, jsonParseFailed: true));
      await ports.service.check();
      expect(ports.service.status, '更新服务返回了无效数据');
      expect(ports.service.manifestFallbackCount, 0);
      expect(ports.service.available, isFalse);
      expect(ports.service.release, isNull);
    });

    test('a second check() while one is in flight is ignored (:189-191)', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.scripted.add(ok(releaseJson(tag: '1.0.0')));
      final Future<void> first = ports.service.check();
      final Future<void> second = ports.service.check();
      await Future.wait(<Future<void>>[first, second]);
      expect(ports.requests.length, 1);
      expect(ports.service.httpRequests, 1);
      expect(ports.service.busy, isFalse);
    });

    test('a non-release build compares against an empty current version (:245)', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts(
        isReleaseBuild: false,
        currentVersion: '9.9.9',
        platformAsset: kLinuxAssetLiteral,
      );
      ports.scripted.add(ok(linuxRelease('1.2.0')));
      await ports.service.check();
      // current == "" so any parseable tag counts as newer, even an older one.
      expect(ports.service.available, isTrue);
      expect(ports.service.latestVersion, '1.2.0');
      expect(ports.service.status, '发现新版本 1.2.0');
    });

    test('a release build only reports a strictly newer tag (:245-246)', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts(
        isReleaseBuild: true,
        currentVersion: '2.0.0',
        platformAsset: kLinuxAssetLiteral,
      );
      ports.scripted.add(ok(linuxRelease('1.2.0')));
      await ports.service.check();
      expect(ports.service.status, '当前已是最新版本');
      expect(ports.service.available, isFalse);
      expect(ports.service.updateAvailableEvents, 0);
    });
  });

  group('request/notify ordering and the 1 MiB abort (AppUpdater.cpp:213-220, :261)', () {
    test('changed() is emitted after the request starts, with busy() already true', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.scripted.add(ok(releaseJson(tag: '1.0.0')));
      await ports.service.check();
      // :213 m_network->get() runs first; the :261 emit happens after it.
      expect(ports.changedEventsAtFetch, <int>[0]);
      expect(ports.busyAtFetch, <bool>[true]);
      expect(ports.service.changedEvents, 2); // :261 plus :259
    });

    test('exactly 1 MiB is accepted, one byte more is aborted (:215-217)', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.scripted.add(const UpdateHttpResponse(
        statusCode: 200,
        bodyBytes: 1048576,
        json: <String, Object?>{'tag_name': '1.0.0'},
      ));
      await ports.service.check();
      expect(ports.service.abortCount, 0);
      expect(ports.service.status, '当前已是最新版本');

      ports.resetScript();
      ports.scripted.add(const UpdateHttpResponse(
        statusCode: 200,
        bodyBytes: 1048577,
        json: <String, Object?>{'tag_name': '9.9.9'},
      ));
      await ports.service.check();
      expect(ports.service.abortCount, 1);
      expect(ports.service.status, '检查失败，请检查网络后重试'); // :234, reply error != NoError
      expect(ports.service.available, isFalse);
    });

    test('an oversized 404 manifest still takes the REST fallback first (:226-229 before :234)',
        () async {
      final FakeUpdatePorts ports = FakeUpdatePorts(
        platformAsset: kLinuxAssetLiteral,
        currentVersion: '1.0.0',
      );
      ports.scripted.add(const UpdateHttpResponse(statusCode: 404, bodyBytes: 1048577));
      ports.scripted.add(ok(linuxRelease('1.2.0')));
      await ports.service.check();
      expect(ports.service.abortCount, 1);
      expect(ports.service.manifestFallbackCount, 1);
      expect(ports.requests.length, 2);
      expect(ports.requests.last.url, kApiLiteral);
      expect(ports.service.status, '发现新版本 1.2.0');
    });

    test('an oversized response is never parsed and never falls back', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts(platformAsset: kLinuxAssetLiteral);
      ports.scripted.add(const UpdateHttpResponse(
        statusCode: 200,
        bodyBytes: 1048577,
        jsonParseFailed: true,
      ));
      await ports.service.check();
      expect(ports.requests.length, 1);
      expect(ports.service.abortCount, 1);
      expect(ports.service.status, '检查失败，请检查网络后重试'); // :184, never :241
    });
  });

  group('responseError and rate limiting (AppUpdater.cpp:155-185)', () {
    test('429 arms the 60 s default backoff and reports the local clock (:169-171)', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.scripted.add(const UpdateHttpResponse(statusCode: 429));
      await ports.service.check();
      expect(ports.service.retryAtUnix, 1700000000 + 60);
      expect(ports.service.status, startsWith('当前网络出口的 GitHub 更新检查额度已用尽，请在 '));
      expect(isRateLimitText(ports.service.status), isTrue);
      expect(ports.service.available, isFalse);
    });

    test('Retry-After replaces the default and is clamped to 86400 (:172-175)', () async {
      final FakeUpdatePorts short = FakeUpdatePorts();
      short.scripted.add(const UpdateHttpResponse(
        statusCode: 429,
        headers: <String, String>{'Retry-After': '30'},
      ));
      await short.service.check();
      expect(short.service.retryAtUnix, 1700000000 + 30);

      final FakeUpdatePorts exact = FakeUpdatePorts();
      exact.scripted.add(const UpdateHttpResponse(
        statusCode: 429,
        headers: <String, String>{'Retry-After': '86400'},
      ));
      await exact.service.check();
      expect(exact.service.retryAtUnix, 1700000000 + 86400);

      final FakeUpdatePorts huge = FakeUpdatePorts();
      huge.scripted.add(const UpdateHttpResponse(
        statusCode: 429,
        headers: <String, String>{'Retry-After': '86401'},
      ));
      await huge.service.check();
      expect(huge.service.retryAtUnix, 1700000000 + 86400);
    });

    test('an unparseable, negative or zero Retry-After keeps the default (:172-178)', () async {
      final FakeUpdatePorts junk = FakeUpdatePorts();
      junk.scripted.add(const UpdateHttpResponse(
        statusCode: 429,
        headers: <String, String>{'Retry-After': 'soon'},
      ));
      await junk.service.check();
      expect(junk.service.retryAtUnix, 1700000000 + 60);

      final FakeUpdatePorts negative = FakeUpdatePorts();
      negative.scripted.add(const UpdateHttpResponse(
        statusCode: 429,
        headers: <String, String>{'Retry-After': '-5'},
      ));
      await negative.service.check();
      expect(negative.service.retryAtUnix, 1700000000 + 60);

      final FakeUpdatePorts zero = FakeUpdatePorts();
      zero.scripted.add(const UpdateHttpResponse(
        statusCode: 429,
        headers: <String, String>{'Retry-After': '0'},
      ));
      await zero.service.check();
      expect(zero.service.retryAtUnix, 1700000000 + 60);
    });

    test('403 is a rate limit only with server-side evidence (:165-167)', () async {
      final FakeUpdatePorts exhausted = FakeUpdatePorts();
      exhausted.scripted.add(const UpdateHttpResponse(
        statusCode: 403,
        headers: <String, String>{'X-RateLimit-Remaining': '0'},
      ));
      await exhausted.service.check();
      expect(isRateLimitText(exhausted.service.status), isTrue);

      final FakeUpdatePorts retryAfter = FakeUpdatePorts();
      retryAfter.scripted.add(const UpdateHttpResponse(
        statusCode: 403,
        headers: <String, String>{'Retry-After': '12'},
      ));
      await retryAfter.service.check();
      expect(isRateLimitText(retryAfter.service.status), isTrue);
      expect(retryAfter.service.retryAtUnix, 1700000000 + 12);

      final FakeUpdatePorts message = FakeUpdatePorts();
      message.scripted.add(UpdateHttpResponse(
        statusCode: 403,
        json: <String, Object?>{'message': 'API RATE LIMIT exceeded'},
      ));
      await message.service.check();
      expect(isRateLimitText(message.service.status), isTrue); // case-insensitive :167

      final FakeUpdatePorts plain = FakeUpdatePorts();
      plain.scripted.add(UpdateHttpResponse(
        statusCode: 403,
        json: <String, Object?>{'message': 'Forbidden'},
      ));
      await plain.service.check();
      expect(plain.service.status, 'GitHub 拒绝访问更新服务（HTTP 403），请检查代理或查看发布页面');
      expect(plain.service.retryAtUnix, 0); // no backoff was armed
    });

    test('X-RateLimit-Reset applies only when exhausted and still in the future (:176-178)',
        () async {
      final FakeUpdatePorts future = FakeUpdatePorts();
      final int reset = future.now + 500;
      future.scripted.add(UpdateHttpResponse(
        statusCode: 403,
        headers: <String, String>{
          'X-RateLimit-Remaining': '0',
          'X-RateLimit-Reset': reset.toString(),
        },
      ));
      await future.service.check();
      expect(future.service.retryAtUnix, reset);

      final FakeUpdatePorts past = FakeUpdatePorts();
      past.scripted.add(UpdateHttpResponse(
        statusCode: 403,
        headers: <String, String>{
          'X-RateLimit-Remaining': '0',
          'X-RateLimit-Reset': (past.now - 500).toString(),
        },
      ));
      await past.service.check();
      expect(past.service.retryAtUnix, 1700000000 + 60);

      final FakeUpdatePorts notExhausted = FakeUpdatePorts();
      notExhausted.scripted.add(UpdateHttpResponse(
        statusCode: 429,
        headers: <String, String>{'X-RateLimit-Reset': (notExhausted.now + 500).toString()},
      ));
      await notExhausted.service.check();
      expect(notExhausted.service.retryAtUnix, 1700000000 + 60);

      final FakeUpdatePorts remainingOne = FakeUpdatePorts();
      remainingOne.scripted.add(UpdateHttpResponse(
        statusCode: 429,
        headers: <String, String>{
          'X-RateLimit-Remaining': '1',
          'X-RateLimit-Reset': (remainingOne.now + 500).toString(),
        },
      ));
      await remainingOne.service.check();
      expect(remainingOne.service.retryAtUnix, 1700000000 + 60);
    });

    test('a 5xx and a status-less transport error are plain network failures (:184)', () async {
      final FakeUpdatePorts fiveHundred = FakeUpdatePorts();
      fiveHundred.scripted.add(const UpdateHttpResponse(statusCode: 500));
      await fiveHundred.service.check();
      expect(fiveHundred.service.status, '检查失败，请检查网络后重试');
      expect(fiveHundred.service.retryAtUnix, 0);

      final FakeUpdatePorts transport = FakeUpdatePorts();
      transport.scripted.add(const UpdateHttpResponse(statusCode: 0, networkFailed: true));
      await transport.service.check();
      expect(transport.service.status, '检查失败，请检查网络后重试');
      expect(transport.service.retryAtUnix, 0);
    });

    test('the armed window expires and a later check runs again (:196-199)', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.scripted.add(const UpdateHttpResponse(statusCode: 429));
      await ports.service.check();
      expect(ports.service.retryAtUnix, 1700000000 + 60);

      ports.now = ports.service.retryAtUnix; // the window has expired
      ports.resetScript();
      ports.scripted.add(const UpdateHttpResponse(statusCode: 200, jsonParseFailed: true));
      await ports.service.check();
      expect(ports.service.status, '更新服务返回了无效数据');
      expect(ports.service.httpRequests, 2);
    });
  });

  group('release retention (AppUpdater.cpp:150-153, :226-252)', () {
    test('a confirmed release survives transport failures but not a validation failure',
        () async {
      final FakeUpdatePorts ports = FakeUpdatePorts(
        platformAsset: kLinuxAssetLiteral,
        currentVersion: '1.0.0',
      );
      final UpdateService service = ports.service;

      ports.scripted.add(ok(linuxRelease('1.2.0')));
      await service.check();
      expect(service.available, isTrue);
      expect(service.latestVersion, '1.2.0');
      expect(service.status, '发现新版本 1.2.0');
      expect(service.updateAvailableEvents, 1);

      // A transport failure returns early, so m_release is untouched.
      ports.resetScript();
      ports.scripted.add(const UpdateHttpResponse(statusCode: 0, networkFailed: true));
      await service.check();
      expect(service.status, '检查失败，请检查网络后重试'); // fail() only rewrites the text
      expect(service.available, isTrue);
      expect(service.latestVersion, '1.2.0');
      expect(service.updateAvailableEvents, 1);

      // An HTTP error also returns early and keeps the previous release.
      ports.resetScript();
      ports.scripted.add(const UpdateHttpResponse(statusCode: 500));
      await service.check();
      expect(service.status, '检查失败，请检查网络后重试');
      expect(service.available, isTrue);

      // A selectRelease validation failure DOES clear it: the :248 assignment precedes
      // the :249-252 error check.
      ports.resetScript();
      ports.scripted.add(ok(releaseJson(
        tag: '1.3.0',
        htmlUrl: 'https://evil.example/releases/tag/1.3.0',
      )));
      await service.check();
      expect(service.status, '发布页面地址无效');
      expect(service.available, isFalse);
      expect(service.latestVersion, '');
      expect(service.release, isNull);
      expect(service.updateAvailableEvents, 1);
    });

    test('an invalid-body response also keeps the previous release (:238-243 early return)',
        () async {
      final FakeUpdatePorts ports = FakeUpdatePorts(
        platformAsset: kLinuxAssetLiteral,
        currentVersion: '1.0.0',
      );
      final UpdateService service = ports.service;
      ports.scripted.add(ok(linuxRelease('1.2.0')));
      await service.check();
      expect(service.available, isTrue);

      ports.resetScript();
      ports.scripted.add(const UpdateHttpResponse(statusCode: 200, jsonParseFailed: true));
      await service.check();
      expect(service.status, '更新服务返回了无效数据');
      expect(service.available, isTrue); // :240-243 returns before :248
      expect(service.latestVersion, '1.2.0');
    });

    test('an up-to-date result clears a previously found release (:247-248)', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts(
        platformAsset: kLinuxAssetLiteral,
        currentVersion: '1.0.0',
      );
      final UpdateService service = ports.service;
      ports.scripted.add(ok(linuxRelease('1.2.0')));
      await service.check();
      expect(service.available, isTrue);

      ports.currentVersion = '2.0.0';
      ports.resetScript();
      ports.scripted.add(ok(linuxRelease('1.2.0')));
      await service.check();
      expect(service.status, '当前已是最新版本');
      expect(service.available, isFalse);
      expect(service.release, isNull);
    });
  });

  group('cancel() (AppUpdater.cpp:264-274)', () {
    test('cancelling an in-flight check aborts and reports :273', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.scripted.add(ok(linuxRelease('1.2.0')));
      final Future<void> pending = ports.service.check();
      expect(ports.service.busy, isTrue);

      ports.service.cancel();
      expect(ports.service.busy, isFalse);
      expect(ports.abortCalls, 1);
      expect(ports.service.status, '已取消，可重新检查');

      await pending;
      // The late response must not touch any state (:270 disconnect).
      expect(ports.service.status, '已取消，可重新检查');
      expect(ports.service.available, isFalse);
      expect(ports.service.latestVersion, '');
      expect(ports.service.httpRequests, 1);
    });

    test('cancel() with nothing in flight is a no-op (:265-267)', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.service.cancel();
      expect(ports.abortCalls, 0);
      expect(ports.service.status, '尚未检查更新');

      ports.scripted.add(ok(releaseJson(tag: '1.0.0')));
      await ports.service.check();
      expect(ports.service.status, '当前已是最新版本'); // the service is still usable
    });

    test('a cancelled manifest response never reaches the REST fallback (:270)', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.scripted.add(const UpdateHttpResponse(statusCode: 404));
      ports.scripted.add(ok(linuxRelease('1.2.0')));
      final Future<void> pending = ports.service.check();
      ports.service.cancel();
      await pending;
      expect(ports.requests.length, 1);
      expect(ports.service.manifestFallbackCount, 0);
      expect(ports.service.status, '已取消，可重新检查');
    });

    test('a fresh check() after a cancel works again (:265-267)', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.scripted.add(ok(releaseJson(tag: '1.0.0')));
      final Future<void> pending = ports.service.check();
      ports.service.cancel();
      await pending;

      ports.resetScript();
      ports.scripted.add(ok(releaseJson(tag: '1.0.0')));
      await ports.service.check();
      expect(ports.service.status, '当前已是最新版本');
      expect(ports.service.httpRequests, 2);
    });
  });

  group('dispose() == the Qt destructor (AppUpdater.cpp:55-61)', () {
    test('dispose() aborts an in-flight request without rewriting the status', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.scripted.add(ok(linuxRelease('1.2.0')));
      final Future<void> pending = ports.service.check();
      expect(ports.service.busy, isTrue);

      ports.service.dispose();
      expect(ports.abortCalls, 1);
      expect(ports.service.busy, isFalse);
      expect(ports.service.status, '正在检查更新…'); // the destructor never calls fail()

      await pending;
      expect(ports.service.status, '正在检查更新…');
      expect(ports.service.available, isFalse);
    });

    test('dispose() with nothing in flight is a no-op', () {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.service.dispose();
      expect(ports.abortCalls, 0);
      expect(ports.service.status, '尚未检查更新');
      expect(ports.service.busy, isFalse);
    });
  });

  group('openRelease() / install intent (AppUpdater.cpp:275-277; T06 fixture :887)', () {
    test('openReleasePage() hands exactly the releases page to the system browser', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      expect(await ports.service.openReleasePage(), isTrue);
      expect(ports.openedUrls, <String>[kReleasesLiteral]);
      expect(ports.openedUrls.single, 'https://github.com/MikeQu223/Rhine-Music-Database/releases');
    });

    test('installIntent() is the same browser call and returns the port answer', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts()..openResult = false;
      expect(await ports.service.installIntent(), isFalse);
      expect(ports.openedUrls,
          <String>['https://github.com/MikeQu223/Rhine-Music-Database/releases']);
      expect(ports.openedUrls.single, kReleasesLiteral);
    });

    test('checking never opens a browser and never produces an installer url', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts(
        platformAsset: kLinuxAssetLiteral,
        currentVersion: '1.0.0',
      );
      ports.scripted.add(ok(linuxRelease('1.2.0')));
      await ports.service.check();
      expect(ports.openedUrls, isEmpty);
      expect(ports.service.release!.pageUrl, tagUrlLiteral('1.2.0'));
      // The asset url is inert data for display; inAppDownloadOrInstall is false.
      expect(
        ports.service.release!.asset!.downloadUrl,
        'https://github.com/MikeQu223/Rhine-Music-Database/releases/download/1.2.0/'
        'RhineMusicDatabase-1.2.0-Linux-x86_64.AppImage',
      );
    });

    test('the build identity the settings surface shows is exposed', () {
      final FakeUpdatePorts ports = FakeUpdatePorts(commitTitle: 'feat: test build');
      expect(ports.service.commitTitle, 'feat: test build');
      expect(ports.service.rateLimitStatus, isNotEmpty);
    });
  });

  group('Android capability (AppUpdater.cpp:72-76, :117, :135-136, :188-202)', () {
    test('platformAsset == "" still issues the request and the REST fallback', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts(platformAsset: '', currentVersion: '1.0.0');
      ports.scripted.add(const UpdateHttpResponse(statusCode: 404));
      ports.scripted.add(ok(releaseJson(
        tag: '1.2.0',
        assets: <Object?>[
          assetJson(tag: '1.2.0', name: assetNameLiteral('1.2.0', kLinuxAssetLiteral)),
        ],
      )));
      await ports.service.check();
      expect(ports.requests.length, 2); // no Android branch in check()/fetchRelease
      expect(ports.requests.first.url, kManifestLiteral);
      expect(ports.requests.last.url, kApiLiteral);
      expect(ports.service.manifestFallbackCount, 1);
      expect(ports.service.status, '新版本尚无适合当前架构的更新包，请查看发布页面'); // :135
      expect(ports.service.available, isFalse);
      expect(ports.service.updateAvailableEvents, 0);
    });

    test('platform "" never matches an asset, not even an Android-named one', () {
      final UpdateReleaseSelection selection = UpdateService.selectRelease(
        releaseJson(
          tag: '1.2.0',
          assets: <Object?>[
            assetJson(tag: '1.2.0', name: 'RhineMusicDatabase-1.2.0-android.apk'),
          ],
        ),
        '',
        '1.0.0',
      );
      expect(selection.isFailed, isTrue);
      expect(selection.error, '新版本尚无适合当前架构的更新包，请查看发布页面');
    });

    test('the update capability itself is never removed or hidden by the service', () {
      // The platform matrix hides entries; it must not delete the update capability.
      final FakeUpdatePorts android = FakeUpdatePorts(platformAsset: '');
      expect(android.platformAsset, '');
      expect(kReleasePageUrl, isNotEmpty);
      expect(kUpdateRepository, isNotEmpty);
      expect(UpdateService.parseVersion('1.2.0'), isNotNull);
      expect(android.service.status, '尚未检查更新');
    });
  });

  group('local clock rendering (AppUpdater.cpp:155-158)', () {
    test('a rate-limit status always carries a zero-padded HH:mm:ss clock', () async {
      final FakeUpdatePorts ports = FakeUpdatePorts();
      ports.scripted.add(const UpdateHttpResponse(
        statusCode: 429,
        headers: <String, String>{'Retry-After': '5'},
      ));
      await ports.service.check();
      final RegExp clock = RegExp(r'请在 (\d{2}:\d{2}:\d{2}) 后重试或查看发布页面$');
      final RegExpMatch? match = clock.firstMatch(ports.service.status);
      expect(match, isNotNull);
      expect(match!.group(1)!.length, 8);
      expect(match.group(1)!.substring(2, 3), ':');
      expect(match.group(1)!.substring(5, 6), ':');
      expect(ports.service.status, isNot(contains('HH:mm:ss'))); // the literal is substituted
    });
  });
}
