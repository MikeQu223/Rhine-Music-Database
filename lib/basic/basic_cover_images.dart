/// 封面像素：把 Siren 的专辑封面 URL 变成可绘制的 `ui.Image`。
///
/// 为什么需要这一层：HUD 命令流里的 image 只带**键**（`['image', key, x, y, w, h]`），
/// 真正的像素由宿主提供（`HudImageLookupFn`，lib/hud/render/paint_stack.dart:83）。
/// Qt 端有自己的封面纹理；Flutter 端此前 `BasicGlyphPorts.imageFor` 恒返回 null，
/// 所以详情页/歌词页/播放条的封面槽一直是空的（用户 2026-11-18：「接一下接口，
/// 从专辑封面那里拿」）。
///
/// 复用 [BasicArtCache] 做下载/落盘/去重/上限（它已经处理了超时、字节上限与
/// 同 URL 并发合并），本层只多做三件事：读文件、解码成 `ui.Image`、按 URL 记内存
/// LRU 并在解码完成时回调宿主重绘。失败一律留空，不编假图、不抛异常。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'basic_art_cache.dart';

/// 内存里同时保留的封面上限（一张 512px 方图约 1 MiB，24 张留出安全余量）。
const int kBasicCoverImageMaxEntries = 24;

/// 解码目标边长：竖屏封面最大约 300 逻辑像素、乘以像素比 3 也只有 900，
/// 512 足够清晰又不会让每张图占掉几 MiB。
const int kBasicCoverImageDecodeSize = 512;

/// 封面 URL → `ui.Image` 的异步缓存。
class BasicCoverImages {
  BasicCoverImages({
    required BasicArtCache cache,
    this.maxEntries = kBasicCoverImageMaxEntries,
    this.decodeSize = kBasicCoverImageDecodeSize,
    this.onChanged,
  }) {
    _cache = cache;
  }

  /// 落盘缓存（下载/去重/上限都在它里面，本层只读文件并解码）。
  late final BasicArtCache _cache;

  /// 内存里最多留几张解码后的图。
  final int maxEntries;

  /// 解码目标宽度（高度按原图比例）。
  final int decodeSize;

  /// 一张新封面解码完成时回调（宿主用它 setState 触发重绘）。
  final void Function()? onChanged;

  final Map<String, ui.Image> _images = <String, ui.Image>{};
  final List<String> _order = <String>[];
  final Set<String> _loading = <String>{};
  final Set<String> _failed = <String>{};
  bool _disposed = false;

  /// 缓存命中数/总量，只用于诊断与测试断言。
  int get length => _images.length;

  /// 命令流查询入口：命中直接返回，未命中就**开始**加载并先返回 null
  /// （这一帧画空槽，加载完成后宿主重绘再补上）。
  ui.Image? imageFor(String key) {
    final String url = key.trim();
    if (_disposed || url.isEmpty) {
      return null;
    }
    final ui.Image? cached = _images[url];
    if (cached != null) {
      _touch(url);
      return cached;
    }
    if (_failed.contains(url) || _loading.contains(url)) {
      return null;
    }
    _loading.add(url);
    unawaited(_load(url));
    return null;
  }

  /// 提前预热一批 URL（例如当前曲目与详情页的封面），不等待结果。
  void prime(Iterable<String> urls) {
    for (final String url in urls) {
      imageFor(url);
    }
  }

  Future<void> _load(String url) async {
    ui.Image? image;
    try {
      final String? path = await _cache.localPath(url);
      if (path != null) {
        image = await _decode(path);
      }
    } on Object {
      // 没有目录 / 没有网络 / 404 / 不是图片：一律当成「这张没有封面」。
      image = null;
    }
    _loading.remove(url);
    if (_disposed) {
      image?.dispose();
      return;
    }
    if (image == null) {
      _failed.add(url);
      return;
    }
    _images[url] = image;
    _touch(url);
    _evict();
    onChanged?.call();
  }

  Future<ui.Image?> _decode(String path) async {
    final Uint8List bytes = await File(path).readAsBytes();
    if (bytes.isEmpty) {
      return null;
    }
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(buffer);
      final ui.Codec codec = await descriptor.instantiateCodec(
        targetWidth: descriptor.width > decodeSize ? decodeSize : descriptor.width,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } finally {
      buffer.dispose();
    }
  }

  void _touch(String url) {
    _order.remove(url);
    _order.add(url);
  }

  void _evict() {
    while (_order.length > maxEntries) {
      final String oldest = _order.removeAt(0);
      final ui.Image? image = _images.remove(oldest);
      image?.dispose();
    }
  }

  /// 宿主销毁时释放所有解码后的像素。
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final ui.Image image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _order.clear();
    _loading.clear();
    _failed.clear();
  }
}
