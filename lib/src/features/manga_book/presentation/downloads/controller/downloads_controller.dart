import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../../utils/logger/operation_log.dart';
import '../../../data/downloads/downloads_repository.dart';
import '../../../domain/downloads/downloads_model.dart';
import '../../../domain/downloads/graphql/__generated__/fragment.graphql.dart';
import '../../../domain/downloads_queue/downloads_queue_model.dart';

part 'downloads_controller.g.dart';

@riverpod
Stream<DownloadUpdatesDto?> downloadUpdates(Ref ref) {
  final diagnostics = ref.watch(serverDownloadDiagnosticsProvider);
  return ref
      .watch(downloadsRepositoryProvider)
      .downloadStatusSubscription()
      .map((updates) {
    diagnostics.subscription(updates);
    return updates;
  });
}

@riverpod
Future<DownloadStatusDto?> downloadStatus(Ref ref) async {
  final diagnostics = ref.watch(serverDownloadDiagnosticsProvider);
  final status =
      await ref.watch(downloadsRepositoryProvider).getDownloadStatus();
  diagnostics.snapshot(status);
  return status;
}

/// Shared by the root subscription, HTTP refreshes and the existing fallback.
/// A successful HTTP request accepts work; only downloader states describe its
/// result. DownloadType has no source exception or failure-message field.
final serverDownloadDiagnosticsProvider = Provider((ref) {
  ref.watch(downloadsRepositoryProvider);
  return ServerDownloadDiagnostics();
});

class ServerDownloadDiagnostics {
  ServerDownloadDiagnostics({OperationLog? log})
      : _log = log ?? OperationLog.instance;

  final OperationLog _log;
  final _last = <(int, int), ({String state, int attempt, int bucket})>{};

  void subscription(DownloadUpdatesDto? updates) {
    for (final download in [...?updates?.initial]) {
      observe(download);
    }
    for (final update in [...?updates?.updates]) {
      observe(update.download, event: update.type);
    }
  }

  void snapshot(DownloadStatusDto? status) {
    for (final download in [...?status?.queue]) {
      observe(download);
    }
    // Absence from a snapshot does not prove completion (it may be removal).
  }

  void observe(DownloadDto download, {DownloadUpdateType? event}) {
    final state = switch (event) {
      DownloadUpdateType.FINISHED => 'FINISHED',
      DownloadUpdateType.DEQUEUED => 'DEQUEUED',
      DownloadUpdateType.ERROR => 'ERROR',
      DownloadUpdateType.QUEUED => 'QUEUED',
      DownloadUpdateType.PAUSED => 'PAUSED',
      DownloadUpdateType.STOPPED => 'STOPPED',
      _ => download.state.name,
    };
    final percent = download.progress.isFinite
        ? (download.progress * 100).round().clamp(0, 100)
        : 0;
    final bucket = percent ~/ 25;
    final key = (download.manga.id, download.chapter.id);
    final previous = _last[key];
    if (previous != null &&
        previous.state == state &&
        previous.attempt == download.tries &&
        (state != 'DOWNLOADING' || bucket <= previous.bucket)) {
      return;
    }
    _last[key] = (state: state, attempt: download.tries, bucket: bucket);
    _log.record(
      'ServerChapterDownload',
      stage: 'server_download',
      outcome: switch (state) {
        'ERROR' => 'failed',
        'FINISHED' => 'completed',
        'DEQUEUED' => 'dequeued',
        _ => 'observed',
      },
      mangaId: download.manga.id,
      chapterId: download.chapter.id,
      state: state,
      attempt: download.tries,
      progressPercent: percent,
      reasonCode: state == 'ERROR' ? 'server_reason_unavailable' : null,
    );
  }
}

final downloadStatusFallbackProvider =
    StreamProvider.autoDispose<DownloadStatusDto?>((ref) {
  final subscription = ref.watch(downloadUpdatesProvider);
  if (!subscription.hasError) return const Stream.empty();
  final repository = ref.read(downloadsRepositoryProvider);
  final diagnostics = ref.watch(serverDownloadDiagnosticsProvider);
  return Stream.periodic(const Duration(seconds: 5))
      .asyncMap((_) => repository.getDownloadStatus())
      .map((status) {
    diagnostics.snapshot(status);
    return status;
  });
});

@riverpod
class DownloadsMap extends _$DownloadsMap {
  void updateDownloadStatus(Fragment$DownloadUpdatesDto? downloadStatusDto) {
    final currState = {...?stateOrNull};
    for (final element in [...?downloadStatusDto?.initial]) {
      currState[element.chapter.id] = element;
    }
    for (final element in [...?downloadStatusDto?.updates]) {
      switch (element.type) {
        case DownloadUpdateType.DEQUEUED:
        case DownloadUpdateType.FINISHED:
          currState.remove(element.download.chapter.id);
          break;
        case DownloadUpdateType.QUEUED:
        case DownloadUpdateType.PROGRESS:
        case DownloadUpdateType.POSITION:
        case DownloadUpdateType.PAUSED:
        case DownloadUpdateType.ERROR:
        case DownloadUpdateType.STOPPED:
          currState[element.download.chapter.id] = element.download;
          break;
        case DownloadUpdateType.$unknown:
          throw UnimplementedError();
      }
    }
    if (stateOrNull != null) {
      state = currState;
    }
  }

  @override
  Map<int, DownloadDto> build() {
    ref.listen(
      downloadUpdatesProvider,
      (_, next) => updateDownloadStatus(next.valueOrNull),
    );
    ref.listen(
      downloadStatusProvider,
      (_, next) {
        final downloadStatus = next.valueOrNull;
        if (downloadStatus != null) {
          state = getStateFromUpdates(downloadStatus);
        }
      },
    );
    ref.listen(
      downloadStatusFallbackProvider,
      (_, next) {
        final downloadStatus = next.valueOrNull;
        if (downloadStatus != null) {
          state = getStateFromUpdates(downloadStatus);
        }
      },
    );
    return getStateFromUpdates(ref.read(downloadStatusProvider).valueOrNull);
  }

  Map<int, DownloadDto> getStateFromUpdates(
      DownloadStatusDto? downloadStatusDto) {
    final downloadsMap = <int, DownloadDto>{};
    for (final element in [...?downloadStatusDto?.queue]) {
      downloadsMap[element.chapter.id] = element;
    }
    return downloadsMap;
  }

  Future<void> reorder(int chapterId, int to) async {
    final downloadStatusDto = await ref
        .read(downloadsRepositoryProvider)
        .reorderDownload(chapterId, to);
    ref.read(serverDownloadDiagnosticsProvider).snapshot(downloadStatusDto);
    state = getStateFromUpdates(downloadStatusDto);
  }

  Future<void> refresh() async {
    ref.invalidate(downloadStatusProvider);
    final downloadStatus = await ref.read(downloadStatusProvider.future);
    state = getStateFromUpdates(downloadStatus);
  }
}

@riverpod
DownloadDto? downloadsFromId(Ref ref, int chapterId) =>
    ref.watch(downloadsMapProvider.select((map) => map[chapterId]));

@riverpod
List<int> downloadsChapterIds(Ref ref) {
  final downloads = ref.watch(downloadsMapProvider).values.toList();
  downloads.sort((a, b) => a.position.compareTo(b.position));
  return downloads.map((d) => d.chapter.id).toList();
}

@riverpod
AsyncValue<DownloaderState?> downloaderState(Ref ref) {
  final subscription = ref.watch(downloadUpdatesProvider);
  if (!subscription.hasError) {
    final subscriptionState = subscription.valueOrNull?.state;
    if (subscriptionState != null) {
      return AsyncData(subscriptionState);
    }
  }

  final fallbackState =
      ref.watch(downloadStatusFallbackProvider).valueOrNull?.state;
  if (fallbackState != null) {
    return AsyncData(fallbackState);
  }

  final httpStatus = ref.watch(downloadStatusProvider);
  final httpState = httpStatus.valueOrNull?.state;
  if (httpState != null) {
    return AsyncData(httpState);
  }
  if (httpStatus.hasError) {
    return AsyncError(httpStatus.error!, httpStatus.stackTrace!);
  }
  return const AsyncLoading();
}

@riverpod
bool showDownloadsFAB(Ref ref) {
  final downloaderState = ref.watch(downloaderStateProvider).valueOrNull;
  final downloads = ref.watch(downloadsMapProvider).values;
  return downloaderState == DownloaderState.STARTED ||
      downloads.any(
        (download) =>
            download.state != DownloadState.ERROR || download.tries != 3,
      );
}
