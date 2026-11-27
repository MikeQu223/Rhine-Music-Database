/// BASIC-89 lane A · 塞壬唱片仓库与数据契约测试。
///
/// 本文件**只编写、不执行**：RED/GREEN 均未运行（禁令：禁 dart test / flutter test / analyze）。
///
/// 真值来源（只读）：
/// - MusicBridge/client/siren.mjs：request :89-111（HTTP/code 文案）、load :114-187（目录归组）、
///   songItem :189-216、albumItem :218-255、songDetail :282-296、albumDetail :298-307、
///   detail :414-439、lyrics :497-513。
/// - 协调者 control seq5 wire 纠正（逐字）：官网 wire = { code: 0, data: ... }；
///   错误信息在 code/msg；目录 data 可能为数组或 { list: [...] }。
///   {code:200,value} 只是本地 Qt HostReply 桥接归一形态，仅作次选容忍分支。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/siren_repository.dart';

/// 记录请求 URI 的注入传输层；测试永不触网。
class _Transport {
  _Transport(this.handler);

  final Future<SirenHttpResult> Function(Uri uri) handler;
  final List<Uri> calls = <Uri>[];

  Future<SirenHttpResult> get(Uri uri) {
    calls.add(uri);
    return handler(uri);
  }

  List<String> get paths => <String>[for (final Uri uri in calls) uri.path];
}

SirenHttpResult _json(Object? body) {
  return SirenHttpResult(statusCode: 200, bytes: utf8.encode(jsonEncode(body)));
}

SirenHttpResult _text(String body) {
  return SirenHttpResult(statusCode: 200, bytes: utf8.encode(body));
}

SirenRepository _repository(
  _Transport transport, {
  Uri? baseUri,
  Duration timeout = const Duration(seconds: 20),
}) {
  return SirenRepository(
    baseUri: baseUri ?? Uri.parse('https://example.test'),
    get: transport.get,
    timeout: timeout,
  );
}

/// 一次正常曲库：s1/s2 属于 a1，s3 属于 a2，s4 无专辑；s2 无艺人、s3 专辑名为空。
Object _catalogPayload() {
  return <String, Object?>{
    'code': 0,
    'data': <Object?>[
      <String, Object?>{'cid': 's1', 'name': 'Song One', 'albumCid': 'a1', 'artists': <Object?>['A', 'B']},
      <String, Object?>{'cid': 's2', 'name': '', 'albumCid': 'a1', 'artists': <Object?>[]},
      <String, Object?>{'cid': 's3', 'name': ' S3 ', 'albumCid': 'a2', 'artists': <Object?>['C']},
      <String, Object?>{'cid': '', 'name': 'drop me', 'albumCid': 'a1', 'artists': <Object?>['A']},
      <String, Object?>{'cid': 's4', 'name': 'no album', 'albumCid': '', 'artists': <Object?>[]},
    ],
  };
}

Object _albumsPayload() {
  return <String, Object?>{
    'code': 0,
    'data': <Object?>[
      <String, Object?>{
        'cid': 'a1',
        'name': 'Album One',
        'artistes': <Object?>['A'],
        'coverUrl': 'https://cover.test/a1.jpg',
        'intro': 'intro a1',
      },
      <String, Object?>{'cid': 'a2', 'name': '', 'artistes': <Object?>[], 'coverUrl': ''},
      <String, Object?>{'cid': '', 'name': 'drop album'},
    ],
  };
}

Future<SirenHttpResult> _catalogHandler(Uri uri) async {
  if (uri.path == '/api/songs') {
    return _json(_catalogPayload());
  }
  if (uri.path == '/api/albums') {
    return _json(_albumsPayload());
  }
  throw StateError('unexpected path: ${uri.path}');
}

void main() {
  group('SirenRepository.loadCatalog（siren.mjs:114-187 / :310-316）', () {
    test('code==0 → data 数组：专辑名/封面回填、空 cid 丢弃、占位标题与艺人回退', () async {
      final _Transport transport = _Transport(_catalogHandler);
      final SirenRepository repository = _repository(transport);

      final SirenCatalog catalog = await repository.loadCatalog();

      expect(transport.paths, <String>['/api/songs', '/api/albums']);
      expect(transport.calls.first.host, 'example.test');
      expect(catalog.songs.length, 4, reason: 'cid 为空的歌曲被丢弃');
      expect(catalog.albums.length, 2, reason: 'cid 为空的专辑被丢弃');

      final SirenSong s1 = catalog.songs.firstWhere((SirenSong song) => song.id == 's1');
      expect(s1.title, 'Song One');
      expect(s1.artist, 'A / B');
      expect(s1.album, 'Album One', reason: '专辑名从 /api/albums 回填');
      expect(s1.albumId, 'a1');
      expect(s1.cover, 'https://cover.test/a1.jpg');
      expect(s1.sourceUrl, '', reason: '曲库阶段没有直链');
      expect(s1.lyricUrl, '');
      expect(s1.durationMs, 0);

      final SirenSong s2 = catalog.songs.firstWhere((SirenSong song) => song.id == 's2');
      expect(s2.title, sirenUnknownTitle, reason: 'siren.mjs:203 的占位标题');
      expect(s2.artist, 'A', reason: '歌曲无 artists 时回退专辑 artistes');

      final SirenSong s3 = catalog.songs.firstWhere((SirenSong song) => song.id == 's3');
      expect(s3.title, 'S3', reason: '字段 trim');
      expect(s3.album, '', reason: '专辑名为空则空串，不编造');
      expect(s3.artist, 'C');

      final SirenSong s4 = catalog.songs.firstWhere((SirenSong song) => song.id == 's4');
      expect(s4.artist, sirenDefaultArtist, reason: '无专辑、无艺人 → 默认艺人');
      expect(s4.album, '');
      expect(s4.albumId, '');

      final SirenAlbum a1 = catalog.albums.firstWhere((SirenAlbum album) => album.id == 'a1');
      expect(a1.name, 'Album One');
      expect(a1.artist, 'A');
      expect(a1.cover, 'https://cover.test/a1.jpg');
      expect(a1.songCount, 2);
      expect(a1.songs.map((SirenSong song) => song.id).toList(), <String>['s1', 's2']);

      final SirenAlbum a2 = catalog.albums.firstWhere((SirenAlbum album) => album.id == 'a2');
      expect(a2.name, sirenUnknownTitle, reason: '专辑名为空 → 占位标题');
      expect(a2.artist, 'C', reason: '专辑无 artistes → 专辑内歌曲艺人并集');
      expect(a2.songCount, 1);
      expect(a2.songs.single.id, 's3');

      expect(catalog.songs.every((SirenSong song) => song.key == 'siren:song:${song.id}'), isTrue);
      expect(a1.key, 'siren:album:a1');
    });

    test('data 为 {list: [...]} 时同样解析（seq5 纠正原句）', () async {
      final _Transport transport = _Transport((Uri uri) async {
        if (uri.path == '/api/songs') {
          return _json(<String, Object?>{
            'code': 0,
            'data': <String, Object?>{
              'list': <Object?>[
                <String, Object?>{'cid': 's1', 'name': 'Song One', 'albumCid': 'a1', 'artists': <Object?>['A']},
              ],
            },
          });
        }
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{
            'list': <Object?>[
              <String, Object?>{'cid': 'a1', 'name': 'Album One', 'artistes': <Object?>['A'], 'coverUrl': 'c'},
            ],
          },
        });
      });
      final SirenCatalog catalog = await _repository(transport).loadCatalog();
      expect(catalog.songs.single.id, 's1');
      expect(catalog.albums.single.id, 'a1');
      expect(catalog.albums.single.songCount, 1);
    });

    test('code==200 / value 仅作 Qt HostReply 桥接次选，不是默认分支', () async {
      final _Transport transport = _Transport((Uri uri) async {
        if (uri.path == '/api/songs') {
          return _json(<String, Object?>{
            'code': 200,
            'value': <Object?>[
              <String, Object?>{'cid': 's1', 'name': 'Song One', 'albumCid': 'a1', 'artists': <Object?>['A']},
            ],
          });
        }
        return _json(<String, Object?>{
          'code': 200,
          'value': <Object?>[
            <String, Object?>{'cid': 'a1', 'name': 'Album One', 'artistes': <Object?>['A'], 'coverUrl': ''},
          ],
        });
      });
      final SirenCatalog catalog = await _repository(transport).loadCatalog();
      expect(catalog.songs.single.title, 'Song One');
      expect(catalog.albums.single.name, 'Album One');
    });

    test('HTTP 非 200 → 塞壬唱片请求失败（HTTP 503）', () async {
      final _Transport transport = _Transport((Uri uri) async {
        return const SirenHttpResult(statusCode: 503, bytes: <int>[]);
      });
      await expectLater(
        _repository(transport).loadCatalog(),
        throwsA(
          isA<SirenException>().having(
            (SirenException error) => error.message,
            'message',
            '塞壬唱片请求失败（HTTP 503）',
          ),
        ),
      );
    });

    test('响应不是 JSON → 塞壬唱片响应格式无效', () async {
      final _Transport transport = _Transport((Uri uri) async => _text('<html>503</html>'));
      await expectLater(
        _repository(transport).loadCatalog(),
        throwsA(
          isA<SirenException>().having(
            (SirenException error) => error.message,
            'message',
            startsWith('塞壬唱片响应格式无效：'),
          ),
        ),
      );
    });

    test('非 UTF-8 字节 → 塞壬唱片响应解码失败', () async {
      final _Transport transport = _Transport((Uri uri) async {
        return const SirenHttpResult(statusCode: 200, bytes: <int>[0xC3, 0x28, 0xFF]);
      });
      await expectLater(
        _repository(transport).loadCatalog(),
        throwsA(
          isA<SirenException>().having(
            (SirenException error) => error.message,
            'message',
            startsWith('塞壬唱片响应解码失败：'),
          ),
        ),
      );
    });

    test('code!=0 → 塞壬唱片返回 1001：服务繁忙（siren.mjs:105 文案）', () async {
      final _Transport transport = _Transport((Uri uri) async {
        return _json(<String, Object?>{'code': 1001, 'msg': '服务繁忙'});
      });
      await expectLater(
        _repository(transport).loadCatalog(),
        throwsA(
          isA<SirenException>().having(
            (SirenException error) => error.message,
            'message',
            '塞壬唱片返回 1001：服务繁忙',
          ),
        ),
      );
    });

    test('code 缺失且无 msg → 塞壬唱片返回 未知错误：请稍后重试', () async {
      final _Transport transport = _Transport((Uri uri) async {
        return _json(<String, Object?>{'data': <Object?>[]});
      });
      await expectLater(
        _repository(transport).loadCatalog(),
        throwsA(
          isA<SirenException>().having(
            (SirenException error) => error.message,
            'message',
            '塞壬唱片返回 未知错误：请稍后重试',
          ),
        ),
      );
    });

    test('data 不是数组 → 塞壬唱片响应格式无效：/api/songs 的 data 不是数组', () async {
      final _Transport transport = _Transport((Uri uri) async {
        if (uri.path == '/api/songs') {
          return _json(<String, Object?>{'code': 0, 'data': <String, Object?>{'rows': <Object?>[]}});
        }
        return _json(<String, Object?>{
          'code': 0,
          'data': <Object?>[
            <String, Object?>{'cid': 'a1', 'name': 'Album One', 'artistes': <Object?>['A']},
          ],
        });
      });
      await expectLater(
        _repository(transport).loadCatalog(),
        throwsA(
          isA<SirenException>().having(
            (SirenException error) => error.message,
            'message',
            '塞壬唱片响应格式无效：/api/songs 的 data 不是数组',
          ),
        ),
      );
    });

    test('注入传输层的超时 → 塞壬唱片请求超时（3 秒）', () async {
      final _Transport transport = _Transport((Uri uri) {
        return Future<SirenHttpResult>.error(TimeoutException('slow'));
      });
      await expectLater(
        _repository(transport, timeout: const Duration(seconds: 3)).loadCatalog(),
        throwsA(
          isA<SirenException>().having(
            (SirenException error) => error.message,
            'message',
            '塞壬唱片请求超时（3 秒）',
          ),
        ),
      );
    });

    test('baseUri 的子路径被保留（便于测试/反代注入）', () async {
      // 这条断言的是"子路径不被吃掉"，所以处理器必须按带前缀的真实路径应答；
      // 直接复用只认 /api/* 的 _catalogHandler 会把正确行为报成 Bad state。
      Future<SirenHttpResult> prefixed(Uri uri) {
        final String path = uri.path;
        if (!path.startsWith('/base/')) {
          throw StateError('baseUri 子路径被吃掉：$path');
        }
        return _catalogHandler(uri.replace(path: path.substring('/base'.length)));
      }

      final _Transport transport = _Transport(prefixed);
      await _repository(transport, baseUri: Uri.parse('https://example.test/base/')).loadCatalog();
      expect(transport.paths, <String>['/base/api/songs', '/base/api/albums']);
    });

    test('close() 之后请求被拒绝：塞壬唱片请求已关闭', () async {
      final _Transport transport = _Transport(_catalogHandler);
      final SirenRepository repository = _repository(transport);
      repository.close();
      await expectLater(
        repository.loadCatalog(),
        throwsA(
          isA<SirenException>().having(
            (SirenException error) => error.message,
            'message',
            '塞壬唱片请求已关闭',
          ),
        ),
      );
      expect(transport.calls, isEmpty);
    });
  });

  group('SirenRepository.songDetail（siren.mjs:282-296 / :482-495）', () {
    test('每次调用都 fresh 请求，sourceUrl/lyricUrl 取当次响应', () async {
      int call = 0;
      final _Transport transport = _Transport((Uri uri) async {
        call += 1;
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{
            'name': ' Song One ',
            'sourceUrl': ' https://file.test/1.flac?sign=$call',
            'lyricUrl': 'https://file.test/1.lrc',
          },
        });
      });
      final SirenRepository repository = _repository(transport);

      final SirenSongDetail first = await repository.songDetail('s1');
      final SirenSongDetail second = await repository.songDetail('s1');

      expect(transport.calls.length, 2, reason: '直链带时效签名，不能复用 detail 缓存');
      expect(transport.paths, <String>['/api/song/s1', '/api/song/s1']);
      expect(first.title, 'Song One');
      expect(first.sourceUrl, 'https://file.test/1.flac?sign=1');
      expect(first.lyricUrl, 'https://file.test/1.lrc');
      expect(second.sourceUrl, 'https://file.test/1.flac?sign=2');
      expect(first.playable, isTrue);
    });

    test('id 需要 url-encode', () async {
      final _Transport transport = _Transport((Uri uri) async {
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{'name': 'weird', 'sourceUrl': 'https://f/x', 'lyricUrl': ''},
        });
      });
      await _repository(transport).songDetail('a/b c');
      expect(transport.calls.single.path, '/api/song/a%2Fb%20c');
    });

    test('空 id 直接报格式无效且不发请求', () async {
      final _Transport transport = _Transport(_catalogHandler);
      final SirenRepository repository = _repository(transport);
      await expectLater(
        repository.songDetail('   '),
        throwsA(
          isA<SirenException>().having(
            (SirenException error) => error.message,
            'message',
            '塞壬唱片响应格式无效：歌曲 id 为空',
          ),
        ),
      );
      expect(transport.calls, isEmpty);
    });

    test('sourceUrl 为空不算错误（播放口负责拒绝），playable=false', () async {
      final _Transport transport = _Transport((Uri uri) async {
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{'name': 'Song One', 'sourceUrl': '  ', 'lyricUrl': ''},
        });
      });
      final SirenSongDetail detail = await _repository(transport).songDetail('s1');
      expect(detail.sourceUrl, '');
      expect(detail.playable, isFalse);
      expect(detail.lyricUrl, '');
    });
  });

  group('SirenRepository.albumDetail（siren.mjs:298-307 / :414-439）', () {
    SirenAlbum catalogAlbum() {
      return const SirenAlbum(
        id: 'a1',
        name: 'Album One',
        artist: 'A',
        cover: 'https://cover.test/a1.jpg',
        songCount: 2,
        songs: <SirenSong>[],
      );
    }

    test('详情曲目强制 albumCid/专辑名/封面，艺人取 artistes，songCount=detail 曲目数', () async {
      final _Transport transport = _Transport((Uri uri) async {
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{
            'name': 'Album One (Deluxe)',
            'coverUrl': 'https://cover.test/a1-deluxe.jpg',
            'artistes': <Object?>['A', 'B'],
            'songs': <Object?>[
              <String, Object?>{
                'cid': 's1',
                'name': 'Song One',
                'artistes': <Object?>['A'],
                'sourceUrl': 'https://file.test/1.flac',
                'lyricUrl': 'https://file.test/1.lrc',
              },
              <String, Object?>{'cid': 's2', 'name': '', 'artistes': <Object?>[], 'sourceUrl': '', 'lyricUrl': ''},
            ],
          },
        });
      });
      final SirenAlbum album = await _repository(transport).albumDetail(catalogAlbum());

      expect(transport.paths, <String>['/api/album/a1/detail']);
      expect(album.name, 'Album One (Deluxe)');
      expect(album.cover, 'https://cover.test/a1-deluxe.jpg');
      expect(album.artist, 'A / B');
      expect(album.songCount, 2);
      expect(album.songs.length, 2);
      expect(album.songs[0].albumId, 'a1');
      expect(album.songs[0].album, 'Album One (Deluxe)');
      expect(album.songs[0].cover, 'https://cover.test/a1-deluxe.jpg');
      expect(album.songs[0].artist, 'A');
      expect(album.songs[0].sourceUrl, 'https://file.test/1.flac');
      expect(album.songs[1].title, sirenUnknownTitle);
      expect(album.songs[1].artist, 'A / B', reason: '曲目 artistes 为空 → 专辑艺人');
    });

    test('detail 空字段不覆盖曲库值，歌曲列表以 detail 为准', () async {
      final _Transport transport = _Transport((Uri uri) async {
        return _json(<String, Object?>{
          'code': 0,
          'data': <String, Object?>{'songs': <Object?>[]},
        });
      });
      final SirenAlbum album = await _repository(transport).albumDetail(catalogAlbum());
      expect(album.name, 'Album One');
      expect(album.cover, 'https://cover.test/a1.jpg');
      expect(album.artist, 'A');
      expect(album.songCount, 0);
      expect(album.songs, isEmpty);
    });
  });

  group('SirenRepository.lyricsText（siren.mjs:56-74 / :497-513）', () {
    test('返回歌词原文（UTF-8）', () async {
      final _Transport transport = _Transport((Uri uri) async => _text('[00:00.00]第一行\n[00:01.50]第二行【翻译】'));
      final String text = await _repository(transport).lyricsText('https://file.test/1.lrc');
      expect(transport.calls.single.toString(), 'https://file.test/1.lrc');
      expect(text, contains('[00:01.50]第二行【翻译】'));
    });

    test('资源 HTTP 非 200 → 塞壬唱片资源请求失败（HTTP 500）（文案与 request 分支不同）', () async {
      final _Transport transport = _Transport((Uri uri) async {
        return const SirenHttpResult(statusCode: 500, bytes: <int>[]);
      });
      await expectLater(
        _repository(transport).lyricsText('https://file.test/1.lrc'),
        throwsA(
          isA<SirenException>().having(
            (SirenException error) => error.message,
            'message',
            '塞壬唱片资源请求失败（HTTP 500）',
          ),
        ),
      );
    });

    test('非法歌词地址 → 塞壬唱片响应格式无效：歌词地址无效', () async {
      final _Transport transport = _Transport(_catalogHandler);
      await expectLater(
        _repository(transport).lyricsText('not a url'),
        throwsA(
          isA<SirenException>().having(
            (SirenException error) => error.message,
            'message',
            startsWith('塞壬唱片响应格式无效：歌词地址无效'),
          ),
        ),
      );
      expect(transport.calls, isEmpty);
    });
  });

  group('basic_models · LRC 解析（lyrics-format.cjs:35-53 / :128-213）', () {
    test('多时间戳展开、按 startMs 排序、行尾【翻译】拆出', () {
      final BasicLyricsDocument document = parseBasicLyrics(
        '[00:02.00][00:05.00]副歌【Chorus】\n[00:01.00]第一行\n',
      );
      expect(document.timed, isTrue);
      expect(document.lines.length, 3);
      expect(document.lines[0].startMs, 1000);
      expect(document.lines[0].text, '第一行');
      expect(document.lines[1].startMs, 2000);
      expect(document.lines[1].text, '副歌');
      expect(document.lines[1].translation, 'Chorus');
      expect(document.lines[2].startMs, 5000);
      expect(document.lines[2].text, '副歌');
    });

    test('[offset:] 标签夹到 ±10000，且不进入行文本', () {
      final BasicLyricsDocument document = parseBasicLyrics('[offset:250]\n[00:01.00]第一行\n');
      expect(document.offsetMs, 250);
      expect(document.lines.single.text, '第一行');

      final BasicLyricsDocument clamped = parseBasicLyrics('[offset:999999]\n[00:01.00]x');
      expect(clamped.offsetMs, 10000);
      final BasicLyricsDocument negative = parseBasicLyrics('[offset:-999999]\n[00:01.00]x');
      expect(negative.offsetMs, -10000);
    });

    test('无时间轴文本 → timed=false、plainText 保留、isEmpty 可判定', () {
      final BasicLyricsDocument document = parseBasicLyrics('纯文本歌词\n第二行');
      expect(document.timed, isFalse);
      expect(document.lines, isEmpty);
      expect(document.plainText, '纯文本歌词\n第二行');
      expect(document.isEmpty, isFalse);
      expect(BasicLyricsDocument.empty.isEmpty, isTrue);
    });

    test('toLyricsDocument 产出 validLyricsDocument 认的形状', () {
      final Map<String, Object?> shape = parseBasicLyrics('[00:01.00]x').toLyricsDocument();
      expect(shape['version'], 1);
      expect(shape['timing'], 'line');
      expect(shape['source'], 'siren');
      expect(shape['offsetMs'], 0);
      expect((shape['lines'] as List<Object?>).length, 1);
      expect(parseBasicLyrics('纯文本').toLyricsDocument()['timing'], 'none');
    });

    test('HTML 实体与 CRLF 清洗', () {
      final BasicLyricsDocument document = parseBasicLyrics('[00:01.00]A &amp; B &lt;C&gt;\r\n[00:02.00]D &quot;x&quot;');
      expect(document.lines[0].text, 'A & B <C>');
      expect(document.lines[1].text, 'D "x"');
    });
  });

  group('basic_models · 匹配与曲目形状（MusicSiren.cpp:105-124）', () {
    const SirenSong song = SirenSong(
      id: 's1',
      title: 'Song One',
      artist: 'A / B',
      album: 'Album One',
      albumId: 'a1',
      cover: 'c',
      sourceUrl: '',
      lyricUrl: '',
      durationMs: 0,
    );
    const SirenAlbum album = SirenAlbum(
      id: 'a1',
      name: 'Album One',
      artist: 'A',
      cover: 'c',
      songCount: 1,
      songs: <SirenSong>[song],
    );

    test('空词全匹配；title/album/artist 任一命中；大小写不敏感', () {
      expect(sirenSongMatches(song, '   '), isTrue);
      expect(sirenSongMatches(song, 'one'), isTrue);
      expect(sirenSongMatches(song, 'album'), isTrue);
      expect(sirenSongMatches(song, 'a / b'), isTrue);
      expect(sirenSongMatches(song, 'zzz'), isFalse);
      expect(sirenAlbumMatches(album, 'album'), isTrue);
      expect(sirenAlbumMatches(album, 'song'), isFalse);
      expect(filterSirenSongs(const <SirenSong>[song], 'zzz'), isEmpty);
      expect(filterSirenAlbums(const <SirenAlbum>[album], 'one').single.id, 'a1');
    });

    test('toTrack 给出 MusicPlayer 认的 provider/kind/id 与专辑字段', () {
      final Map<String, Object?> track = song.toTrack();
      expect(track['provider'], sirenProvider);
      expect(track['kind'], 'song');
      expect(track['id'], 's1');
      expect(track['key'], 'siren:song:s1');
      expect(track['albumID'], 'a1');
      expect(track['title'], 'Song One');
    });
  });
}
