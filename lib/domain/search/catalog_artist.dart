// 音乐人归并检索：把曲库歌曲按作者归并成音乐人条目，再按查询做子串过滤。
//
// 规范来源：Qt/src/MusicSiren.cpp:91-190（searchSirenLocal 的 artist 分支）
//   - 逐首歌遍历 artists 数组，按 name 归并，每出现一次 trackCount +1；
//   - name 为空则跳过；
//
// 排序（与 Qt 一致）：
//   - trackCount 降序；
//   - 相同 trackCount 时按 title（即 name）升序比较。
//
// 纯 Dart：不依赖 Flutter，便于在领域层单测。

/// 归并后的音乐人条目。
class CatalogArtist {
  const CatalogArtist(this.id, this.name, this.trackCount);

  /// 'artist:' + name，与 Qt 的 MusicData::item('artist', ...) 键形状一致。
  final String id;

  /// 作者名，同时作为排序/匹配用的 title。
  final String name;

  /// 该作者在曲库中出现的曲目数。
  final int trackCount;

  @override
  String toString() =>
      'CatalogArtist(id: $id, name: $name, trackCount: $trackCount)';
}

/// 曲库音乐人索引：构建一次，[search] 可重复调用。
class CatalogArtistIndex {
  /// [songs] 每项至少含 `id` / `title` / `album` / `artist`；
  /// `artist` 为单串或 `List<String>` 均可。
  CatalogArtistIndex(List<Map<String, Object?>> songs)
      : _artists = _build(songs);

  final List<CatalogArtist> _artists;

  /// 按 name 归并并排序；构造期一次完成，避免每次检索重复归并。
  static List<CatalogArtist> _build(List<Map<String, Object?>> songs) {
    final counts = <String, int>{};
    for (final song in songs) {
      for (final name in _artistNames(song['artist'])) {
        if (name.trim().isEmpty) {
          continue;
        }
        counts[name] = (counts[name] ?? 0) + 1;
      }
    }
    final artists = <CatalogArtist>[
      for (final entry in counts.entries)
        CatalogArtist('artist:${entry.key}', entry.key, entry.value),
    ];
    artists.sort((left, right) {
      final byCount = right.trackCount - left.trackCount;
      if (byCount != 0) {
        return byCount;
      }
      return left.name.compareTo(right.name);
    });
    return artists;
  }

  /// 把 song['artist'] 归一成作者名列表（单串 / `List<String>` 两种形状）。
  static List<String> _artistNames(Object? raw) {
    if (raw is String) {
      return <String>[raw];
    }
    if (raw is List) {
      return <String>[
        for (final entry in raw)
          if (entry is String) entry,
      ];
    }
    return const <String>[];
  }

  /// 大小写不敏感的子串匹配 name；空查询（trim 后）返回空列表。
  List<CatalogArtist> search(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) {
      return List<CatalogArtist>.empty(growable: true);
    }
    return <CatalogArtist>[
      for (final artist in _artists)
        if (artist.name.toLowerCase().contains(needle)) artist,
    ];
  }
}
