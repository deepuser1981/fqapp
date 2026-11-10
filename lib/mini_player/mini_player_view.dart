import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

const _accent = Color(0xFFEF5038);

/// 独立小窗的界面：无标题栏、画面到边，悬停才出控制层。
///
/// 这个 widget 只画界面与手势，不持有播放器；播放/进度由
/// [MiniPlayerWindow] 的 shell 通过回调接进来，保证窗口与播放器生命周期
/// 对齐（窗口销毁 = 播放器释放）。
class MiniPlayerView extends StatefulWidget {
  const MiniPlayerView({
    super.key,
    required this.aspect,
    required this.coverUrl,
    required this.title,
    required this.episodeLabel,
    required this.playing,
    required this.position,
    required this.duration,
    required this.positionStream,
    required this.volume,
    required this.alwaysOnTop,
    required this.loading,
    required this.error,
    required this.video,
    required this.onToggle,
    required this.onSeek,
    required this.onPrevious,
    required this.onNext,
    required this.onVolume,
    required this.onReturn,
    required this.onClose,
    required this.onTogglePin,
  });

  final double aspect;
  final String coverUrl;
  final String title;
  final String episodeLabel;
  final bool playing;
  final Duration position;
  final Duration duration;
  final Stream<Duration> positionStream;
  final double volume;
  final bool alwaysOnTop;
  final bool loading;
  final String? error;

  /// 已就绪的视频画面；loading 时为空。
  final Widget? video;

  final Future<void> Function() onToggle;
  final Future<void> Function(Duration target) onSeek;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final Future<void> Function(double volume) onVolume;
  final VoidCallback onReturn;
  final VoidCallback onClose;
  final VoidCallback onTogglePin;

  @override
  State<MiniPlayerView> createState() => _MiniPlayerViewState();
}

class _MiniPlayerViewState extends State<MiniPlayerView> {
  bool _visible = true;
  Timer? _hideTimer;
  Timer? _tapTimer;
  Timer? _volumeTimer;
  Duration? _scrub;
  double? _volumeChip;
  double _volume = 1;
  Duration _latestPosition = Duration.zero;
  StreamSubscription<Duration>? _positionSub;

  bool get _chromeVisible =>
      _visible || !widget.playing || widget.error != null || widget.loading;

  @override
  void initState() {
    super.initState();
    _volume = widget.volume;
    _latestPosition = widget.position;
    _positionSub = widget.positionStream.listen((value) {
      _latestPosition = value;
    });
    _show();
  }

  @override
  void didUpdateWidget(covariant MiniPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) _show();
    if (oldWidget.volume != widget.volume) _volume = widget.volume;
    if (oldWidget.positionStream != widget.positionStream) {
      _positionSub?.cancel();
      _latestPosition = widget.position;
      _positionSub = widget.positionStream.listen((value) {
        _latestPosition = value;
      });
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _tapTimer?.cancel();
    _volumeTimer?.cancel();
    _positionSub?.cancel();
    super.dispose();
  }

  void _show() {
    _hideTimer?.cancel();
    if (!_visible) setState(() => _visible = true);
    if (!widget.playing) return;
    _hideTimer = Timer(const Duration(milliseconds: 2400), () {
      if (mounted && widget.playing && _scrub == null) {
        setState(() => _visible = false);
      }
    });
  }

  void _scheduleToggle() {
    _tapTimer?.cancel();
    _tapTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(widget.onToggle());
    });
  }

  void _onDoubleTap() {
    _tapTimer?.cancel();
    widget.onReturn();
  }

  void _onPanStart() {
    _tapTimer?.cancel();
    unawaited(windowManager.startDragging());
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onReturn();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      unawaited(widget.onToggle());
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      final target = _latestPosition - const Duration(seconds: 10);
      unawaited(widget.onSeek(target < Duration.zero ? Duration.zero : target));
      _show();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      final target = _latestPosition + const Duration(seconds: 10);
      final end = widget.duration;
      unawaited(
        widget.onSeek(end > Duration.zero && target > end ? end : target),
      );
      _show();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyM) {
      unawaited(_setVolume(_volume == 0 ? 1 : 0));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _setVolume(double value) async {
    final clamped = value.clamp(0.0, 1.0).toDouble();
    setState(() {
      _volume = clamped;
      _volumeChip = clamped;
    });
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _volumeChip = null);
    });
    await widget.onVolume(clamped);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta.dy > 0 ? -0.05 : 0.05;
    unawaited(_setVolume(_volume + delta));
  }

  Future<void> _seekTo(double ms) async {
    final end = widget.duration.inMilliseconds;
    final target = ms.clamp(0, end > 0 ? end : ms).toInt();
    setState(() => _scrub = null);
    await widget.onSeek(Duration(milliseconds: target));
    _show();
  }

  @override
  Widget build(BuildContext context) {
    final aspect = widget.aspect.isFinite && widget.aspect > 0
        ? widget.aspect
        : 16 / 9;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: MouseRegion(
        onHover: (_) => _show(),
        onEnter: (_) => _show(),
        onExit: (_) => _show(),
        cursor: _chromeVisible
            ? SystemMouseCursors.basic
            : SystemMouseCursors.none,
        child: Listener(
          onPointerSignal: _onPointerSignal,
          child: ColoredBox(
            color: Colors.black,
            child: DragToResizeArea(
              resizeEdgeSize: 6,
              enableResizeEdges: const [
                ResizeEdge.left,
                ResizeEdge.right,
                ResizeEdge.topLeft,
                ResizeEdge.topRight,
                ResizeEdge.bottomLeft,
                ResizeEdge.bottomRight,
              ],
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: AspectRatio(
                      aspectRatio: aspect,
                      child: widget.video == null
                          ? const SizedBox.expand()
                          : widget.video!,
                    ),
                  ),
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (_) => _scheduleToggle(),
                      onDoubleTap: _onDoubleTap,
                      onPanStart: (_) => _onPanStart(),
                    ),
                  ),
                  if (widget.loading) _loadingLayer(),
                  if (widget.error != null) _errorLayer(),
                  _chrome(aspect),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chrome(double aspect) {
    final show = _chromeVisible;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 104,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: show ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xD9000000)],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 10,
          right: 10,
          child: IgnorePointer(
            ignoring: !show,
            child: AnimatedOpacity(
              opacity: show ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: Row(
                children: [
                  _glassButton(
                    icon: widget.alwaysOnTop
                        ? Icons.arrow_upward_rounded
                        : Icons.arrow_upward_outlined,
                    tooltip: widget.alwaysOnTop ? '取消置顶' : '置顶',
                    active: widget.alwaysOnTop,
                    onPressed: widget.onTogglePin,
                  ),
                  const SizedBox(width: 6),
                  _glassButton(
                    icon: Icons.open_in_full_rounded,
                    tooltip: '回主窗（Esc）',
                    onPressed: widget.onReturn,
                  ),
                  const SizedBox(width: 6),
                  _glassButton(
                    icon: Icons.close_rounded,
                    tooltip: '关闭小窗',
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            ignoring: !show,
            child: AnimatedOpacity(
              opacity: show ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StreamBuilder<Duration>(
                      stream: widget.positionStream,
                      initialData: widget.position,
                      builder: (context, snapshot) {
                        final position =
                            _scrub ?? snapshot.data ?? widget.position;
                        final end = widget.duration;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [_bar(position, end), _rail(position, end)],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (_volumeChip case final value?)
          Positioned(
            left: 0,
            right: 0,
            bottom: 86,
            child: IgnorePointer(
              child: Center(
                child: _pill(
                  icon: value == 0 ? Icons.volume_off : Icons.volume_up,
                  text: value == 0 ? '静音' : '音量 ${(value * 100).round()}%',
                ),
              ),
            ),
          ),
        if (_resizeGripVisible)
          const Positioned(
            right: 8,
            bottom: 9,
            child: IgnorePointer(
              child: Icon(
                Icons.drag_handle_rounded,
                size: 12,
                color: Color(0x66FFFFFF),
              ),
            ),
          ),
      ],
    );
  }

  bool get _resizeGripVisible => _visible && widget.playing;

  Widget _bar(Duration position, Duration duration) {
    return SizedBox(
      height: 42,
      child: Row(
        children: [
          const SizedBox(width: 8),
          _iconButton(
            icon: widget.playing
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            tooltip: widget.playing ? '暂停（空格）' : '播放（空格）',
            size: 30,
            onPressed: () => unawaited(widget.onToggle()),
            emphasize: true,
          ),
          _iconButton(
            icon: Icons.skip_previous_rounded,
            tooltip: '上一集',
            size: 28,
            onPressed: widget.onPrevious,
          ),
          _iconButton(
            icon: Icons.skip_next_rounded,
            tooltip: '下一集',
            size: 28,
            onPressed: widget.onNext,
          ),
          const SizedBox(width: 8),
          Text(
            _time(position),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            ' / ${_time(duration)}',
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xB3FFFFFF),
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xF2FFFFFF)),
            ),
          ),
          const SizedBox(width: 6),
          if (widget.episodeLabel.isNotEmpty)
            Text(
              widget.episodeLabel,
              maxLines: 1,
              style: const TextStyle(fontSize: 11, color: Color(0x8CFFFFFF)),
            ),
          const SizedBox(width: 10),
        ],
      ),
    );
  }

  Widget _rail(Duration position, Duration duration) {
    final total = duration.inMilliseconds;
    final fraction = total > 0
        ? (position.inMilliseconds / total).clamp(0.0, 1.0)
        : 0.0;
    return SizedBox(
      height: 14,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          void seek(double dx) {
            if (total <= 0) return;
            final target = (dx / width).clamp(0.0, 1.0) * total;
            setState(() => _scrub = Duration(milliseconds: target.round()));
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) => seek(details.localPosition.dx),
            onTapUp: (details) {
              seek(details.localPosition.dx);
              final target = _scrub;
              if (target != null) {
                unawaited(_seekTo(target.inMilliseconds.toDouble()));
              }
            },
            onHorizontalDragStart: (details) => seek(details.localPosition.dx),
            onHorizontalDragUpdate: (details) => seek(details.localPosition.dx),
            onHorizontalDragEnd: (_) {
              final target = _scrub;
              if (target != null) {
                unawaited(_seekTo(target.inMilliseconds.toDouble()));
              }
            },
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: const Color(0x2EFFFFFF),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: width * (1 - fraction),
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: _accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Positioned(
                  left: (fraction * width - 4).clamp(0.0, width - 8),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: Color(0x40EF5038), blurRadius: 4),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _loadingLayer() {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.video == null) const ColoredBox(color: Colors.black),
        const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white70,
            ),
          ),
        ),
      ],
    );
  }

  Widget _errorLayer() {
    return ColoredBox(
      color: const Color(0xE6000000),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.error ?? '播放失败',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 10),
            TextButton(onPressed: widget.onReturn, child: const Text('回主窗')),
          ],
        ),
      ),
    );
  }

  Widget _glassButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: active ? const Color(0x29EF5038) : const Color(0x700A0A0C),
            shape: BoxShape.circle,
            border: Border.all(
              color: active ? const Color(0x57EF5038) : const Color(0x21FFFFFF),
            ),
          ),
          child: Icon(
            icon,
            size: 15,
            color: active ? _accent : const Color(0xEBFFFFFF),
          ),
        ),
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required double size,
    required VoidCallback? onPressed,
    bool emphasize = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: 30,
          child: Icon(
            icon,
            size: emphasize ? 20 : 17,
            color: onPressed == null
                ? const Color(0x4DFFFFFF)
                : const Color(0xF2FFFFFF),
          ),
        ),
      ),
    );
  }

  Widget _pill({required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xD91C1C1F),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x1FFFFFFF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white70),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  static String _time(Duration value) {
    final total = value.inSeconds.clamp(0, 24 * 60 * 60);
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
}
