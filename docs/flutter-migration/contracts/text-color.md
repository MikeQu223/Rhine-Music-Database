# Text, glyph and color contract (T04)

Status: **frozen from Qt source at baseline `8ed3067b0812eb2612f7841ec127a6e8ca93231b`**. This contract is evidence E1 (direct source read), not device-measured E0. No test, build, analyze, Flutter run, Qt run, adb, APK, screenshot, or device validation was executed while producing it.

Owner: TEXT-CONTRACT (T04). Consumer: T31 and every Flutter surface that paints HUD text or calibrated colors. The old Flutter UI is **not** normative; only the Qt source referenced below is.

Normative terms: **MUST**, **MUST NOT**, **SHOULD**. A value written as a JSON array is ordered; do not reorder, normalize, deduplicate, or replace it with a map.

## 0. Evidence and scope

| Concern | Qt source read |
|---|---|
| Font load, glyph table, advance/path, baseline, tracking, fit, art advance | `Qt/src/Glyphs.cpp:35-49`, `:51-90`, `:108-188`, `:190-349`, `:403-412`, `:530-601`, `:637-859`, `:860-888`; `Qt/src/Glyphs.h:21-24` (default `Glyph`); `Qt/src/NativeHudBoot.cpp:143-311` (boot geometry) |
| Default HUD ink, fit, archive mask, brand, footer | `Qt/src/NativeHud.cpp:10-15`, `:48-76`, `:313-373` |
| Boot palette and constants | `Qt/src/NativeHudBoot.cpp:143-153`, `:155-380` |
| Canonical palette and variants | `Qt/src/CollectionDetailCard.cpp:10-50`, `Qt/src/DiscoverMusicCard.cpp:55-105`, `Qt/src/PlayerBar.cpp:17-31`, `Qt/src/PlaybackQueueCard.cpp:14-20`, `Qt/src/NativeHudModal.cpp:85-178` |
| Runtime resource root | `Qt/src/main.cpp:940-968` |
| Plan card | `docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:416-423` |

Out of scope: the 17-op array index table, hit arrays, frame publication, and generic alpha/transform/clip dispatch (T03); domain, login, settings, session, queue, lyrics, search, IME, and notification behavior (T05-T07); production Flutter wiring (ARCH_BLOCKED until the host selects a renderer).

## 1. Font program and asset loading

### 1.1 Assets

The HUD uses exactly five font files, two JSON tables and one version stamp. Source copies live in `Assets/fonts/` and `Resources/`; the runtime copy lives in `output/resources/` and is the directory `Glyphs` actually loads.

| Key | File | Bytes | SHA-256 (provenance) | unitsPerEm | hhea/typo ascent | descent | usWin ascent/descent | usWeightClass | Family / subfamily |
|---|---|---:|---|---:|---:|---:|---:|---:|---|
| `light` | `RhineMiSans-light.otf` | 6796588 | `465f4050e0430232d87ab546b86077c744d40a0c605a00e9f4809c7ddf1a5390` | 1000 | 1044 | -282 | 1044 / 282 | 300 | Rhine MiSans / light |
| `regular` | `RhineMiSans-regular.otf` | 6725816 | `0fd648712a13af8ede02892f57db2f375bb5681be4172ac6b7edb300302efee7` | 1000 | 1044 | -282 | 1044 / 282 | 400 | Rhine MiSans / regular |
| `demibold` | `RhineMiSans-demibold.otf` | 6682092 | `9e6eac121a57a296af45989212a5f98f29969a6dd68fa620db9d3e696d62ec20` | 1000 | 1044 | -282 | 1044 / 282 | 600 | Rhine MiSans / demibold |
| `bold` | `RhineMiSans-bold.otf` | 6797880 | `9f473f5fcf17c0163f4ce4fadfc83c9a7c489763ec24945bdc6879e112bb0c1c` | 1000 | 1044 | -282 | 1044 / 282 | 700 | Rhine MiSans / bold |
| `symbols` | `NotoSansSymbols2-Regular.ttf` | 1233128 | `7d5fb73b7ca67a6798101741f5d280a3d016a56a197afcd4199dbb57b4b82a21` | 1000 | 1069 | -630 | 1069 / 630 | 400 | Noto Sans Symbols 2 / Regular |
| glyph table | `misans-glyphs.json` | 1683324 | `864f702a40bf50b9c779613c2a5c0fb30dfada9a243fb11884550c46edaaa718` | — | — | — | — | — | four weight objects |
| boot lettering | `boot-lettering-art.json` | 39328 | `8566f894c5f5578ad635a9a6eca4bb6cb60a42d6079a8b6c454c17ebe08a1726` | — | — | — | — | — | top-level art keys |
| font version | `music-fonts.version` | 21 | `3b05e5e722287e2431901d3d060b25eb6eeba8f449eb95eaafdc7837bb748216` | — | — | — | — | — | single line with a trailing LF |

`music-fonts.version` contains exactly `full-misans-4.003-v1` followed by a single LF (20 characters plus the LF, 21 bytes in total).

The `unitsPerEm`, ascender/descender, `usWin` and `usWeightClass` columns are read from the shipped binaries' own `head` / `hhea` / `OS/2` / `name` tables, not derived from the JSON tables. All five fonts have `hhea.lineGap == 0` and `OS/2.sTypoLineGap == 0` (the MiSans OS/2 tables are version 3, the Noto table version 4). The four MiSans weights all register the family name `Rhine MiSans` and differ only in subfamily (`light` / `regular` / `demibold` / `bold`) and `usWeightClass` (300 / 400 / 600 / 700). The JSON `ascent: 1044` equals the MiSans `hhea`/`OS/2` ascender; the symbols font's 1069/630 must not be substituted for the MiSans baseline factor.

`misans-glyphs.json` has four top-level objects, keys `light`, `regular`, `demibold`, `bold`. Each object has `units: 1000`, `ascent: 1044`, `descent: -282`, and `glyphs`; each weight contains exactly 1007 glyphs in the frozen asset. This module re-read that table directly and confirms all four weights carry `units: 1000`, `ascent: 1044`, `descent: -282` and exactly 1007 entries; the space glyph advance is `0.286` / `0.29` / `0.293` / `0.298` for light / regular / demibold / bold respectively (it is **not** the same in every weight), while the ellipsis `…` advance is `1.0` in every weight. The binary-derived columns above (SHA-256, `unitsPerEm`, ascender/descender, `usWin`, `usWeightClass`, family and subfamily) are inherited inventory provenance and were **not** re-derived in this module. A glyph entry is `{ "advance": <number in em>, "path": "<SVG path in 1000-unit glyph space>" }`; its lookup key is the two-part string `weight + ":" + character`, never a codepoint integer. `boot-lettering-art.json` maps a top-level art key (`access`, `identity`, `request`, `processing`, `processingGlitch`, `permission`, `brand`, `welcome`, `company`, `database`) to `{ "letters": [ { "width": <number>, "path": "<SVG path>" }, ... ] }`. Do not synthesize lettering from the OTF: the boot art uses these contours and advances.

### 1.2 Root resolution

`Qt/src/main.cpp:940-968` resolves the resource root in this order:

1. `RHINE_RESOURCES` if non-empty.
2. Packaged candidates: Android `androidResourceRoot()`; macOS `applicationDirPath()/../Resources`; iOS `applicationDirPath()/RhineAssets`; other desktop `applicationDirPath()/resources`, then `applicationDirPath()/../resources`.
3. A candidate is accepted only when `<candidate>/slots.json` exists.
4. If nothing matches, fall back to `QDir::currentPath() + "/output/resources"`.

Flutter MUST mirror the same precedence, or explicitly require the packaged resource directory; it MUST NOT silently use the repository `Assets/fonts/` at runtime. The five font files and both JSON tables MUST ship together and be replaced as one versioned set.

### 1.3 Loading order (exact)

In `Glyphs` construction (`Qt/src/Glyphs.cpp:65-90`):

1. For each weight in `light`, `regular`, `demibold`, `bold`:
   - Load `root + "/RhineMiSans-" + weight + ".otf"` as `QRawFont(path, 1000, QFont::PreferNoHinting)`.
   - Register the same **file path** — `QFontDatabase::addApplicationFont(file)`, not the mapped bytes (`Qt/src/Glyphs.cpp:69`) — and take `applicationFontFamilies(id).value(0)` as `layoutFamilies[weight]`. All four register the family `Rhine MiSans`; the style name distinguishes the weight. Only the `symbols` slot is built from mapped bytes.
   - If registration fails, `layoutFamilies[weight]` stays empty and `layoutText` uses Qt's `GeneralFont`; this is a failure fallback, not the normal path.
2. Load `root + "/NotoSansSymbols2-Regular.ttf"` into the separate `symbols` slot. The bytes are memory-mapped and wrapped as `QRawFont(bytes, 1000, PreferNoHinting)`; if that fails, retry by filename. The symbols font is never registered as the application text family.
3. Parse `root + "/misans-glyphs.json"` into the per-weight glyph map. The JSON entry takes precedence over the OTF for the same `weight:char`.
4. Parse `root + "/boot-lettering-art.json"` into the lettering map.

A weight whose font cannot be loaded still **occupies** its `fonts` key: the constructor assigns `fonts[weight] = QRawFont(file, 1000, QFont::PreferNoHinting)` unconditionally for all four weights (`Qt/src/Glyphs.cpp:66-68`), so `fonts.value(weight, fonts["regular"])` (`:114`, `:147`, `:272`) substitutes `regular` only when the key is **absent**, never when the font is invalid. `QFontDatabase::addApplicationFont` failure likewise only empties `layoutFamilies[weight]` (`:69-72`). An unreadable OTF therefore behaves as an invalid `QRawFont` with an empty `glyphIndexesForString`, not as a silent substitute of `regular`: the lookup falls through to `symbols` and then to the default glyph below. Flutter MUST reproduce that, and MUST NOT treat a broken weight file as a license to use `regular` outlines or metrics. A missing glyph in the selected weight MUST try `symbols`; if symbols also has no glyph index, the lookup returns the **default `Glyph`**, whose advance is **`1` em unit** — `Qt/src/Glyphs.h:21-24` declares `double advance = 1;` and `Qt/src/Glyphs.cpp:278-280` returns `{}` on a double miss — with an empty path. The cursor therefore still moves by `1 * size + tracking` (`Qt/src/Glyphs.cpp:302-305`): nothing is painted, but the advance is one full em, not zero. Do not throw, substitute a system glyph, or treat the miss as zero-advance; a zero-advance assumption shifts every later glyph in the run.

### 1.4 Glyph path and advance

- OTF advances are read at pixel size 1000 and divided by 1000, yielding em units. The JSON `advance` is already em units.
- OTF outlines are flipped once with `QTransform::fromScale(1, -1)` because font coordinates point up and painter coordinates point down. JSON paths are parsed in the same 1000-unit font space and receive the same flip when painted.
- A glyph path is painted with the text transform in section 2.3; do not pre-apply `size` to the outline.
- The SVG parser accepts the command subset used by the tables: `M/m`, `L/l`, `H/h`, `V/v`, `C/c`, `Q/q`, `Z/z`; numbers support decimals and exponents. Unsupported tokens terminate parsing. Fill rule is `Qt::WindingFill`. After an `M`/`m` the active command becomes the lineto form (`Qt/src/Glyphs.cpp:229`), so the coordinate pairs that follow a moveto are linetos, not extra movetos.
- A glyph lookup cache is keyed by `weight + ":" + character`; do not key by Unicode scalar alone.

## 2. Text operation and metrics

### 2.1 Command shape

The op is a flat array, never an object:

```json
["text", VALUE, X, Y, SIZE, WEIGHT, TRACKING, COLOR]
```

| Index | Meaning | Type | Default / rule |
|---:|---|---|---|
| 0 | literal `"text"` | string | exact |
| 1 | text value | string | may be empty; UTF-16 string |
| 2 | x | number | stage units; left of the first glyph advance origin |
| 3 | y | number | stage units; **baseline**, not top |
| 4 | size | number | stage units; 1000-unit font scaled by `size / 1000` |
| 5 | weight | string | one of `light`, `regular`, `demibold`, `bold`; an unknown value never matches the glyph table (keys embed the literal weight string) and reaches `regular` only through `fonts.value(weight, fonts["regular"])` |
| 6 | tracking | number | stage units added after every UTF-16 code unit |
| 7 | color | array | `[r,g,b]` or `[r,g,b,a]` or `[r,g,b,a,marker]`; missing/empty uses the default ink |

The index table belongs to T03; this card freezes the text-specific semantics. Emit `COLOR` as an array, not a packed integer and not a Material `Color`.

### 2.2 Coordinate system and baseline

HUD coordinates are stage units with a 1080-unit stage height. `Qt/src/Hud.cpp` scales the painter by `height() / 1080` before dispatching commands; a Flutter renderer MUST apply the same stage transform, and MUST NOT pre-multiply coordinates by device pixel ratio.

For `text`, `Y` is the glyph baseline. The paint transform is:

```text
translate(X, Y + SIZE * 1.044)
scale(SIZE / 1000, -SIZE / 1000)
fill glyph path(s)
```

`1.044` is `ascent 1044 / unitsPerEm 1000` from the OTF `hhea`/`typo` metrics and `misans-glyphs.json`. It is not the Flutter `TextPainter` baseline, not `fontSize * 1.2`, and not the Noto symbols ascent (`1.069`). The baseline offset applies to every weight and to the fallback layout path.

`art` is different: `Y` is the top, the transform is `translate(X, Y)` then `scale(SIZE / 1000, +SIZE / 1000)` (positive Y), and there is **no** `1.044` offset. Never use the text baseline rule for `art`.

The dispatcher sets `QPainter::Antialiasing | QPainter::SmoothPixmapTransform` once per frame before any command runs (`Qt/src/Glyphs.cpp:589-601`); a Flutter renderer MUST mirror those hints instead of relying on its own default antialiasing mode.

### 2.3 Normal path: per-code-unit advances

For text that does not trigger section 3:

1. Iterate the string as UTF-16 code units (Qt `for (auto ch : value)`, i.e. `QChar`), not grapheme clusters and not Unicode scalar values.
2. For each code unit, resolve the glyph in the requested weight: JSON `weight:char` first, then the weight OTF, then Noto symbols.
3. Paint the glyph with the baseline transform at the current `x`.
4. Advance `x += glyph.advance * size + tracking`.

Width is computed by the same iteration:

```text
width = max(0, Σ(glyph.advance_i * size + tracking) - tracking)
```

Equivalently, for `n > 0`: `Σ(advance_i * size) + tracking * (n - 1)`. For empty text the raw sum is `0` and the subtraction still runs, so the result is `max(0, -tracking)` — `0` whenever `tracking >= 0`. The trailing tracking is removed exactly once. Tracking may be negative; clamp only the final width at zero. The width cache key is `number(size,'g',17) 0x1f weight 0x1f number(tracking,'g',17) 0x1f text` (`Qt/src/Glyphs.cpp:291-292`). The two branches insert differently: the layout branch inserts unconditionally (`:296-299`), the per-code-unit branch only when `text.size() <= 4096` (`:307-309`). Cache occupancy is therefore observable from outside, but the returned width is identical either way.

The first glyph's left side bearing is `inset = glyph.path.boundingRect().x() * size / 1000`; if the path is empty, `0`. Only the **first UTF-16 code unit** is inspected — `Qt/src/Glyphs.cpp:347` calls `glyph(text.first(1), weight)`, so a surrogate pair contributes only its lead unit — and empty text returns `0` before any lookup (`:341-343`). In the layout path the whole shaped path is used instead (`:344-346`). `NativeHud::aligned` calls `text(value, x - inset, ...)`. Do not use font ascent/descent or a Flutter text width to compute inset.

`bounds` uses the same per-code-unit loop and baseline transform, but advances `x += advance * size` **without tracking**. It unions the transformed path bounding boxes and returns `{x, y, width, height}`; `NativeHud::centeredText` subtracts `bounds.x` and `bounds.y`, plus `bounds.width / 2` when the `horizontal` flag is set and `bounds.height / 2` for the vertical axis (`Qt/src/NativeHud.cpp:80-85`). Do not assume the bounds origin is `(X, Y)`.

### 2.4 Fit and ellipsis (`NativeHud::fit`)

`NativeHud::fit` is the HUD title/control fitter (`Qt/src/NativeHud.cpp:48-76`). Its cache is `QCache<QString, QString>` with 512 entries (`Qt/src/NativeHud.h:204`) keyed by `number(size,'g',17) + 0x1f + number(width,'g',17) + 0x1f + weight + 0x1f + value` (`Qt/src/NativeHud.cpp:51-52`), built by delimiter concatenation rather than JSON serialization (`:49-50`). Tracking is not part of the key and is always treated as `0`. The binary search is entered only when the unclipped width already exceeds the limit (`:57`), and the result is inserted unconditionally (`:74`).

Exact algorithm:

```text
length = value.size()
if width(value, size, weight) > limit:
    low = 1; high = length
    while low < high:
        middle = (low + high + 1) / 2
        if width(value.left(middle), size, weight) <= limit:
            low = middle
        else:
            high = middle - 1
    length = low
result = value
if length != value.size():
    result = value.left(max(0, length - 1)) + "…"
```

`width` here is the normal width function with tracking `0`. `left` is a UTF-16 prefix, not a grapheme prefix. The ellipsis is U+2026 (`…`), not three periods.

Two consequences MUST be preserved:

- The ellipsis is **not measured** after appending. The returned string can still exceed `limit`; callers must not assume it fits.
- If even the first code unit is too wide, `length == 1`, the prefix is empty, and the result is exactly `"…"`. If the input is empty and the limit is non-negative, the result is empty.

`NativeHud::limited` is `text(fit(...))`; it does not add its own ellipsis.

### 2.5 Distinct `Glyphs::label` fitter

`Glyphs::label` renders a 1024×440 cover image (`Qt/src/Glyphs.cpp:860-888`) and is **not** `NativeHud::fit`. Freeze it separately:

- Image `1024×440`, format `RGBA8888_Premultiplied`; fill `QColor::fromRgbF(0.902, 0.886, 0.851)`; ink `(0.09, 0.09, 0.075)`; header bar `fillRect(12, 12, 1000, 6)`.
- For each of the three lines, start `size = maximum`; while `width(s, size, weight) > 954 && size > 34`, `size -= 2`.
- Then while `width(shown, size, weight) > 954 && shown.size() > 1`, `shown.chop(1)`.
- If `shown != s`, chop one more code unit and append `"…"`. The ellipsis is reached only through that comparison: the chop loop requires `shown.size() > 1`, so a one-code-unit input that still overflows at `size 34` is drawn **unchanged** (`shown == s`), while anything chopped down to one code unit becomes exactly `"…"`.
- Draw at `x = 30`, `y = 40 / 210 / 340`, sizes `125 / 78 / 40`, weights `bold / demibold / regular`, tracking `0`.
- Defaults: title `"音乐资料库"`, empty artist `"暂无歌手"`, kind `MUSIC`, id `"—"`; kind is uppercased and followed by `" ID "`.

Do not reuse this size-stepping fitter for HUD text, and do not reuse `NativeHud::fit` for cover labels.

### 2.6 Art advance (`Glyphs::artWidth`)

`Glyphs::artWidth(key, size, tracking, count)` (`Qt/src/Glyphs.cpp:403-412`) measures boot lettering from the `boot-lettering-art.json` letter lists — it is not the text `width` function:

- `letters = lettering.value(key)`;
- `visible = letters.mid(0, count < 0 ? letters.size() : count)`, i.e. a negative `count` means every letter and any non-negative `count` truncates the list to that many letters;
- `result += advance * size + tracking` over the visible letters;
- the return value is `0` when nothing is visible, otherwise `result - tracking`.

Consequences: the trailing `tracking` is subtracted exactly once; unlike `width` there is **no** `max(0, .)` clamp, so with at least one visible letter a large negative tracking yields a negative width; an empty letter list returns exactly `0`. Do not synthesize a letter count from the string length of the art key.

## 3. Layout fallback

### 3.1 Trigger predicate

`Glyphs::needsLayout(text, weight)` returns true if **any** code point satisfies one of these conditions (`Qt/src/Glyphs.cpp:108-139`):

| # | Trigger | Exact condition |
|---:|---|---|
| 1 | non-BMP | `point > 0xFFFF` |
| 2 | combining mark | `QChar::category(point)` is `Mark_NonSpacing`, `Mark_SpacingCombining`, or `Mark_Enclosing` |
| 3 | Hangul Jamo | `script == Script_Hangul` and `point < 0xAC00 || point > 0xD7A3` |
| 4 | contextual/complex script | `script` is not one of `Common`, `Inherited`, `Latin`, `Han`, `Hiragana`, `Katakana`, `Hangul` |
| 5 | zero-width joiner | `point == 0x200D` |
| 6 | bidi RTL | `direction == DirR` or `direction == DirAL` |
| 7 | missing from both direct fonts | `!weightFont.supportsCharacter(point) && !symbolsFont.supportsCharacter(point)` |

The predicate iterates `text.toUcs4()` (Unicode scalar values), unlike the normal advance loop which iterates UTF-16 code units. A single trigger switches the whole string to the layout path. Do not trigger per character, do not split the string into runs yourself, and do not trigger merely because a character is absent from the weight OTF if Noto symbols supports it.

Cache key: `weight + ":" + text`, cached only when `text.size() <= 4096`. The cache stores the boolean, not a shaped layout.

### 3.2 Layout path

`Glyphs::layoutText(text, weight, spacing)` (`Qt/src/Glyphs.cpp:142-188`):

1. Cache key: `weight + ":" + number(spacing, 'g', 17) + ":" + text`; only cache when `text.size() <= 4096`.
2. Start from `QFontDatabase::systemFont(QFontDatabase::GeneralFont)`.
3. `const auto family = layoutFamilies.value(weight, layoutFamilies["regular"])` (`:150`). If `family` is non-empty, `font.setFamily(family)` and then `font.setStyleName(weightRawFont.styleName())` (`:151-154`); if it is empty the family stays Qt `GeneralFont`. **Regardless of that branch**, `font.setWeight(static_cast<QFont::Weight>(weightRawFont.weight()))` runs unconditionally (`:155`).
4. `font.setPixelSize(1000)`; `font.setHintingPreference(QFont::PreferNoHinting)`; `font.setLetterSpacing(QFont::AbsoluteSpacing, spacing)`.
5. `QTextLayout(text.normalized(NFC), font)`; alignment `Qt::AlignLeft`; create one line and set its width to `1000000`.
6. Shaped advance: `line.isValid() ? max(0, line.horizontalAdvance() - spacing) / 1000 : 0`. `spacing` is in 1000-unit em units; callers pass `size > 0 ? tracking * 1000 / size : 0`. Width in stage units is this advance times `size`.
7. Outline: for every glyph run and every glyph, take `run.rawFont().pathForGlyph(index)`, translate by `(positions[i].x(), positions[i].y() - line.ascent())`, add to a `WindingFill` path, then map the whole path with `QTransform::fromScale(1, -1)`.
8. Paint with the same baseline transform as section 2.2: `translate(x, y + size*1.044)`, `scale(size/1000, -size/1000)`, then fill the shaped path. The shaped path already contains positions; do not add per-glyph advances again.

`bounds`/inset fallback use `layoutText(value, weight, 0)` and map the path with `translate(0, size*1.044)`, `scale(size/1000, -size/1000)`; they do not add tracking. Inset is `path.boundingRect().x() * size / 1000`.

### 3.3 Fallback font order

There are two pipelines; do not conflate them:

- **Normal (no trigger):** per code unit, JSON glyph → weight OTF glyph → Noto symbols glyph → the default `Glyph` (`advance: 1` em, empty path). A glyph miss is never a zero-advance miss; see section 1.3. This is the only place Noto symbols is consulted explicitly.
- **Layout (any trigger):** application family for the requested weight (registered `Rhine MiSans` + style) if available, otherwise Qt `GeneralFont`; then Qt's `QTextLayout`/platform font fallback for missing scripts. Noto symbols is **not** injected into this pipeline, because Qt picks fallback fonts itself. A Flutter implementation MUST use the same application font face and let the platform shaper fall back; it MUST NOT force every fallback to the first installed font or to Noto symbols.

If the application family registration failed, the layout path uses `GeneralFont`; that is a degraded environment, not a license to change metrics.

## 4. Colors

### 4.1 Array and default

Accepted shapes:

- `[r, g, b]`: alpha defaults to `1.0`.
- `[r, g, b, a]`: alpha used directly.
- `[r, g, b, a, marker]`: marker must be a string; conversion applies only if `marker.startsWith("calibrated")`.

Components SHOULD be finite and in `[0, 1]`; the Qt code does not clamp, so out-of-range input is a contract violation. Alpha is never gamma-converted. A missing or empty color array in `NativeHud::text`/`fill`/`art` resolves to `ink()` before serialization; the command always carries a concrete array.

### 4.2 Calibrated conversion (`Glyphs::color`, `Qt/src/Glyphs.cpp:35-49`)

For each of the three RGB components `v`:

```text
linear = pow(v, 1.8)
if linear <= 0.0031308:
    encoded = 12.92 * linear
else:
    encoded = 1.055 * pow(linear, 1/2.4) - 0.055
```

Then construct `QColor::fromRgbF(encodedR, encodedG, encodedB, alpha)`. The marker string itself has no numeric meaning beyond the `"calibrated"` prefix; do not parse a gamma number from it. The conversion is per channel and is **not** applied when the fifth item is absent or does not start with `calibrated`. Do not convert alpha, and do not round to 8-bit before painting.

Why this exists: the palette/ink authoring path uses a gamma-1.8 encoding for calibrated colors; the renderer decodes it to linear and re-encodes to the sRGB transfer function. A plain `Color.fromARGB` or a Material `ColorScheme` treats the numbers as display-space sRGB and will be visibly wrong.

### 4.3 Frozen color groups

These are the three fixture groups; expected values are double-precision results of the formula above.

| id | Input array | Expected RGBA |
|---|---|---|
| `calibrated-white` | `[0.92, 0.92, 0.92, 1, "calibratedWhite"]` | `[0.9360448981490523, 0.9360448981490523, 0.9360448981490523, 1.0]` |
| `calibrated-rgb` | `[0.08, 0.085, 0.075, 1, "calibratedRGB"]` | `[0.1036974505282458, 0.11107973909911709, 0.09619882186634102, 1.0]` |
| `plain-amber` | `[0.835, 0.639, 0.282, 1]` | unchanged `[0.835, 0.639, 0.282, 1.0]` |

Default HUD ink (`NativeHud::ink`):

- dark: `[0.92, 0.92, 0.92, 1, "calibratedWhite"]`
- light: `[0.08, 0.085, 0.075, 1, "calibratedRGB"]`

After conversion these become the first two rows above. The dark ink is not pure white; do not paint it as `#FFFFFF`.

### 4.4 Canonical palette and surface variants

The canonical palette is `CollectionDetailCard` (`Qt/src/CollectionDetailCard.cpp:10-50`). A surface without its own palette uses these values. Arrays have four elements and no calibrated marker, so they are used as authored (no gamma conversion).

| Token | Light | Dark |
|---|---|---|
| `paper` | `[0.945, 0.941, 0.906, 1]` | `[0.08, 0.095, 0.09, 1]` |
| `panel` | `[0.973, 0.969, 0.933, 1]` | `[0.095, 0.11, 0.10, 1]` |
| `ink` | `[0.133, 0.165, 0.145, 1]` | `[0.93, 0.94, 0.88, 1]` |
| `muted` | `[0.384, 0.42, 0.376, 1]` | `[0.65, 0.69, 0.62, 1]` |
| `line` | `[0.80, 0.808, 0.753, 1]` | `[0.30, 0.34, 0.29, 1]` |
| `soft` | `[0.898, 0.906, 0.855, 1]` | `[0.16, 0.20, 0.16, 1]` |
| `inverse` | `[0.973, 0.969, 0.933, 1]` | `[0.12, 0.15, 0.13, 1]` |
| `amber` | `[0.835, 0.639, 0.282, 1]` | same as light |

Surface overrides (keep them; do not collapse to canonical):

| Surface | Light | Dark |
|---|---|---|
| `DiscoverMusicCard` | paper `[0.973, 0.969, 0.933, 1]`, ink `[0.133, 0.165, 0.145, 1]`, muted `[0.39, 0.43, 0.38, 1]`, soft `[0.89, 0.90, 0.85, 1]`, amber `[0.835, 0.639, 0.282, 1]`, night `[0.133, 0.165, 0.145, 1]`, white `[0.95, 0.95, 0.9, 1]` | paper `[0.09, 0.115, 0.095, 1]`, ink `[0.93, 0.94, 0.88, 1]`, muted `[0.65, 0.69, 0.62, 1]`, soft `[0.16, 0.20, 0.16, 1]` |
| `PlayerBar` | paper `[0.933, 0.937, 0.894, 1]`, ink `[0.141, 0.161, 0.145, 1]`, muted `[0.4, 0.439, 0.392, 1]`, line `[0.8, 0.816, 0.761, 1]`, amber `[0.863, 0.651, 0.227, 1]` | paper `[0.133, 0.161, 0.137, 1]`, ink `[0.929, 0.941, 0.875, 1]`, muted `[0.647, 0.678, 0.616, 1]`, line `[0.298, 0.329, 0.282, 1]` |
| `PlaybackQueueCard` | ink `[0.145, 0.176, 0.153, 1]`, muted `[0.41, 0.44, 0.39, 1]`, line `[0.79, 0.80, 0.74, 1]`, selected `[0.90, 0.90, 0.83, 1]`, amber `[0.83, 0.64, 0.27, 1]` | ink `[0.93, 0.94, 0.88, 1]`, muted `[0.68, 0.71, 0.64, 1]`, line `[0.31, 0.35, 0.29, 1]`, selected `[0.24, 0.28, 0.22, 1]`, amber same |
| Modal panel | `[0.929, 0.922, 0.894, 1]` | `[0.15, 0.15, 0.15, 1, "calibratedWhite"]` |

Do not introduce Material `ColorScheme`, opacity-derived tints, or 8-bit rounded equivalents. Do not derive `muted` by applying alpha to `ink`; the values are independent.

## 5. Archive mask, footer, brand, boot constants

### 5.1 Archive right mask

`NativeHud::archiveMask` (`Qt/src/NativeHud.cpp:313-327`) is emitted only when `archiveMaskStrength != 0`:

- `opacity = archiveMaskStrength / 100.0` (percentage; no clamp in this function).
- `FadeWidth = 300`.
- dark color `[0.055, 0.075, 0.08, opacity]`; light color `[0.9, 0.89, 0.86, opacity]`.
- `fadeEnd = navigationLeft(width) = width - 789`; `fadeStart = fadeEnd - 300 = width - 1089`.
- `clip(0, 0, width, 984)`; op `["right-mask", color, fadeStart, 300, width, 984]`; `restore()`.
- The slot itself is frozen by T03: 16 equal segments, 17 gradient stops from `progress = 0/16` through `16/16`, `eased = progress^2 * (3 - 2*progress)`, stop alpha `baseAlpha * eased`, gradient from `(start, 0)` to `(start + span, 0)`, fill `(start, 0, right - start, height)`.
- The Android cached-mask path (`RHINE_HUD_MASK_CACHE`) is **off by default** and is a performance approximation: it samples a W×1 image at pixel centers `(i + 0.5) / span`, premultiplies, and stretches it. Do not use it as the reference output and do not enable it for parity evidence.

### 5.2 Background gradient

From `Glyphs` gradient dispatch (T03 owns the op index): radial gradient center `(979.2, 518.4)`, radius `1100`, stops `0 / 0.76 / 1`, fill rect `(-4096, -4096, 8192, 8192)`.

- dark: `QColor(32, 42, 47)`, `QColor(23, 33, 37)`, `QColor(17, 24, 27)`
- light: `QColor(231, 231, 225)`, `QColor(227, 225, 220)`, `QColor(228, 223, 219)`

These are 8-bit `QColor` constructors, i.e. display-space sRGB; do not run the calibrated conversion on them.

### 5.3 Footer

`NativeHud::footer(width)` (`Qt/src/NativeHud.cpp:357-373`):

- Square: `fill(59, 971, 5, 5, [119/255, 123/255, 96/255, 1])`.
- Session text, x `75`, baseline y `967`, size `10`, weight `regular`, tracking `0.9`, default ink. Session string:
  - `LOCAL LIBRARY` when local;
  - `SIREN RECORDS` when Siren;
  - otherwise `GUEST SESSION` when no uid;
  - with uid: `NETEASE SESSION`; override `QQ SESSION` for provider `qq`, `KUGOU SESSION` for provider `kugou`.
- Credit: `"POWERED BY RHINE LAB"`, size `10`, weight `demibold`, baseline y `967`, x `width - 59 - width(credit, 10, "demibold")`; default ink. No tracking.
- Footer sits above the player bar; `playerBar(0, 984, width)` is drawn after modals unless mode is `boot`.

### 5.4 Brand

- `brand()`: `roll("music-brand", libraryName, 59, 115.425, 44, min(720, width*0.45), "bold")`, which is `shown = fit(libraryName, 44, min(720, width*0.45), "bold")` followed by `rollingText("music-brand", shown, 59 - inset(shown, 44, "bold"), 115.425, 44, "bold", 0)` — the sixth argument of `roll` is the fit width, not a rolling parameter, and the rolling tracking is `0` (`Qt/src/NativeHud.cpp:97-101`, `:86-96`); then `aligned("RHINE LAB / MUSIC DATABASE", 59, 173, 14, "demibold", 1)`.
- `brandLine(0)`: `text("RHINE LAB", 59, 115.425, 50.75, "bold", 1)`.
- `brandLine(1)`: `text("MUSIC DATABASE", 59, 169, 22, "demibold", 1.7)`.
- `brandLine(other)`: `rule(59, 212, 300, 0.65)`; `text("INDEX / COLLECTION / TRACK", 59, 228, 11, "regular", 1.2)`.

### 5.5 Boot constants

`NativeHud::boot` starts with `offset = (width - 1920) / 2`, `translate(offset, 0)`. All animation magnitudes (opacity, scale, visible flags, ring radii/sweeps, letter counts) come from `frame["boot"]` and are not frozen by T04; the following constants are.

- Background: `gradient(dark)`; then `fill(-offset, 0, width, 1080, [flash, flash, flash, frame.boot.white])` where `flash = dark ? 0 : 1` (the fourth element is the frame alpha `number("white")`, i.e. `frame.boot.white`; it is not the `white` local defined later for the welcome art, see the welcome art bullet below).
- Scan/palette: scan orbit paper `[17/255, 24/255, 27/255, 1]` dark, `[1, 1, 1, 1]` light; the two orange dots are `[237/255, 130/255, 27/255, 1]`; ring/arc pen widths are `2.4` (music), `4` (white), `2` (inner/sides), dot radius from frame.
- Welcome panel: `ink()` with `panel[3] = frame.boot.welcomePanel`; `fill(725, 344, 470, 392, panel)`; transform around `(960, 552.6)`.
- Welcome art: `art("welcome", 960 - artWidth("welcome", 55)/2, 403, 55, -1, 0, [white, white, white, 1, "calibratedWhite"])`; `white = dark ? frame.boot.welcomeInk : 1 - frame.boot.welcomeInk`.
- Company: `alpha(companyMask ? 0.65 : 1)`; `artWidth("company", 48, -0.5)`; `art("company", 960 - companyWidth/2, 475, 48, -1, -0.5)`; highlight `clip(755, 470, 410 * frame.boot.highlight, 60)`, fill `(755, 470, 410, 60)`, color dark `[17/255, 24/255, 27/255, 1]` / light `[238/255, 237/255, 232/255, 1]`, alpha `companyMask ? 0.06 : 1`.
- Database: `art("database", 960 - artWidth("database", 36)/2, 537, 36)`, alpha from frame.
- Logo: `logo(858.5, 590, 203)`, scale `203/310`; contour path stroke `26`; plus segment `"M44 70H94M69 45V95M219 70H263"` stroke `15`; all with `ink()`.
- Logo letters: `text(frame.boot.logoLetters, 20, 174 - 16*1.044, 16, "bold", 22)` — this draw happens **inside** the logo block (`Qt/src/NativeHudBoot.cpp:180-207`), i.e. under `translate(518 + logo.offsetX, 463)` and `scale(296/310)`, not in stage coordinates.
- Auth: `text("▪", 907, 528, 14)`; art key selected from frame auth string (`processing` default; `identity` if starts with `ID`; `request` if starts with `REQUEST`; `processingGlitch` if starts with space); art size `21.35`, tracking `-0.00909 * size`, position `(931, 527)`.
- Powered: `clip(width - 354, 945, 295 * poweredLetters / 19, 35)`; `text("POWERED BY", width - 354, 947, 19)`; `text("RHINE LAB", width - 218, 947, 19, "bold")`; `fill(width - 84, 955, 25, 6)`.
- Skip button: `button("ENTER SYSTEM ↗", width - 261, 994, 202, 40, "skip", 14)`.

Boot lettering art contours come from `Resources/boot-lettering-art.json`; do not replace them with text or with OTF glyphs.

### 5.6 Platform paths that must not change the reference output

Three environment-gated paths change *how* identical geometry is rasterized or dispatched. None of them changes a frozen number above; T03 owns their dispatch consequences.

- `RHINE_HUD_RUN_CACHE` (`Qt/src/Glyphs.cpp:413-428`, default **OFF** — enabled only when the variable is non-empty and not `"0"`): when on, `text` and `art` merge the whole run into one `QPainterPath` and fill it once (`:542-553`, `:567-578`) instead of filling per glyph (`:555-563`, `:580-587`). Glyph paths and pen positions are identical; coverage differs because the rasterizer works from the union bounding box, which is why the reference output is the per-glyph path.
- `RHINE_HUD_MASK_CACHE` (`Qt/src/Glyphs.cpp:481-528`): the right-mask counterpart, also default **OFF** (see §5.1).
- `RHINE_HUD_CULL` (`Qt/src/Glyphs.cpp:601-636`, stats at `:833-837`, default **ON** — enabled unless the value is exactly `"0"`): Android-only, and active only while the painter clips, i.e. `cull = cullEnabled && c.hasClipping()`; an empty clip box disables it (`:613-618`). It skips a `text`/`art` command only when the command's conservative box misses the clip rect entirely (`!clipBox.intersects(box)`, `:622-627`). That box is `(x - size*0.2, y - size*1.15, length*(size*1.1 + max(0, tracking)) + size*0.4, size*1.6)` (`:632-635`), where `length` is the string length for `text` (`:705`) and the `count` argument `a[5]` for `art` (`:718`, `:721`): an `art` command is only eligible for culling when `a[5] >= 0` (a negative count means the whole run), and `a[5]` is used as-is, so the box can exceed the number of letters actually present in the lettering list. Culling can only drop commands that would paint nothing; it MUST NOT be used to justify a different visible result.
- Apple raster cache (`Qt/src/Glyphs.cpp:893-1107`, `QCache` 32 MiB at `Qt/src/Glyphs.h:79`): on Darwin the host may pass `cacheText` and reuse a per-command pixel tile. It applies only when the device image is ARGB32/RGBA8888, the transform is affine, text length is ≤ 4096, device bytes ≤ 32 MiB, opacity is 1 and composition is `SourceOver` (`:989-999`); it re-checks that the background under the tile is byte-identical before blitting (`:1047-1064`). It is pixel memoization only and is not a Flutter obligation.
- `RHINE_HUD_PROBE` (`Qt/src/Glyphs.cpp:596-598`): accumulates per-op timings only; it never changes drawing.

## 6. Why ordinary Flutter Text is not usable for the HUD

A `Text`, `RichText`, `TextPainter`, `DefaultTextStyle`, or `Material` text theme MUST NOT be used for stage HUD content. The reasons are contract-level, not stylistic:

1. **Baseline.** Qt places `y` at the baseline and adds `size * 1.044`; Flutter text APIs place a box using font ascent/descent and their own baseline. The 1.044 ascent comes from the shipped OTF, not from the platform font.
2. **Advances.** Qt sums per-UTF-16-code-unit advances from `misans-glyphs.json`/the OTF and adds tracking after every unit, then removes one trailing tracking. Flutter shaping applies kerning, ligatures, hinting, and its own tracking model, producing different x positions and widths even with the same file.
3. **Path fallback.** JSON glyph paths take precedence over the OTF; missing glyphs try Noto symbols; complex text switches to `QTextLayout` and platform fallback. A normal `TextStyle` cannot express this lookup order or the JSON path precedence.
4. **Calibrated color.** A fifth "calibrated*" item selects the gamma-1.8 → sRGB conversion. Flutter `Color`/Material colors have no such marker and would paint the raw values, changing every calibrated ink/panel/overlay.
5. **Command contract.** The HUD is a flat array of 17 ops with fixed indices, no reordering/deduplication, and same-generation commands/hits/frame. Widget text introduces its own layout tree, semantics, and paint order; it cannot be a drop-in for the `text` op.
6. **Fit and ellipsis.** `NativeHud::fit` uses a binary search over UTF-16 prefixes and appends an unmeasured U+2026. Flutter overflow/ellipsis algorithms differ and are not allowed to replace it.
7. **Layout fallback.** The trigger predicate and the application-family-first shaping order are part of the visual contract; a generic `Text` uses the platform's default fallback chain.

T31 MUST provide a custom painter/text engine that consumes the flat `text` op and this contract. Ordinary Flutter text may be used only outside the HUD stage and only after T31 confirms it does not share these metrics.

## 7. Fixture and test

Neither artifact exists at baseline. Both are deliverables of this module, written in the second step of this card under the contract below; this document is normative if they ever disagree. The shapes below are binding.

`test/fixtures/glyph_metrics.json` MUST be the machine-readable projection of this contract. It contains:

- `fontProgram`: units, ascent/descent, baseline factor, four OTF metadata entries (file, bytes, SHA-256, `unitsPerEm`, ascender/descender, `usWin` pair, `usWeightClass`), symbols metadata, glyph-table metadata (1007 glyphs, font version).
- `advanceGroups`: exactly three groups:
  - `width-regular-24`: `"RHINE MUSIC / 2026"`, regular, size 24, tracking 0, expected width `232.848` (regular advances sum to `9.702` em, `9.702 * 24 = 232.848`).
  - `width-bold-44`: `"全部歌曲"`, bold, size 44, tracking 0, expected width `176.0` (`4 * 1.0` em, `4 * 44 = 176.0`).
  - `width-regular-32-tracking`: `"MUSIC"`, regular, size 32, tracking 1.5, expected width `106.256` (advances sum to `3.133` em, `3.133 * 32 + 1.5 * 4 = 106.256`).
- `fitGroup`: `"METAL BASELINE SCROLL"`, regular, size 37, limit `290`; original width `459.688`; search length `13`; prefix width `284.123`; fitted `"METAL BASELI…"`; fitted width `293.965`; ellipsis advance `1.0`. `284.123` is the width of `value.left(13)`, the prefix the search settles on (`284.123 <= 290`, while `value.left(14)` is `306.212 > 290`, so the search stops at `13`), whereas the emitted string is `value.left(length - 1)` plus `"…"`, i.e. `256.965 + 37 = 293.965` for these inputs. The emitted string is never re-measured, so it exceeds the limit `290` even though the prefix the search settled on does not — which is exactly why the ellipsis must not be measured.
- `baselineGroups`: the baseline offsets the frozen groups rely on — `16 * 1.044 = 16.704`, `44 * 1.044 = 45.936`, `37 * 1.044 = 38.628`, and the boot-logo case `174 - 16 * 1.044 = 157.296`.
- `colorGroups`: exactly the three rows in section 4.3, plus an `alphaProbe` proving alpha is copied unchanged.
- `source`: baseline, Qt references, font version.
- `ordinaryTextUnusable`: the machine-readable pointer to section 6 — the seven reasons ordinary Flutter `Text` cannot be used for HUD stage text.

`test/text_metrics_test.dart` MUST be a reference test over the fixture: it loads `test/fixtures/glyph_metrics.json`, sums the supplied per-character advances with the Qt formula, checks the baseline `size * 1.044`, reimplements the exact `NativeHud::fit` binary search, and applies the calibrated formula. Its target command is `flutter test test/text_metrics_test.dart`, so it uses the `flutter_test` dependency already declared in `pubspec.yaml` — no new package and no `pubspec.yaml` change — and it must bind no widgets. It MUST NOT import production code, use a Flutter renderer, or assert a system-font approximation.

Acceptance mapping:

- `flutter test test/text_metrics_test.dart` must report every width, baseline, fit and color group equal within `1e-9`. The numbers frozen in section 4.3 and in this section are this contract's own double-precision results, of which the fixture carries copies; the first two width groups reproduce the Qt formula bit-for-bit (`232.848` and `176` are exact doubles), while the tracking group lands on `106.25599999999998602`, because the §7 `width` helper accumulates `advance * size + tracking` per code unit and subtracts `tracking` once at the end — `1.42e-14` below the `106.256` literal (the written expression `3.133 * 32 + 1.5 * 4` is the same double as that literal), which is why the comparison carries a tolerance.
- Failure is any use of a system font, Flutter `TextPainter` width, or uncalibrated ARGB to satisfy a group.
- **NOT EXECUTED**: no `flutter test`, `dart test`, build, analyze, run, Gradle, adb, APK or device command was run for this card, because the task prohibits them. Every test status in this contract is unverified — RED/GREEN is unknown and this is **not** a pass claim. Device-side antialiasing, hinting, color management and physical-pixel evidence remain **DEVICE_BLOCKED**; production wiring remains **ARCH_BLOCKED**.

## 8. Checklist mapping and open items

| Plan checkbox | Covered by |
|---|---|
| T04-1 four OTF + NotoSansSymbols2 + misans-glyphs loading, advance/path, 1.044, tracking, fit ellipsis | §1, §2 (including §2.4/§2.5) |
| T04-2 QTextLayout fallback triggers and font order | §3 |
| T04-3 light/dark palettes, calibrated Gamma 1.8, mask/footer/boot constants | §4, §5 |
| T04-4 fixture three color + three width groups; why ordinary Text is unusable | §4.3, §6, §7 |

Dependencies: T01 supplies shared scaffolding; this contract is source-verified independently. If T01 changes the resource root or asset-pack layout, re-check §1.2 and §1.3 without changing Qt-derived numbers. T03 remains authoritative for op indices and generic paint semantics; this card supplies the text/color payload and calibrated conversion.

Open items: T01 freeze may add a shared asset manifest; T31 must implement the custom text painter and may add a production fixture consumer, but must not edit this contract or the two planned fixture/test files without a new contract decision. No device or execution evidence is claimed, and the fixture and test are unexecuted.
