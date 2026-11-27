import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../constants/db_keys.dart';
import '../../constants/endpoints.dart';
import '../../constants/enum.dart';
import '../../features/history/presentation/history_controller.dart';
import '../../features/manga_book/data/manga_book/manga_book_repository.dart';
import '../../features/manga_book/domain/chapter/chapter_model.dart';
import '../../features/manga_book/domain/chapter/graphql/__generated__/fragment.graphql.dart';
import '../../features/manga_book/domain/chapter_batch/chapter_batch_model.dart';
import '../../features/manga_book/domain/manga/manga_model.dart';
import '../../features/manga_book/presentation/manga_details/controller/manga_details_controller.dart';
import '../../features/settings/presentation/server/widget/client/server_port_tile/server_port_tile.dart';
import '../../features/settings/presentation/server/widget/client/server_url_tile/server_url_tile.dart';
import '../../features/settings/presentation/server/widget/credential_popup/credentials_popup.dart';
import '../../global_providers/global_providers.dart';
import '../logger/operation_log.dart';
import 'token_manager.dart';

String? readingAccount(AuthType type, String? token, String? credentials) {
  try {
    if (type == AuthType.none) return 'anonymous';
    if (type == AuthType.uiLogin) {
      final parts = (token ?? '').split('.');
      if (parts.length != 3) return null;
      final json = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      final subject = json is Map ? json['sub'] : null;
      final id = int.tryParse(subject?.toString() ?? '');
      return id != null && id > 0 ? 'user_$id' : null;
    }
    if (credentials?.startsWith('Basic ') != true) return null;
    final decoded = utf8.decode(base64.decode(credentials!.substring(6)));
    final split = decoded.indexOf(':');
    return split > 0 ? 'basic_${decoded.substring(0, split)}' : null;
  } on FormatException {
    return null;
  }
}

final readingProgressScopeProvider = Provider<String?>((ref) {
  final type = ref.watch(authTypeKeyProvider) ?? DBKeys.authType.initial;
  final account = ref.watch(uiLoginAccessTokenProvider
      .select((token) => readingAccount(type, token, null)));
  final credentialsAccount = ref.watch(credentialsProvider
      .select((credentials) => readingAccount(type, null, credentials)));
  final identity = type == AuthType.basic ? credentialsAccount : account;
  final server = ref.watch(serverUrlProvider);
  if (identity == null ||
      server == null ||
      server == DBKeys.serverUrl.initial) {
    return null;
  }
  final endpoint = Endpoints.baseApi(
    baseUrl: server,
    port: ref.watch(serverPortProvider),
    addPort: ref.watch(serverPortToggleProvider) ?? true,
    appendApiToUrl: false,
  );
  return base64Url.encode(utf8.encode('$endpoint\n$identity'));
});

class ReadingProgress {
  const ReadingProgress({
    required this.chapter,
    required this.page,
    required this.pageCount,
    required this.readAtMs,
    required this.pending,
    this.serverBase,
  });

  final ChapterDto chapter;
  final int page;
  final int pageCount;
  final int readAtMs;
  final bool pending;
  final ChapterDto? serverBase;

  bool get completed => chapter.isRead || page >= pageCount - 1;

  ReadingProgress withServer(ChapterDto server, {required bool pending}) =>
      ReadingProgress(
          chapter: chapter,
          page: page,
          pageCount: pageCount,
          readAtMs: readAtMs,
          pending: pending,
          serverBase: server);

  Map<String, dynamic> toJson() => {
        'chapter': chapter.toJson(),
        'page': page,
        'pageCount': pageCount,
        'readAtMs': readAtMs,
        'pending': pending,
        if (serverBase != null) 'serverBase': serverBase!.toJson(),
      };

  factory ReadingProgress.fromJson(Map<String, dynamic> json) {
    final progress = ReadingProgress(
      chapter: chapterFromJson(json['chapter'] as Map<String, dynamic>),
      page: json['page'] as int,
      pageCount: json['pageCount'] as int,
      readAtMs: json['readAtMs'] as int,
      pending: json['pending'] as bool,
      serverBase: json['serverBase'] == null
          ? null
          : chapterFromJson(json['serverBase'] as Map<String, dynamic>),
    );
    if (progress.page < 0 ||
        progress.pageCount <= progress.page ||
        progress.readAtMs <= 0) {
      throw const FormatException('Invalid reading progress');
    }
    return progress;
  }
}

int chapterReadAtMs(ChapterDto? chapter) =>
    (int.tryParse(chapter?.lastReadAt ?? '') ?? 0) * 1000;

bool sameReading(ChapterDto? a, ChapterDto? b) =>
    a != null &&
    b != null &&
    a.id == b.id &&
    a.url == b.url &&
    a.lastReadAt == b.lastReadAt &&
    a.lastPageRead == b.lastPageRead &&
    a.isRead == b.isRead;

bool useLocalReading(ReadingProgress? local, ChapterDto? server) =>
    local != null &&
    (chapterReadAtMs(server) <= local.readAtMs ||
        sameReading(server, local.serverBase));

/// One latest position per manga, isolated by server and signed-in account.
class ReadingProgressController extends Notifier<Map<int, ReadingProgress>> {
  String? _scope;
  int _epoch = 0;
  bool _foreground = true;
  Timer? _debounce;
  Timer? _retry;
  Future<void> _writes = Future.value();
  Future<void>? _sync;
  bool _again = false;
  bool _disposed = false;
  final _pendingChapters = <int, ReadingProgress>{};

  @override
  Map<int, ReadingProgress> build() {
    _disposed = false;
    _scope = ref.watch(readingProgressScopeProvider);
    _pendingChapters.clear();
    _epoch++;
    _debounce?.cancel();
    _retry?.cancel();
    ref.onDispose(() {
      _disposed = true;
      _epoch++;
      _debounce?.cancel();
      _retry?.cancel();
    });
    if (_scope == null) return {};
    final raw = ref
        .read(sharedPreferencesProvider)
        .getString('reading_progress_v1_$_scope');
    if (raw == null) return {};
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final entries = <int, ReadingProgress>{};
      for (final entry in data.entries) {
        if (entry.key == '_pending') continue;
        final id = int.parse(entry.key);
        final progress =
            ReadingProgress.fromJson(entry.value as Map<String, dynamic>);
        if (id != progress.chapter.mangaId ||
            (progress.serverBase != null &&
                progress.serverBase!.mangaId != id)) {
          throw const FormatException('Inconsistent reading journal');
        }
        entries[id] = progress;
      }
      final pending = data['_pending'];
      if (pending == null) {
        for (final progress in entries.values.where((p) => p.pending)) {
          _pendingChapters[progress.chapter.id] = progress;
        }
      } else {
        for (final entry in (pending as Map<String, dynamic>).entries) {
          final progress =
              ReadingProgress.fromJson(entry.value as Map<String, dynamic>);
          if (int.parse(entry.key) != progress.chapter.id ||
              !progress.pending ||
              !entries.containsKey(progress.chapter.mangaId)) {
            throw const FormatException('Inconsistent pending journal');
          }
          _pendingChapters[progress.chapter.id] = progress;
        }
      }
      return entries;
    } catch (error, stackTrace) {
      OperationLog.instance.record('ReadingProgress',
          outcome: 'storage_invalid', error: error, stackTrace: stackTrace);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  int startingPage(ChapterDto chapter) {
    final local = state[chapter.mangaId];
    if (local?.chapter.id == chapter.id &&
        local?.chapter.url == chapter.url &&
        useLocalReading(local, chapter)) {
      return local!.page;
    }
    return chapter.lastPageRead;
  }

  Future<void> record(ChapterDto chapter, int page, int pageCount,
      {ChapterDto? serverLatest, String? expectedScope}) async {
    if (_scope == null) {
      throw StateError('Reading progress account is not configured');
    }
    if (pageCount <= 0 || page < 0 || page >= pageCount) {
      throw ArgumentError('Invalid reading position');
    }
    if (expectedScope != null && expectedScope != _scope) {
      throw StateError('Reading account changed');
    }
    final epoch = _epoch;
    final previous = state[chapter.mangaId];
    final completedHere = previous?.chapter.id == chapter.id &&
        previous?.chapter.url == chapter.url &&
        previous!.completed;
    final progress = ReadingProgress(
      chapter: completedHere && !chapter.isRead
          ? chapter.copyWith(user: chapter.user.copyWith(isRead: true))
          : chapter,
      page: page,
      pageCount: pageCount,
      readAtMs: max(
          DateTime.now().millisecondsSinceEpoch, (previous?.readAtMs ?? 0) + 1),
      pending: true,
      serverBase:
          chapterReadAtMs(serverLatest) > chapterReadAtMs(previous?.serverBase)
              ? serverLatest
              : previous?.serverBase ?? serverLatest,
    );
    state = {...state, chapter.mangaId: progress};
    _pendingChapters[chapter.id] = progress;
    _again = true;
    await _persist();
    if (_disposed || epoch != _epoch) return;
    _debounce?.cancel();
    if (_foreground) {
      _debounce = Timer(const Duration(seconds: 2), () => unawaited(flush()));
    }
  }

  Future<void> _persist() {
    final prefs = ref.read(sharedPreferencesProvider);
    final key = 'reading_progress_v1_$_scope';
    final value = jsonEncode({
      for (final entry in state.entries) '${entry.key}': entry.value.toJson(),
      '_pending': {
        for (final entry in _pendingChapters.entries)
          '${entry.key}': entry.value.toJson(),
      },
    });
    final write = _writes.then((_) async {
      if (!await prefs.setString(key, value)) {
        throw StateError('Reading progress could not be persisted');
      }
    });
    _writes =
        write.then<void>((_) {}, onError: (Object error, StackTrace stack) {
      OperationLog.instance.record('ReadingProgress',
          outcome: 'storage_failed', error: error, stackTrace: stack);
    });
    return write;
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    _debounce?.cancel();
    _retry?.cancel();
    unawaited(flush());
  }

  Future<void> discardChapters(Set<int> chapterIds) async {
    await _sync;
    _pendingChapters.removeWhere((id, _) => chapterIds.contains(id));
    final remaining = {
      for (final entry in state.entries)
        if (!chapterIds.contains(entry.value.chapter.id))
          entry.key: entry.value,
    };
    for (final progress in _pendingChapters.values) {
      if (progress.readAtMs >
          (remaining[progress.chapter.mangaId]?.readAtMs ?? 0)) {
        remaining[progress.chapter.mangaId] = progress;
      }
    }
    state = remaining;
    await _persist();
  }

  Future<void> flush() {
    _debounce?.cancel();
    _retry?.cancel();
    return _sync ??= _flush().whenComplete(() {
      _sync = null;
      if (!_disposed &&
          _foreground &&
          _scope != null &&
          _pendingChapters.isNotEmpty) {
        _retry = Timer(const Duration(seconds: 30), () => unawaited(flush()));
      }
    });
  }

  Future<void> _flush() async {
    final epoch = _epoch;
    final scope = _scope;
    if (scope == null) return;
    bool active() =>
        !_disposed &&
        epoch == _epoch &&
        ref.read(readingProgressScopeProvider) == scope;
    try {
      await _writes;
      do {
        _again = false;
        final pending = _pendingChapters.values.toList()
          ..sort((a, b) => a.readAtMs.compareTo(b.readAtMs));
        for (final saved in pending) {
          if (!active()) return;
          final progress = _pendingChapters[saved.chapter.id];
          if (progress == null) continue;
          final mangaId = progress.chapter.mangaId;
          final books = ref.read(mangaBookRepositoryProvider);
          final manga = await books.getMangaFromServer(mangaId: mangaId);
          if (!active()) return;
          if (_pendingChapters[progress.chapter.id]?.readAtMs !=
              progress.readAtMs) {
            _again = true;
            continue;
          }
          if (manga == null) throw StateError('Manga progress is unavailable');
          final remote = manga.lastReadChapter;
          if (!useLocalReading(progress, remote)) {
            _pendingChapters.remove(progress.chapter.id);
            final latest = state[mangaId]!;
            if (!useLocalReading(latest, remote)) {
              _pendingChapters.removeWhere((_, value) =>
                  value.chapter.mangaId == mangaId &&
                  value.readAtMs < chapterReadAtMs(remote));
              state = {
                ...state,
                mangaId: ReadingProgress(
                  chapter: remote!,
                  page: max(0, remote.lastPageRead),
                  pageCount: max(remote.pageCount, remote.lastPageRead + 1),
                  readAtMs: chapterReadAtMs(remote),
                  pending: false,
                  serverBase: remote,
                )
              };
            } else {
              state = {
                ...state,
                mangaId: latest.withServer(remote!,
                    pending: _pendingChapters.values
                        .any((p) => p.chapter.mangaId == mangaId))
              };
            }
            await _persist();
            OperationLog.instance.record('ReadingProgress',
                outcome: 'server_newer',
                mangaId: mangaId,
                chapterId: remote.id);
            ref.invalidate(mangaWithIdProvider(mangaId: mangaId));
            continue;
          }
          final fresh =
              await books.getChapterFromServer(chapterId: progress.chapter.id);
          if (!active()) return;
          if (fresh == null ||
              fresh.mangaId != mangaId ||
              fresh.url != progress.chapter.url) {
            throw StateError('Reading chapter no longer matches the server');
          }
          if (_pendingChapters[progress.chapter.id]?.readAtMs !=
              progress.readAtMs) {
            _again = true;
            continue;
          }
          final result = await books.putChapter(
            chapterId: progress.chapter.id,
            patch: ChapterChange(
                lastPageRead: progress.page, isRead: progress.completed),
          );
          if (!active()) return;
          if (result == null) {
            throw StateError('Reading progress was not acknowledged');
          }
          if (result.id != progress.chapter.id ||
              result.mangaId != mangaId ||
              result.url != progress.chapter.url ||
              result.lastPageRead != progress.page ||
              result.isRead != progress.completed) {
            throw StateError(
                'Server acknowledged a different reading position');
          }
          final latest = state[mangaId]!;
          if (_pendingChapters[progress.chapter.id]?.readAtMs ==
              progress.readAtMs) {
            _pendingChapters.remove(progress.chapter.id);
          }
          for (final entry in _pendingChapters.entries.toList()) {
            if (entry.value.chapter.mangaId == mangaId) {
              _pendingChapters[entry.key] =
                  entry.value.withServer(result, pending: true);
            }
          }
          state = {
            ...state,
            mangaId: latest.withServer(result,
                pending: _pendingChapters.values
                    .any((p) => p.chapter.mangaId == mangaId))
          };
          await _persist();
          OperationLog.instance.record('ReadingProgress',
              outcome: 'synced', mangaId: mangaId, chapterId: result.id);
          ref.invalidate(readingHistoryProvider);
          ref.invalidate(mangaWithIdProvider(mangaId: mangaId));
          final chapterList = mangaChapterListProvider(mangaId: mangaId);
          if (ref.read(chapterList).valueOrNull != null) {
            ref.read(chapterList.notifier).updateChapters([result]);
          }
        }
      } while (_again && active());
    } catch (error, stackTrace) {
      if (!active()) return;
      OperationLog.instance.record('ReadingProgress',
          outcome: 'pending_retry', error: error, stackTrace: stackTrace);
    }
  }
}

final readingProgressProvider =
    NotifierProvider<ReadingProgressController, Map<int, ReadingProgress>>(
        ReadingProgressController.new);
