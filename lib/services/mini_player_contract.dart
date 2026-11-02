import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';

/// 小窗窗口与主窗之间的两个单向通道。
///
/// desktop_multi_window 的窗口是独立 Flutter 引擎（独立 isolate），两边的
/// Dart 内存不共享：进度、控制都必须走平台通道。拆成两个单向通道，避免
/// 「双向通道只能配对两个引擎」在新旧小窗交替时留下悬挂 handler。
const miniPlayerControlChannel = WindowMethodChannel(
  'fqapp/mini_player/control',
  mode: ChannelMode.unidirectional,
);

const miniPlayerStateChannel = WindowMethodChannel(
  'fqapp/mini_player/state',
  mode: ChannelMode.unidirectional,
);

/// 出窗时主窗交给小窗的完整播放上下文。
///
/// 小窗不读主窗的 Hive / SharedPreferences：续播历史由主窗落盘，小窗只
/// 负责播并回报位置。所有字段都能 JSON 序列化，因为窗口参数就是一段
/// JSON 字符串。
class MiniPlayerPayload {
  const MiniPlayerPayload({
    required this.bookId,
    required this.title,
    required this.episodeLabel,
    required this.episodeIndex,
    required this.episodeCount,
    required this.coverUrl,
    required this.url,
    required this.keyHex,
    required this.positionMs,
    required this.durationMs,
    required this.playing,
    required this.volume,
    required this.rate,
    required this.vertical,
    required this.aspect,
    this.width = 420,
    this.height = 236,
    this.x = 0,
    this.y = 0,
  });

  final String bookId;
  final String title;
  final String episodeLabel;
  final int episodeIndex;
  final int episodeCount;
  final String coverUrl;
  final String url;
  final String keyHex;
  final int positionMs;
  final int durationMs;
  final bool playing;
  final double volume;
  final double rate;
  final bool vertical;

  /// 画面宽高比（width / height），默认 16:9。
  final double aspect;

  /// 主窗算好的窗口几何（逻辑像素）。
  final double width;
  final double height;
  final double x;
  final double y;

  bool get hasNext => episodeIndex + 1 < episodeCount;

  MiniPlayerPayload copyWith({
    String? bookId,
    String? title,
    String? episodeLabel,
    int? episodeIndex,
    int? episodeCount,
    String? coverUrl,
    String? url,
    String? keyHex,
    int? positionMs,
    int? durationMs,
    bool? playing,
    double? volume,
    double? rate,
    bool? vertical,
    double? aspect,
    double? width,
    double? height,
    double? x,
    double? y,
  }) => MiniPlayerPayload(
    bookId: bookId ?? this.bookId,
    title: title ?? this.title,
    episodeLabel: episodeLabel ?? this.episodeLabel,
    episodeIndex: episodeIndex ?? this.episodeIndex,
    episodeCount: episodeCount ?? this.episodeCount,
    coverUrl: coverUrl ?? this.coverUrl,
    url: url ?? this.url,
    keyHex: keyHex ?? this.keyHex,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs ?? this.durationMs,
    playing: playing ?? this.playing,
    volume: volume ?? this.volume,
    rate: rate ?? this.rate,
    vertical: vertical ?? this.vertical,
    aspect: aspect ?? this.aspect,
    width: width ?? this.width,
    height: height ?? this.height,
    x: x ?? this.x,
    y: y ?? this.y,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'bookId': bookId,
    'title': title,
    'episodeLabel': episodeLabel,
    'episodeIndex': episodeIndex,
    'episodeCount': episodeCount,
    'coverUrl': coverUrl,
    'url': url,
    'keyHex': keyHex,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'playing': playing,
    'volume': volume,
    'rate': rate,
    'vertical': vertical,
    'aspect': aspect,
    'width': width,
    'height': height,
    'x': x,
    'y': y,
  };

  factory MiniPlayerPayload.fromJson(Map<String, dynamic> json) =>
      MiniPlayerPayload(
        bookId: '${json['bookId'] ?? ''}',
        title: '${json['title'] ?? ''}',
        episodeLabel: '${json['episodeLabel'] ?? ''}',
        episodeIndex: (json['episodeIndex'] as num?)?.toInt() ?? 0,
        episodeCount: (json['episodeCount'] as num?)?.toInt() ?? 0,
        coverUrl: '${json['coverUrl'] ?? ''}',
        url: '${json['url'] ?? ''}',
        keyHex: '${json['keyHex'] ?? ''}',
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        playing: json['playing'] == true,
        volume: (json['volume'] as num?)?.toDouble() ?? 1,
        rate: (json['rate'] as num?)?.toDouble() ?? 1,
        vertical: json['vertical'] == true,
        aspect: (json['aspect'] as num?)?.toDouble() ?? 16 / 9,
        width: (json['width'] as num?)?.toDouble() ?? 420,
        height: (json['height'] as num?)?.toDouble() ?? 236,
        x: (json['x'] as num?)?.toDouble() ?? 0,
        y: (json['y'] as num?)?.toDouble() ?? 0,
      );

  static MiniPlayerPayload? tryParse(String arguments) {
    if (arguments.isEmpty) return null;
    try {
      final decoded = jsonDecode(arguments);
      if (decoded is! Map) return null;
      return MiniPlayerPayload.fromJson(Map<String, dynamic>.from(decoded));
    } on FormatException {
      return null;
    }
  }
}

enum MiniPlayerEventType { position, returned, closed, episode, error }

/// 小窗 → 主窗的一条状态消息。
class MiniPlayerEvent {
  const MiniPlayerEvent({
    required this.type,
    this.episodeIndex = 0,
    this.positionMs = 0,
    this.durationMs = 0,
    this.playing = false,
    this.delta = 0,
    this.message,
    this.width = 0,
    this.height = 0,
    this.x = 0,
    this.y = 0,
  });

  final MiniPlayerEventType type;
  final int episodeIndex;
  final int positionMs;
  final int durationMs;
  final bool playing;

  /// 换集请求：+1 下一集，-1 上一集。
  final int delta;
  final String? message;

  /// 小窗被拖动/缩放后的几何，主窗用来记住下次出窗的位置。
  final double width;
  final double height;
  final double x;
  final double y;

  Duration get position => Duration(milliseconds: positionMs);

  static MiniPlayerEvent? fromCall(MethodCall call) {
    final args = call.arguments is Map
        ? Map<String, dynamic>.from(call.arguments as Map)
        : const <String, dynamic>{};
    final type = switch (call.method) {
      'position' => MiniPlayerEventType.position,
      'returned' => MiniPlayerEventType.returned,
      'closed' => MiniPlayerEventType.closed,
      'episode' => MiniPlayerEventType.episode,
      'error' => MiniPlayerEventType.error,
      _ => null,
    };
    if (type == null) return null;
    return MiniPlayerEvent(
      type: type,
      episodeIndex: (args['episodeIndex'] as num?)?.toInt() ?? 0,
      positionMs: (args['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (args['durationMs'] as num?)?.toInt() ?? 0,
      playing: args['playing'] == true,
      delta: (args['delta'] as num?)?.toInt() ?? 0,
      message: args['message'] as String?,
      width: (args['width'] as num?)?.toDouble() ?? 0,
      height: (args['height'] as num?)?.toDouble() ?? 0,
      x: (args['x'] as num?)?.toDouble() ?? 0,
      y: (args['y'] as num?)?.toDouble() ?? 0,
    );
  }
}
