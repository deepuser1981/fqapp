import '../models/media_item.dart';
import 'api_client.dart';
import 'backend_transport.dart';
import 'drama_download_store.dart';

/// Online directories are authoritative; offline playback keeps their saved
/// order, including episodes whose media has not been downloaded.
Future<List<Chapter>> loadVideoCatalogue({
  required String seriesId,
  required String tab,
  String? episodeId,
  String title = '',
  Future<List<List<Chapter>>> Function()? loader,
}) async {
  Future<List<Chapter>> fallback() async {
    // An injected loader owns its data source; do not touch platform storage
    // or connectivity behind the back of an offline host/preview.
    if (loader == null) {
      try {
        final local = await HiveDramaDownloadStore.instance.catalogue(seriesId);
        if (local != null) return local.episodes;
      } catch (_) {
        // An unavailable catalogue does not invalidate a standalone video ID.
      }
    }
    return [
      if (episodeId != null && episodeId.isNotEmpty)
        Chapter(
          itemId: episodeId,
          title: title,
          volumeName: '剧集',
          hasKnownIndex: false,
        ),
    ];
  }

  // 不再用 connectivity_plus 的形态结论决定「要不要联网取目录」：后端就在
  // 本机，插件报 none 并不代表拿不到目录（Windows 上它长期报 none）。
  // 先照常请求，失败了再退回本地兜底，文案也才说得准。
  try {
    final volumes =
        await (loader?.call() ??
            ApiClient.instance.directoryChapters(seriesId, tab: tab));
    final episodes = volumes.expand((volume) => volume).toList(growable: false);
    if (episodes.isNotEmpty) return episodes;
  } catch (error) {
    if (error is BackendRequestAborted && !error.timedOut) rethrow;
    final local = await fallback();
    if (local.isNotEmpty) return local;
    rethrow;
  }
  return fallback();
}

class OfflineEpisodeUnavailable extends ApiException {
  const OfflineEpisodeUnavailable() : super('当前离线，此集尚未缓存，请联网后播放或缓存');
}
