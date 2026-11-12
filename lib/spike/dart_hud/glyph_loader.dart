/// T13-S02 - glyph atlas reader for the Dart HUD spike (isolated, fail-closed).
///
/// This loader only *reads* `Assets/fonts/misans-glyphs.json` and probes the
/// presence/size of the shipped font files. It never parses an OTF/TTF, never
/// installs a font, never mutates `pubspec.yaml` and never feeds the production
/// text stack: the spike has no production consumer.
///
/// Atlas shape (repository truth, one JSON object per weight):
///
/// ```json
/// {"light":{"units":1000,"ascent":1044,"descent":-282,
///           "glyphs":{"A":{"advance":0.639,"path":"M624 2 ..."}}}}
/// ```
///
/// Four weights: light / regular / demibold / bold.
/// * `advance` is an em fraction: with `units == 1000`, 0.639 means 639 units.
/// * `path` is the outline as an SVG path string in the same 1000-unit em,
///   y-up. It is copied verbatim; this file never invents or repairs an
///   outline. An entry without a non-empty string path is dropped and reported.
///
/// Failure model: every missing file, malformed weight or malformed glyph is a
/// structured entry in [GlyphLoadResult.errors] / [GlyphLoadResult.missingFiles];
/// [loadSpikeGlyphs] never throws. [GlyphLoadResult.paintable] is true only when
/// the atlas parsed cleanly and every expected font file exists.
library;

import 'dart:convert';
import 'dart:io';

/// Atlas path relative to the repository root.
const String kGlyphAtlasRelativePath = 'Assets/fonts/misans-glyphs.json';

/// The four weights present in the atlas, in file order.
const List<String> kGlyphWeightNames = <String>['light', 'regular', 'demibold', 'bold'];

/// Shipped font files whose existence is probed (never opened as fonts).
const List<String> kGlyphFontRelativePaths = <String>[
  'Assets/fonts/RhineMiSans-light.otf',
  'Assets/fonts/RhineMiSans-regular.otf',
  'Assets/fonts/RhineMiSans-demibold.otf',
  'Assets/fonts/RhineMiSans-bold.otf',
  'Assets/fonts/NotoSansSymbols2-Regular.ttf',
];

/// Font-build metadata file probed alongside the fonts.
const String kMusicFontsVersionRelativePath = 'Assets/fonts/music-fonts.version';

/// One glyph: an em-fraction advance and the exact SVG outline string.
final class GlyphEntry {
  const GlyphEntry({required this.character, required this.advance, required this.path});

  final String character;

  /// Em fraction (multiply by the point size to get stage units).
  final double advance;

  /// SVG path, 1000-unit em, y-up. Never empty: entries without one are dropped.
  final String path;

  @override
  String toString() => 'GlyphEntry($character, advance=$advance, path=${path.length} chars)';
}

/// One parsed weight table.
final class GlyphWeight {
  const GlyphWeight({
    required this.weight,
    required this.units,
    required this.ascent,
    required this.descent,
    required this.glyphs,
    required this.source,
  });

  final String weight;

  /// Font design units per em (atlas truth, 1000 today).
  final int units;

  /// Vertical metrics from the atlas header (font units).
  final double ascent;
  final double descent;

  /// Character -> glyph, insertion order preserved from the JSON object.
  final Map<String, GlyphEntry> glyphs;

  /// Atlas path this weight was read from.
  final String source;

  int get glyphCount => glyphs.length;
}

/// Existence/size probe for one expected file.
final class GlyphFileProbe {
  const GlyphFileProbe({required this.path, required this.exists, required this.bytes});

  final String path;
  final bool exists;

  /// File length in bytes, 0 when absent and -1 when unreadable.
  final int bytes;

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'exists': exists,
        'bytes': bytes,
      };

  @override
  String toString() => 'GlyphFileProbe($path, exists=$exists, bytes=$bytes)';
}

/// Structured outcome of [loadSpikeGlyphs]. Never thrown, always returned.
final class GlyphLoadResult {
  const GlyphLoadResult({
    required this.atlasPath,
    required this.weights,
    required this.files,
    required this.errors,
    required this.missingFiles,
  });

  /// The atlas path that was probed.
  final String atlasPath;

  /// Successfully parsed weights (possibly a subset when the atlas is damaged).
  final Map<String, GlyphWeight> weights;

  /// Every probed file, atlas first, then fonts, then the version metadata.
  final List<GlyphFileProbe> files;

  /// Structural problems (bad JSON, missing weight header, bad glyph entry...).
  final List<String> errors;

  /// Paths that do not exist on disk.
  final List<String> missingFiles;

  /// True only when the atlas is fully parsed and every expected file exists.
  ///
  /// Fail-closed: partial data is reported but never declared paintable, so a
  /// host cannot accidentally ship a spike with half an atlas.
  bool get paintable =>
      errors.isEmpty && missingFiles.isEmpty && weights.length == kGlyphWeightNames.length;

  /// Total parsed glyphs across all weights.
  int get glyphCount =>
      weights.values.fold<int>(0, (int sum, GlyphWeight weight) => sum + weight.glyphCount);

  /// Per-weight glyph counts, for coverage reporting.
  Map<String, int> get coverage => <String, int>{
        for (final MapEntry<String, GlyphWeight> entry in weights.entries)
          entry.key: entry.value.glyphCount,
      };

  /// Characters (grapheme-insensitive code units) missing from one weight.
  ///
  /// Used by tests and the integration spike to state fallback gaps instead of
  /// pretending the atlas covers everything.
  List<String> missingCharacters(String weight, Iterable<String> characters) {
    final GlyphWeight? table = weights[weight];
    if (table == null) {
      return characters.toSet().toList(growable: false);
    }
    return <String>[
      for (final String character in characters.toSet())
        if (!table.glyphs.containsKey(character)) character,
    ];
  }

  /// Missing characters per weight for one requested string/set.
  Map<String, List<String>> fallbackGaps(String characters) {
    final List<String> unique = characters.split('').toSet().toList(growable: false);
    return <String, List<String>>{
      for (final String weight in kGlyphWeightNames)
        weight: missingCharacters(weight, unique),
    };
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'atlasPath': atlasPath,
        'paintable': paintable,
        'glyphCount': glyphCount,
        'coverage': coverage,
        'missingFiles': missingFiles,
        'errors': errors,
        'files': <Map<String, Object?>>[for (final GlyphFileProbe file in files) file.toJson()],
      };

  @override
  String toString() =>
      'GlyphLoadResult(paintable=$paintable, weights=${weights.length}, '
      'glyphs=$glyphCount, missingFiles=${missingFiles.length}, errors=${errors.length})';
}

/// Reads the atlas and probes the shipped font files. Never throws.
///
/// [root] is the repository root; the default `'.'` resolves the documented
/// relative paths against the process working directory.
GlyphLoadResult loadSpikeGlyphs({String root = '.'}) {
  try {
    return _load(root);
  } catch (error) {
    return GlyphLoadResult(
      atlasPath: _join(root, kGlyphAtlasRelativePath),
      weights: const <String, GlyphWeight>{},
      files: const <GlyphFileProbe>[],
      errors: List<String>.unmodifiable(<String>['unexpected loader failure: $error']),
      missingFiles: const <String>[],
    );
  }
}

GlyphLoadResult _load(String root) {
  final List<String> errors = <String>[];
  final List<String> missing = <String>[];
  final List<GlyphFileProbe> files = <GlyphFileProbe>[];
  final Map<String, GlyphWeight> weights = <String, GlyphWeight>{};

  final String atlasPath = _join(root, kGlyphAtlasRelativePath);
  final GlyphFileProbe atlasProbe = _probe(atlasPath);
  files.add(atlasProbe);
  if (!atlasProbe.exists) {
    missing.add(atlasPath);
  }
  for (final String relative in kGlyphFontRelativePaths) {
    final GlyphFileProbe probe = _probe(_join(root, relative));
    files.add(probe);
    if (!probe.exists) {
      missing.add(probe.path);
    }
  }
  final GlyphFileProbe versionProbe = _probe(_join(root, kMusicFontsVersionRelativePath));
  files.add(versionProbe);
  if (!versionProbe.exists) {
    missing.add(versionProbe.path);
  }

  if (!atlasProbe.exists) {
    return GlyphLoadResult(
      atlasPath: atlasPath,
      weights: const <String, GlyphWeight>{},
      files: List<GlyphFileProbe>.unmodifiable(files),
      errors: List<String>.unmodifiable(errors),
      missingFiles: List<String>.unmodifiable(missing),
    );
  }

  String text;
  try {
    text = File(atlasPath).readAsStringSync();
  } on FileSystemException catch (error) {
    errors.add('cannot read atlas: $error');
    return GlyphLoadResult(
      atlasPath: atlasPath,
      weights: const <String, GlyphWeight>{},
      files: List<GlyphFileProbe>.unmodifiable(files),
      errors: List<String>.unmodifiable(errors),
      missingFiles: List<String>.unmodifiable(missing),
    );
  }

  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    errors.add('atlas is not valid JSON: $error');
    return GlyphLoadResult(
      atlasPath: atlasPath,
      weights: const <String, GlyphWeight>{},
      files: List<GlyphFileProbe>.unmodifiable(files),
      errors: List<String>.unmodifiable(errors),
      missingFiles: List<String>.unmodifiable(missing),
    );
  }

  if (decoded is! Map<String, Object?>) {
    errors.add('atlas root is not a JSON object (got ${decoded.runtimeType})');
    return GlyphLoadResult(
      atlasPath: atlasPath,
      weights: const <String, GlyphWeight>{},
      files: List<GlyphFileProbe>.unmodifiable(files),
      errors: List<String>.unmodifiable(errors),
      missingFiles: List<String>.unmodifiable(missing),
    );
  }

  void note(String message) {
    if (errors.length < 64) {
      errors.add(message);
    }
  }

  for (final String weightName in kGlyphWeightNames) {
    final Object? raw = decoded[weightName];
    if (raw is! Map<String, Object?>) {
      note('weight "$weightName" is missing or not an object');
      continue;
    }
    final Object? units = raw['units'];
    final Object? ascent = raw['ascent'];
    final Object? descent = raw['descent'];
    final Object? glyphsRaw = raw['glyphs'];
    if (units is! num || ascent is! num || descent is! num || glyphsRaw is! Map<String, Object?>) {
      note('weight "$weightName" header or glyph table is malformed');
      continue;
    }

    final Map<String, GlyphEntry> glyphs = <String, GlyphEntry>{};
    for (final MapEntry<String, Object?> entry in glyphsRaw.entries) {
      final String character = entry.key;
      final Object? value = entry.value;
      if (character.isEmpty) {
        note('weight "$weightName" has an empty character key');
        continue;
      }
      if (value is! Map<String, Object?>) {
        note('weight "$weightName" glyph "$character" is not an object');
        continue;
      }
      final Object? advance = value['advance'];
      final Object? path = value['path'];
      if (advance is! num) {
        note('weight "$weightName" glyph "$character" has no numeric advance');
        continue;
      }
      if (path is! String || path.isEmpty) {
        // Fail-closed: never synthesize an outline.
        note('weight "$weightName" glyph "$character" has no outline path; dropped');
        continue;
      }
      glyphs[character] = GlyphEntry(
        character: character,
        advance: advance.toDouble(),
        path: path,
      );
    }

    weights[weightName] = GlyphWeight(
      weight: weightName,
      units: units.toInt(),
      ascent: ascent.toDouble(),
      descent: descent.toDouble(),
      glyphs: Map<String, GlyphEntry>.unmodifiable(glyphs),
      source: atlasPath,
    );
  }

  return GlyphLoadResult(
    atlasPath: atlasPath,
    weights: Map<String, GlyphWeight>.unmodifiable(weights),
    files: List<GlyphFileProbe>.unmodifiable(files),
    errors: List<String>.unmodifiable(errors),
    missingFiles: List<String>.unmodifiable(missing),
  );
}

GlyphFileProbe _probe(String path) {
  final File file = File(path);
  bool exists = false;
  int bytes = 0;
  try {
    exists = file.existsSync();
    if (exists) {
      bytes = file.lengthSync();
    }
  } catch (_) {
    exists = false;
    bytes = -1;
  }
  return GlyphFileProbe(path: path, exists: exists, bytes: bytes);
}

String _join(String root, String relative) {
  if (root.isEmpty || root == '.') {
    return relative;
  }
  return root.endsWith('/') ? '$root$relative' : '$root/$relative';
}
