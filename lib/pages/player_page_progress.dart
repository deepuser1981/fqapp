part of 'player_page.dart';

/// 播放页的进度保存：续播历史条目的构造。
///
/// Unknown catalogue ordinals are omitted; stable identity and seconds still
/// round-trip through the same history record.
extension _PlayerPageProgress on _PlayerPageState {
  Map<String, dynamic> _historyEntry(int index, NativePlayer player) {
    final durationMs = player.duration > Duration.zero
        ? player.duration.inMilliseconds
        : 0;
    final rawPositionMs = player.position.inMilliseconds;
    final positionMs = durationMs > 0
        ? rawPositionMs.clamp(0, durationMs)
        : rawPositionMs < 0
        ? 0
        : rawPositionMs;
    return {
      'id': widget.bookId,
      'kind': _historyKind,
      'title': widget.title,
      'bookId': widget.bookId,
      'seriesId': widget.bookId,
      'episodeId': widget.eps[index].itemId,
      'chapterId': widget.eps[index].itemId,
      if (widget.eps[index].hasKnownIndex) 'episode': index,
      'progress': durationMs > 0 ? positionMs / durationMs : 0.0,
      'position': positionMs / 1000,
      'duration': durationMs / 1000,
      'maxScroll': durationMs / 1000,
      'cover': widget.cover,
      'time': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// 小窗回传的进度没有 NativePlayer 可读，按同一条历史条目结构手写。
  /// 主窗仍是唯一落盘方，小窗只负责播和回报。
  Map<String, dynamic> _miniHistoryEntry(
    int index,
    int positionMs,
    int durationMs,
  ) {
    final total = durationMs > 0 ? durationMs : 0;
    final position = total > 0
        ? positionMs.clamp(0, total)
        : (positionMs < 0 ? 0 : positionMs);
    return {
      'id': widget.bookId,
      'kind': _historyKind,
      'title': widget.title,
      'bookId': widget.bookId,
      'seriesId': widget.bookId,
      'episodeId': widget.eps[index].itemId,
      'chapterId': widget.eps[index].itemId,
      'episode': index,
      'progress': total > 0 ? position / total : 0.0,
      'position': position / 1000,
      'duration': total / 1000,
      'maxScroll': total / 1000,
      'cover': widget.cover,
      'time': DateTime.now().millisecondsSinceEpoch,
    };
  }
}
