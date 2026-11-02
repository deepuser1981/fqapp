import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'app_log.dart';
import 'desktop_platform.dart';
import 'mini_player_contract.dart';

typedef MiniPlayerStateHandler =
    Future<Map<String, dynamic>?> Function(MiniPlayerEvent event);

/// 主窗这一侧的小窗窗口控制器：建窗、发控制指令、收状态/进度、记住几何。
///
/// 小窗是独立引擎，不能直接读主窗的播放器；进度靠双向消息交接，见
/// [MiniPlayerPayload] 与 [MiniPlayerEvent]。
class MiniPlayerWindowController {
  MiniPlayerWindowController._();

  static final instance = MiniPlayerWindowController._();

  static const _widthKeyLandscape = 'mini_player_width_landscape';
  static const _heightKeyLandscape = 'mini_player_height_landscape';
  static const _widthKeyPortrait = 'mini_player_width_portrait';
  static const _heightKeyPortrait = 'mini_player_height_portrait';
  static const _xKey = 'mini_player_x';
  static const _yKey = 'mini_player_y';

  MiniPlayerStateHandler? onState;

  WindowController? _window;
  String? _windowId;
  StreamSubscription<void>? _windowsSub;
  bool _closedNotified = false;
  int _lastPositionMs = 0;
  int _lastDurationMs = 0;
  int _lastEpisodeIndex = 0;

  bool get isOpen => _window != null;
  String? get windowId => _windowId;

  Future<void> open(MiniPlayerPayload data) async {
    if (!isWindowsDesktop) {
      throw StateError('小窗播放只在 Windows 桌面可用');
    }
    if (_window != null) {
      await focus();
      return;
    }
    final mainBounds = await windowManager.getBounds();
    final display = await _displayFor(mainBounds);
    final work = _workArea(display);
    final geometry = await _resolveGeometry(data.aspect, work);
    final payload = data.copyWith(
      width: geometry.width,
      height: geometry.height,
      x: geometry.x,
      y: geometry.y,
    );
    await miniPlayerStateChannel.setMethodCallHandler(_handleState);
    final controller = await WindowController.create(
      WindowConfiguration(
        hiddenAtLaunch: true,
        arguments: jsonEncode(payload.toJson()),
      ),
    );
    _window = controller;
    _windowId = controller.windowId;
    _closedNotified = false;
    _lastPositionMs = payload.positionMs;
    _lastDurationMs = payload.durationMs;
    _lastEpisodeIndex = payload.episodeIndex;
    _windowsSub?.cancel();
    _windowsSub = onWindowsChanged.listen((_) {
      unawaited(_checkWindowAlive());
    });
    AppLog.d(
      'mini-player',
      'window opened id=$_windowId episode=${payload.episodeIndex} '
          'position=${payload.positionMs}',
    );
  }

  Future<void> focus() async {
    try {
      await miniPlayerControlChannel.invokeMethod<void>('focus');
    } catch (_) {
      // 窗口刚建还没注册 handler 时忽略：它自己会 focus。
    }
  }

  /// 让小窗把进度交回来并关窗。
  Future<void> requestReturn() async {
    if (_window == null) return;
    try {
      await miniPlayerControlChannel.invokeMethod<void>('return');
    } catch (error) {
      AppLog.d('mini-player', 'requestReturn failed: $error');
      await _closeFallback();
    }
  }

  /// 主窗主动收窗（页面销毁、主窗退出前）。
  Future<void> close() async {
    if (_window == null) return;
    try {
      await miniPlayerControlChannel.invokeMethod<void>('close');
    } catch (_) {
      await _closeFallback();
    }
  }

  /// 页面销毁时彻底清掉 handler，避免下个页面收到旧消息。
  Future<void> dispose() async {
    await close();
    await _resetWindow();
    await miniPlayerStateChannel.setMethodCallHandler(null);
    onState = null;
  }

  Future<void> _closeFallback() async {
    await _resetWindow();
  }

  Future<dynamic> _handleState(MethodCall call) async {
    final event = MiniPlayerEvent.fromCall(call);
    if (event == null) return null;
    _lastPositionMs = event.positionMs;
    _lastDurationMs = event.durationMs;
    _lastEpisodeIndex = event.episodeIndex;
    if (event.width > 0 && event.height > 0) {
      await _saveGeometry(event);
    }
    final handler = onState;
    Map<String, dynamic>? reply;
    if (handler != null) {
      try {
        reply = await handler(event);
      } catch (error, stack) {
        AppLog.e(
          'mini-player',
          'state handler failed type=${event.type.name}',
          error: error,
          stack: stack,
        );
      }
    }
    if (event.type == MiniPlayerEventType.closed ||
        event.type == MiniPlayerEventType.returned) {
      _closedNotified = true;
      await _resetWindow();
    }
    return reply;
  }

  Future<void> _checkWindowAlive() async {
    final id = _windowId;
    if (id == null || _closedNotified) return;
    final windows = await WindowController.getAll();
    if (windows.any((window) => window.windowId == id)) return;
    _closedNotified = true;
    final event = MiniPlayerEvent(
      type: MiniPlayerEventType.closed,
      episodeIndex: _lastEpisodeIndex,
      positionMs: _lastPositionMs,
      durationMs: _lastDurationMs,
      playing: false,
    );
    final handler = onState;
    if (handler != null) {
      try {
        await handler(event);
      } catch (_) {}
    }
    await _resetWindow();
  }

  Future<void> _resetWindow() async {
    await _windowsSub?.cancel();
    _windowsSub = null;
    _window = null;
    _windowId = null;
  }

  Future<void> _saveGeometry(MiniPlayerEvent event) async {
    final prefs = await _prefs();
    if (prefs == null) return;
    final portrait = event.height > event.width;
    await prefs.setDouble(
      portrait ? _widthKeyPortrait : _widthKeyLandscape,
      event.width,
    );
    await prefs.setDouble(
      portrait ? _heightKeyPortrait : _heightKeyLandscape,
      event.height,
    );
    await prefs.setDouble(_xKey, event.x);
    await prefs.setDouble(_yKey, event.y);
  }

  Future<({double width, double height, double x, double y})> _resolveGeometry(
    double aspect,
    Rect work,
  ) async {
    final safeAspect = aspect.isFinite && aspect > 0.2 && aspect < 5
        ? aspect
        : 16 / 9;
    final portrait = safeAspect < 1;
    final prefs = await _prefs();
    final savedWidth = prefs?.getDouble(
      portrait ? _widthKeyPortrait : _widthKeyLandscape,
    );
    final savedHeight = prefs?.getDouble(
      portrait ? _heightKeyPortrait : _heightKeyLandscape,
    );
    double width;
    double height;
    if (savedWidth != null &&
        savedHeight != null &&
        savedWidth.isFinite &&
        savedHeight.isFinite &&
        savedWidth > 0 &&
        savedHeight > 0) {
      width = savedWidth;
      height = savedHeight;
    } else if (portrait) {
      height = math.min(480.0, work.height * 0.9);
      width = height * safeAspect;
    } else {
      width = math.min(420.0, work.width * 0.9);
      height = width / safeAspect;
    }
    width = width.clamp(240.0, math.max(240.0, work.width * 0.95)).toDouble();
    height = height
        .clamp(135.0, math.max(135.0, work.height * 0.95))
        .toDouble();
    final savedX = prefs?.getDouble(_xKey);
    final savedY = prefs?.getDouble(_yKey);
    double x;
    double y;
    if (savedX != null &&
        savedY != null &&
        _fits(savedX, savedY, width, height, work)) {
      x = savedX;
      y = savedY;
    } else {
      x = work.right - width - 24;
      y = work.bottom - height - 24;
    }
    x = x
        .clamp(work.left + 8, math.max(work.left + 8, work.right - width - 8))
        .toDouble();
    y = y.clamp(work.top + 8, math.max(work.top + 8, work.bottom - height - 8));
    return (width: width, height: height, x: x, y: y);
  }

  bool _fits(double x, double y, double width, double height, Rect work) {
    final rect = Rect.fromLTWH(x, y, width, height);
    return rect.left >= work.left - 24 &&
        rect.top >= work.top - 24 &&
        rect.right <= work.right + 24 &&
        rect.bottom <= work.bottom + 24;
  }

  Future<Display> _displayFor(Rect bounds) async {
    final displays = await screenRetriever.getAllDisplays();
    if (displays.isEmpty) return screenRetriever.getPrimaryDisplay();
    final center = bounds.center;
    for (final display in displays) {
      final work = _workArea(display);
      if (work.contains(center)) return display;
    }
    return displays.first;
  }

  Rect _workArea(Display display) {
    final position = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    return position & size;
  }

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }
}
