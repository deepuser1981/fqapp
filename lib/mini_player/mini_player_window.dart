import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../services/desktop_media.dart';
import '../services/mini_player_contract.dart';
import 'mini_player_view.dart';

/// 小窗独立引擎的入口：配窗口、建播放器、跑 [MiniPlayerApp]。
///
/// 窗口是先隐藏创建的（WindowConfiguration.hiddenAtLaunch），尺寸/位置由主窗
/// 算好放在 payload 里；这里只负责把风格切成无边框、置顶并显示。
Future<void> runMiniPlayerWindow(MiniPlayerPayload payload) async {
  MediaKit.ensureInitialized();
  await _ensureWindowManager();
  await windowManager.setPreventClose(true);
  unawaited(
    windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: Size(payload.width, payload.height),
        minimumSize: const Size(240, 135),
        center: false,
        backgroundColor: Colors.black,
        skipTaskbar: false,
        title: '什锦铺 · 小窗',
      ),
      () async {
        try {
          await windowManager.setAsFrameless();
          await windowManager.setPosition(Offset(payload.x, payload.y));
          await windowManager.setAlwaysOnTop(true);
        } finally {
          await windowManager.show();
          await windowManager.focus();
        }
      },
    ),
  );
  runApp(MiniPlayerApp(payload: payload));
}

/// desktop_multi_window 建窗时插件注册与 Dart main 可能同时起跑，windowManager 的
/// 通道偶尔会在第一次调用时还没就绪；重试几次比整窗起不来好。
Future<void> _ensureWindowManager() async {
  for (var attempt = 0; attempt < 20; attempt++) {
    try {
      await windowManager.ensureInitialized();
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

class MiniPlayerApp extends StatelessWidget {
  const MiniPlayerApp({super.key, required this.payload});

  final MiniPlayerPayload payload;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFFEF5038),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: Colors.black,
    ),
    home: MiniPlayerWindow(payload: payload),
  );
}

class MiniPlayerWindow extends StatefulWidget {
  const MiniPlayerWindow({super.key, required this.payload});

  final MiniPlayerPayload payload;

  @override
  State<MiniPlayerWindow> createState() => _MiniPlayerWindowState();
}

class _MiniPlayerWindowState extends State<MiniPlayerWindow>
    with WindowListener {
  late MiniPlayerPayload _payload = widget.payload;
  Player? _player;
  VideoController? _video;
  DesktopMedia? _media;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _ticker;
  Timer? _noticeTimer;

  bool _loading = true;
  String? _error;
  bool _playing = false;
  bool _alwaysOnTop = true;
  bool _closing = false;
  bool _switching = false;
  bool _ended = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _position = Duration(milliseconds: _payload.positionMs);
    _duration = Duration(milliseconds: _payload.durationMs);
    _volume = _payload.volume;
    unawaited(_registerControlChannel());
    windowManager.addListener(this);
    unawaited(_start());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _noticeTimer?.cancel();
    windowManager.removeListener(this);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final player = _player;
    final media = _media;
    _player = null;
    _media = null;
    unawaited(player?.dispose() ?? Future<void>.value());
    media?.close();
    unawaited(miniPlayerControlChannel.setMethodCallHandler(null));
    super.dispose();
  }

  Future<void> _registerControlChannel() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        await miniPlayerControlChannel.setMethodCallHandler(_onControl);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  @override
  void onWindowClose() async {
    await _closeWindow(send: true);
  }

  Future<dynamic> _onControl(MethodCall call) async {
    switch (call.method) {
      case 'return':
        await _returnToMain();
      case 'close':
        await _closeWindow(send: true);
      case 'focus':
        await windowManager.focus();
      case 'reopen':
        final args = call.arguments;
        if (args is Map) {
          await _reopen(
            MiniPlayerPayload.fromJson(Map<String, dynamic>.from(args)),
          );
        }
      default:
        return null;
    }
    return null;
  }

  Future<void> _start() async {
    _ticker?.cancel();
    await _cancelSubscriptions();
    setState(() {
      _loading = true;
      _error = null;
      _ended = false;
    });
    final payload = _payload;
    DesktopMedia? media;
    Player? created;
    try {
      var url = payload.url;
      if (payload.keyHex.isNotEmpty) {
        media = await DesktopMedia.open(payload.url, payload.keyHex);
        url = media.url;
      }
      created = Player();
      final player = created;
      final video = VideoController(player);
      await player.open(Media(url), play: false);
      if (payload.positionMs > 0) {
        await player.seek(Duration(milliseconds: payload.positionMs));
      }
      await player.setVolume((payload.volume.clamp(0, 1) * 100).toDouble());
      if (payload.rate != 1.0) await player.setRate(payload.rate);
      if (!mounted) {
        await player.dispose();
        media?.close();
        return;
      }
      _player = player;
      _video = video;
      _media = media;
      _position = player.state.position;
      _duration = player.state.duration;
      _bind(player);
      if (payload.playing) await player.play();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _playing = payload.playing;
      });
      _tick();
      await _sendState('position');
    } catch (error) {
      await created?.dispose();
      media?.close();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '播放失败，请回主窗重试';
      });
      await _sendState('error', extra: {'message': '小窗播放失败'});
    }
  }

  void _bind(Player player) {
    _subscriptions.addAll([
      player.stream.position.listen((position) {
        _position = position;
      }),
      player.stream.duration.listen((duration) {
        _duration = duration;
        if (mounted) setState(() {});
      }),
      player.stream.playing.listen((playing) {
        _playing = playing;
        if (playing && _ended) _ended = false;
        if (mounted) setState(() {});
        unawaited(_sendState('position'));
      }),
      player.stream.completed.listen((completed) {
        if (!completed) return;
        _ended = true;
        _position = _duration;
        unawaited(_sendState('position'));
        if (_payload.hasNext) unawaited(_requestEpisode(1));
      }),
      player.stream.error.listen((_) {
        if (!mounted) return;
        setState(() => _error = '播放中断，请回主窗重试');
      }),
    ]);
  }

  Future<void> _cancelSubscriptions() async {
    final pending = List<StreamSubscription<dynamic>>.from(_subscriptions);
    _subscriptions.clear();
    for (final subscription in pending) {
      await subscription.cancel();
    }
  }

  void _tick() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_loading && !_closing) unawaited(_sendState('position'));
    });
  }

  Future<Map<String, dynamic>?> _sendState(
    String method, {
    Map<String, dynamic>? extra,
    bool withGeometry = false,
    bool? playingOverride,
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final args = <String, dynamic>{
        'episodeIndex': _payload.episodeIndex,
        'positionMs': _position.inMilliseconds,
        'durationMs': _duration.inMilliseconds,
        'playing': playingOverride ?? _playing,
        ...?extra,
      };
      if (withGeometry) {
        final bounds = await windowManager.getBounds();
        args.addAll({
          'width': bounds.width,
          'height': bounds.height,
          'x': bounds.left,
          'y': bounds.top,
        });
      }
      final reply = await miniPlayerStateChannel
          .invokeMethod<dynamic>(method, args)
          .timeout(timeout);
      if (reply is Map) return Map<String, dynamic>.from(reply);
      return null;
    } catch (_) {
      // 主窗可能已经关闭/退出；小窗自己继续播到关闭即可。
      return null;
    }
  }

  Future<void> _requestEpisode(int delta) async {
    if (_switching) return;
    _switching = true;
    try {
      final reply = await _sendState(
        'episode',
        extra: {'delta': delta},
        timeout: const Duration(seconds: 20),
      );
      if (!mounted) return;
      if (reply == null || reply['ok'] != true) {
        final hasNext = _payload.hasNext;
        final hasPrevious = _payload.episodeIndex > 0;
        _showNotice(
          delta > 0
              ? (hasNext ? '下一集加载失败' : '已经是最后一集')
              : (hasPrevious ? '上一集加载失败' : '已经是第一集'),
        );
        return;
      }
      final payload = reply['payload'];
      if (payload is! Map) return;
      final next = MiniPlayerPayload.fromJson(
        Map<String, dynamic>.from(payload),
      );
      await _switchTo(next);
    } finally {
      _switching = false;
    }
  }

  Future<void> _switchTo(MiniPlayerPayload payload) async {
    final oldPlayer = _player;
    final oldMedia = _media;
    await _cancelSubscriptions();
    _ticker?.cancel();
    setState(() {
      _payload = payload;
      _player = null;
      _video = null;
      _media = null;
      _loading = true;
      _error = null;
      _ended = false;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    await WidgetsBinding.instance.endOfFrame;
    await oldPlayer?.dispose();
    oldMedia?.close();
    await _start();
  }

  Future<void> _toggle() async {
    final player = _player;
    if (player == null) return;
    if (_ended) {
      _ended = false;
      await player.seek(Duration.zero);
      await player.play();
      return;
    }
    if (player.state.playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> _seek(Duration target) async {
    final player = _player;
    if (player == null) return;
    final end = _duration.inMilliseconds;
    final ms = end > 0
        ? target.inMilliseconds.clamp(0, end)
        : target.inMilliseconds;
    await player.seek(Duration(milliseconds: ms));
    _position = Duration(milliseconds: ms);
    await _sendState('position');
  }

  Future<void> _setVolume(double value) async {
    final player = _player;
    if (player == null) return;
    final clamped = value.clamp(0, 1).toDouble();
    setState(() => _volume = clamped);
    await player.setVolume(clamped * 100);
  }

  Future<void> _togglePin() async {
    final next = !_alwaysOnTop;
    await windowManager.setAlwaysOnTop(next);
    if (!mounted) return;
    setState(() => _alwaysOnTop = next);
  }

  Future<void> _returnToMain() async {
    if (_closing) return;
    _closing = true;
    try {
      final wasPlaying = _playing;
      await _player?.pause();
      await _sendState(
        'returned',
        withGeometry: true,
        playingOverride: wasPlaying,
      );
    } finally {
      await _hideWindow();
      _closing = false;
    }
  }

  Future<void> _closeWindow({required bool send}) async {
    if (_closing && send) return;
    _closing = true;
    try {
      if (send) {
        await _player?.pause();
        await _sendState('closed', withGeometry: true, playingOverride: false);
      }
    } finally {
      await _hideWindow();
      _closing = false;
    }
  }

  /// 小窗只隐藏、不销毁。
  ///
  /// 2026-11-03 崩溃转储：收回主窗时销毁第二个 Flutter 引擎会让
  /// `flutter_windows.dll` 在 0x17a58 访问冲突（APPCRASH 0xc0000005）。
  /// 改成隐藏并保留引擎，下次出窗走 [reopen] 复用；代价是隐藏期间仍占
  /// 一个解码器，但不会再在收回时把主进程带崩。
  Future<void> _hideWindow() async {
    _ticker?.cancel();
    try {
      await windowManager.setAlwaysOnTop(false);
    } catch (_) {}
    try {
      await windowManager.hide();
    } catch (_) {
      // 窗口已经不可用：下次 open 会重新建。
    }
  }

  Future<void> _reopen(MiniPlayerPayload payload) async {
    _closing = false;
    _ended = false;
    _error = null;
    final sameSource =
        _player != null &&
        _payload.url == payload.url &&
        _payload.keyHex == payload.keyHex;
    setState(() {
      _payload = payload;
      _loading = true;
    });
    try {
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setSize(Size(payload.width, payload.height));
      await windowManager.setPosition(Offset(payload.x, payload.y));
    } catch (_) {
    } finally {
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }
    if (sameSource) {
      final player = _player!;
      await player.setVolume((payload.volume.clamp(0, 1) * 100).toDouble());
      if (payload.rate != 1.0) await player.setRate(payload.rate);
      await player.seek(Duration(milliseconds: payload.positionMs));
      if (payload.playing) {
        await player.play();
      } else {
        await player.pause();
      }
      _position = Duration(milliseconds: payload.positionMs);
      _duration = player.state.duration;
      if (!mounted) return;
      setState(() {
        _loading = false;
        _playing = payload.playing;
      });
      _tick();
      await _sendState('position');
      return;
    }
    await _switchTo(payload);
  }

  void _showNotice(String text) {
    _noticeTimer?.cancel();
    if (!mounted) return;
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MiniPlayerView(
            aspect: _payload.aspect,
            coverUrl: _payload.coverUrl,
            title: _payload.title,
            episodeLabel: _payload.episodeLabel,
            playing: _playing,
            position: _position,
            duration: _duration,
            positionStream:
                player?.stream.position ?? const Stream<Duration>.empty(),
            volume: _volume,
            alwaysOnTop: _alwaysOnTop,
            loading: _loading,
            error: _error,
            video: _video == null
                ? null
                : Video(
                    controller: _video!,
                    controls: NoVideoControls,
                    fit: BoxFit.contain,
                    pauseUponEnteringBackgroundMode: false,
                    resumeUponEnteringForegroundMode: false,
                  ),
            onToggle: _toggle,
            onSeek: _seek,
            onPrevious: _payload.episodeIndex > 0
                ? () => unawaited(_requestEpisode(-1))
                : null,
            onNext: _payload.hasNext
                ? () => unawaited(_requestEpisode(1))
                : null,
            onVolume: _setVolume,
            onReturn: () => unawaited(_returnToMain()),
            onClose: () => unawaited(_closeWindow(send: true)),
            onTogglePin: () => unawaited(_togglePin()),
          ),
          if (_notice case final notice?)
            Positioned(
              left: 0,
              right: 0,
              top: 54,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xD91C1C1F),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0x1FFFFFFF)),
                    ),
                    child: Text(
                      notice,
                      style: const TextStyle(fontSize: 11, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
