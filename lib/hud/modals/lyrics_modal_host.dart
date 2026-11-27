/// LyricsModalHost: the runtime receiver that connects the HUD lyric panel's
/// action strings to the two  popovers and turns user gestures into domain
/// suggestions.
///
/// Qt evidence:
///  * dispatch table `NativeHudController.cpp:324-345` (lyrics-offset toggles the
///    popover, lyrics-earlier/later call adjustOffset(+/-200), reset and
///    apply-global call the two single-shot methods, lyrics-sources is gated by
///    `music.isLocal() && provider == "local"`, lyrics-source:<id> selects the
///    local source, resets browse and closes the popover).
///  * offset arithmetic `LyricsController.cpp:511-518` (std::clamp +/-10000),
///    reset `LyricsController.cpp:521-531`, apply-global
///    `LyricsController.cpp:534-544`, constructor clamp `LyricsController.cpp:60-64`.
///  * popover bounds `NativeHud.cpp:145-152` (stage width * 0.56).
///
/// The host never mutates [LyricsPanelModel], never writes preferences and never
/// starts I/O: every offset result is a suggestion for the composition root
/// (LyricsController owns the clamp + persistence). `sameTrack` semantics
/// stay with the caller: the host only reads the offset values it is given.
///
/// No Flutter widget/material imports: this file is pure Dart, like the two
/// popover libraries it drives.
library;

import 'lyrics_offset_modal.dart';
import 'lyrics_panel.dart';
import 'lyrics_source_modal.dart';

/// Measures text for both popovers. [LyricsOffsetMeasureText] and
/// [LyricsSourceMeasureText] have this exact signature, so one injection point
/// serves both frames.
typedef LyricsModalMeasureText = double Function(
    String text, double size, String? weight, double tracking);

/// Result of one host action: an offset suggestion or a source selection.
sealed class LyricsModalResult {
  const LyricsModalResult();
}

/// Suggested change to the lyric offset. The caller applies it through
/// LyricsController::adjustOffset/resetOffset/applyGlobalOffset; the host does
/// not touch `model.offsetMs`.
final class LyricOffsetChange extends LyricsModalResult {
  const LyricOffsetChange({
    required this.action,
    required this.deltaMs,
    required this.newOffset,
    required this.global,
  });

  /// The action that produced this suggestion (one of
  /// [LyricsOffsetModal.actionEarlier], [...actionLater], [...actionReset],
  /// [...actionApplyGlobal]).
  final String action;

  /// Signed delta the caller should pass to adjustOffset, in milliseconds.
  /// Zero for apply-global, which writes the global value instead.
  final double deltaMs;

  /// Offset after the change, in milliseconds, already clamped to +/-10000
  /// (LyricsController.cpp:511-518).
  final double newOffset;

  /// True when the suggestion targets the global offset
  /// (LyricsController::applyGlobalOffset, LyricsController.cpp:534-544);
  /// false for the three per-track actions.
  final bool global;

  @override
  bool operator ==(Object other) =>
      other is LyricOffsetChange &&
      other.action == action &&
      other.deltaMs == deltaMs &&
      other.newOffset == newOffset &&
      other.global == global;

  @override
  int get hashCode => Object.hash(action, deltaMs, newOffset, global);

  @override
  String toString() => 'LyricOffsetChange(action: $action, deltaMs: $deltaMs, '
      'newOffset: $newOffset, global: $global)';
}

/// Suggested local-source selection. Qt hands the raw third segment of
/// `player:lyrics-source:<id>` to LyricsController::selectLocalSource and then
/// closes the popover (NativeHudController.cpp:342-345); validation stays in
/// the domain (LyricsController.cpp:232-238), so an unknown id is reported as
/// emitted, never silently dropped here.
final class LyricsSourceSelection extends LyricsModalResult {
  const LyricsSourceSelection(this.source);

  /// Raw source id (`parts.value(2)`), `''` when the action had no id.
  final String source;

  @override
  bool operator ==(Object other) =>
      other is LyricsSourceSelection && other.source == source;

  @override
  int get hashCode => source.hashCode;

  @override
  String toString() => 'LyricsSourceSelection($source)';
}

/// One composed frame: which popover is open plus its Qt op stream and hits.
class LyricsModalFrame {
  const LyricsModalFrame({
    this.openAction,
    required this.commands,
    required this.hits,
  });

  /// Open popover kind (`lyrics-offset` / `lyrics-source`), null when closed.
  final String? openAction;

  /// Qt draw commands of the open popover, empty when closed.
  final List<List<Object?>> commands;

  /// Qt hit rows of the open popover, empty when closed.
  final List<List<Object?>> hits;

  bool get isOpen => openAction != null;

  /// The idle frame: nothing open, no commands, no hits.
  static const LyricsModalFrame closed = LyricsModalFrame(
    commands: <List<Object?>>[],
    hits: <List<Object?>>[],
  );
}

/// Stateful receiver for the two lyric popovers.
///
/// Typical wiring: paint with a sink that records the action strings published
/// with the frame (the sink fires while composing the frame, not on a tap),
/// then forward the tapped hit's action to [handleAction], render [build] on
/// top of the panel, and apply non-null results through LyricsController. Do not pass
/// [handleAction] itself as the sink: it would toggle the popover on every
/// repaint.
class LyricsModalHost {
  LyricsModalHost({
    required this.model,
    required this.stageWidth,
    required this.measureText,
    this.opacity = 1,
    this.offset = 0,
    this.onSourceSelected,
  });

  /// Latest panel snapshot. Mutable by design: the composition root assigns a
  /// new model every frame; the open popover keeps reading the newest values.
  LyricsPanelModel model;

  /// Stage width in Qt design pixels (NativeHud::width), NOT the lyric panel
  /// width: `modalBounds` computes `width * 0.56` from the stage width
  /// (NativeHud.cpp:145-152).
  final double stageWidth;

  /// Injected glyph measurement, forwarded unchanged to both popovers.
  final LyricsModalMeasureText measureText;

  /// Eased opacity of the open popover (LyricsOffsetMotion/LyricsSourceMotion).
  double opacity;

  /// Eased vertical offset of the open popover, in stage pixels.
  double offset;

  /// Called after a source row is chosen and the popover is closed, so the
  /// caller can run LyricsController::selectLocalSource + browse reset.
  void Function(LyricsSourceSelection selection)? onSourceSelected;

  /// QML action that opens/toggles the offset popover.
  static const String actionOffset = 'player:lyrics-offset';

  /// QML action that opens/toggles the source popover (Qt name
  /// "lyrics-sources", NativeHudController.cpp:336-341).
  static const String actionSources = 'player:lyrics-sources';

  /// Qt modal kind string of the source popover (NativeHudController.cpp:337).
  static const String sourceModalKind = 'lyrics-source';

  /// Qt close action shared by both popovers (NativeHudModal.cpp:96,158).
  static const String actionClose = lyricsSourceCloseAction;

  /// One notch of the two offset buttons (NativeHudController.cpp:330-331).
  static const double offsetStepMs = 200;

  /// Hard clamp applied by LyricsController (LyricsController.cpp:511-518).
  static const double offsetLimitMs = 10000;

  String? _openAction;

  /// The open popover kind, null when closed.
  String? get openAction => _openAction;

  bool get isOpen => _openAction != null;

  /// Opens the popover named by [action] (accepts the QML action string or the
  /// Qt modal kind). Opening is idempotent; [handleAction] owns the toggle.
  void open(String action) {
    if (action == actionOffset || action == LyricsOffsetModal.kind) {
      _openAction = LyricsOffsetModal.kind;
      return;
    }
    if (action == actionSources || action == sourceModalKind) {
      if (!_canOpenSources) {
        return;
      }
      _openAction = sourceModalKind;
    }
  }

  /// Closes the open popover and clears its state immediately (no closing
  /// animation is owned here; the caller drives motion opacity/offset).
  void close() {
    _openAction = null;
  }

  /// Builds the open popover through the  port, or [LyricsModalFrame.closed].
  LyricsModalFrame build() {
    final String? action = _openAction;
    if (action == null) {
      return LyricsModalFrame.closed;
    }
    if (action == LyricsOffsetModal.kind) {
      final LyricsOffsetModalFrame frame = LyricsOffsetModal(
        LyricsOffsetModalState(
          width: stageWidth,
          opacity: opacity,
          offset: offset,
          offsetMs: model.offsetMs,
          globalOffsetMs: model.globalOffsetMs,
          measureText: measureText,
          dark: model.dark,
          reduced: model.reducedMotion,
        ),
      ).build();
      return LyricsModalFrame(
        openAction: action,
        commands: frame.commands,
        hits: frame.hits,
      );
    }
    final LyricsSourceModalFrame frame = LyricsSourceModal(
      width: stageWidth,
      measureText: measureText,
      dark: model.dark,
      reduced: model.reducedMotion,
      opacity: opacity,
      offset: offset,
      localSource: model.localSource,
    ).build();
    return LyricsModalFrame(
      openAction: action,
      commands: frame.commands,
      hits: frame.hits,
    );
  }

  /// Consumes one HUD action.
  ///
  /// Returns null for every action that only changes presentation (open,
  /// toggle, close, no-op reset/apply-global) and for actions the current
  /// popover does not own. Offset actions return a suggestion instead of
  /// mutating [model]; source rows call [onSourceSelected] and close.
  LyricsModalResult? handleAction(String action) {
    if (action == actionOffset) {
      if (_openAction == LyricsOffsetModal.kind) {
        close();
      } else {
        open(actionOffset);
      }
      return null;
    }
    if (action == actionSources) {
      if (!_canOpenSources) {
        return null;
      }
      if (_openAction == sourceModalKind) {
        close();
      } else {
        open(actionSources);
      }
      return null;
    }
    if (action == actionClose) {
      if (_openAction != null) {
        close();
      }
      return null;
    }
    if (_openAction == LyricsOffsetModal.kind) {
      switch (action) {
        case LyricsOffsetModal.actionEarlier:
          return _offset(action, offsetStepMs);
        case LyricsOffsetModal.actionLater:
          return _offset(action, -offsetStepMs);
        case LyricsOffsetModal.actionReset:
          // Qt returns early when the offset is already zero
          // (LyricsController.cpp:521-531): no signal, no redraw.
          if (model.offsetMs == 0) {
            return null;
          }
          return LyricOffsetChange(
            action: action,
            deltaMs: -model.offsetMs,
            newOffset: 0,
            global: false,
          );
        case LyricsOffsetModal.actionApplyGlobal:
          // Qt returns early when track and global offsets already agree
          // (LyricsController.cpp:534-544).
          if (model.offsetMs == model.globalOffsetMs) {
            return null;
          }
          return LyricOffsetChange(
            action: action,
            deltaMs: 0,
            newOffset: model.offsetMs,
            global: true,
          );
        default:
          return null;
      }
    }
    if (_openAction == sourceModalKind) {
      final bool select = action == 'player:lyrics-source' ||
          action.startsWith(lyricsSourceSelectPrefix);
      if (select) {
        final LyricsSourceSelection selection =
            LyricsSourceSelection(lyricsSourceSelectId(action));
        // Qt selects, resets browse and closes in one branch
        // (NativeHudController.cpp:342-345); closing before the callback lets
        // the caller rebuild a closed frame synchronously.
        close();
        onSourceSelected?.call(selection);
        return selection;
      }
    }
    return null;
  }

  bool get _canOpenSources => model.isLocal && model.provider == 'local';

  LyricOffsetChange _offset(String action, double deltaMs) {
    final double next = _clampOffset(model.offsetMs + deltaMs);
    return LyricOffsetChange(
      action: action,
      deltaMs: deltaMs,
      newOffset: next,
      global: false,
    );
  }

  static double _clampOffset(double value) {
    if (value < -offsetLimitMs) {
      return -offsetLimitMs;
    }
    if (value > offsetLimitMs) {
      return offsetLimitMs;
    }
    return value;
  }
}
