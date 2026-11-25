// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../constants/endpoints.dart';
import '../../features/settings/presentation/server/widget/client/server_port_tile/server_port_tile.dart';
import '../../features/settings/presentation/server/widget/client/server_url_tile/server_url_tile.dart';
import '../../global_providers/global_providers.dart';
import '../extensions/custom_extensions.dart';
import '../logger/operation_log.dart';
import 'auth_http_client.dart';

part 'offline_chapter_manager.g.dart';

/// Machine-readable cache failure. Messages/URLs from [cause] must never be
/// rendered or exported; the operation logger only receives its runtime type.
class LocalCacheException implements Exception {
  const LocalCacheException(
    this.reasonCode, {
    this.cause,
    this.stackTrace,
    this.httpStatus,
    this.completedPages,
    this.totalPages,
  });

  final String reasonCode;
  final Object? cause;
  final StackTrace? stackTrace;
  final int? httpStatus;
  final int? completedPages;
  final int? totalPages;
}

String localCacheFailureReason(Object error) => switch (error) {
      LocalCacheException() => error.reasonCode,
      FileSystemException() => 'disk_error',
      SocketException() ||
      HttpException() ||
      HandshakeException() ||
      TimeoutException() ||
      http.ClientException() =>
        'network_error',
      _ => 'cache_failure',
    };

/// Tracks local download progress for chapters
class LocalDownloadProgress {
  final int chapterId;
  final int mangaId;
  final int totalPages;
  final int downloadedPages;
  final bool isComplete;
  final String? error;
  final Object? cause;
  final StackTrace? stackTrace;
  final String? reasonCode;
  final int? httpStatus;
  final bool alreadyCached;

  const LocalDownloadProgress({
    required this.chapterId,
    required this.mangaId,
    required this.totalPages,
    required this.downloadedPages,
    required this.isComplete,
    this.error,
    this.cause,
    this.stackTrace,
    this.reasonCode,
    this.httpStatus,
    this.alreadyCached = false,
  });

  double get progress => totalPages > 0 ? downloadedPages / totalPages : 0.0;
}

/// Manages local chapter downloads for offline reading.
/// Stores chapter pages as image files in app documents.
class OfflineChapterManager {
  OfflineChapterManager(this._ref,
      {Future<Directory> Function()? documentsDirectory})
      : _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory;

  final Ref _ref;
  final Future<Directory> Function() _documentsDirectory;

  static const _metadataKey = 'offline_chapters_metadata';
  static final _random = Random.secure();

  String _newGeneration() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';

  // Deliberately outside offline_manga: deleting images must not delete user
  // intent. Generations also invalidate writers already running in another
  // Flutter engine, without relying on process-local preferences or locks.
  Future<Directory> _getStateDir() async {
    final appDir = await _documentsDirectory();
    return Directory(p.join(appDir.path, 'offline_manga_state'))
        .create(recursive: true);
  }

  Future<File> _chapterStateFile(int mangaId, int chapterId) async =>
      File(p.join((await _getStateDir()).path, '${mangaId}_$chapterId.json'));

  Future<Map<String, dynamic>?> _readJson(File file) async {
    try {
      return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    } on FileSystemException {
      if (!await file.exists()) return null; // Concurrent removal is a miss.
      rethrow;
    }
  }

  Future<void> _atomicWrite(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final temporary = await target.parent.createTemp('.pending-');
    try {
      final file = File(p.join(temporary.path, 'body'));
      await file.writeAsBytes(bytes, flush: true);
      await file.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  }

  Future<void> _writeJson(File file, Map<String, dynamic> value) =>
      _atomicWrite(file, utf8.encode(jsonEncode(value)));

  Future<({String epoch, String revision, bool excluded, bool clearing})>
      _state(int mangaId, int chapterId) async {
    final global = await _readJson(
        File(p.join((await _getStateDir()).path, 'clear.json')));
    final chapter = await _readJson(await _chapterStateFile(mangaId, chapterId));
    return (
      epoch: global?['generation'] as String? ?? 'legacy',
      revision: chapter?['generation'] as String? ?? 'legacy',
      excluded: chapter?['excluded'] == true,
      clearing: global?['clearing'] == true,
    );
  }

  /// Persistent user removal, shared with foreground and headless engines.
  Future<bool> isAutomaticallyExcluded(int mangaId, int chapterId) async {
    final state = await _state(mangaId, chapterId);
    return state.excluded || state.clearing;
  }

  /// Call only for an explicit user save, never for hourly catch-up.
  Future<void> allowAutomaticCache(int mangaId, int chapterId) async {
    final file = await _chapterStateFile(mangaId, chapterId);
    final state = await _readJson(file);
    if (state?['excluded'] != true) return;
    await _writeJson(file, {
      'generation': _newGeneration(),
      'excluded': false,
    });
  }

  String _manifestName(String epoch, String revision) =>
      'complete-$epoch-$revision.json';

  /// Get the base directory for offline manga storage
  Future<Directory> _getBaseDir() async {
    final appDir = await _documentsDirectory();
    final dir = Directory(p.join(appDir.path, 'offline_manga'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Get directory for a specific chapter's pages
  Future<Directory> _getChapterDir(int mangaId, int chapterId) async {
    final baseDir = await _getBaseDir();
    final dir = Directory(p.join(baseDir.path, '$mangaId', '$chapterId'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Build base API URL (without /api/v1 since page URLs already include it)
  String _buildBaseApi() {
    return Endpoints.baseApi(
      baseUrl: _ref.read(serverUrlProvider) ?? 'http://127.0.0.1',
      port: _ref.read(serverPortProvider),
      addPort: _ref.read(serverPortToggleProvider).ifNull(),
      appendApiToUrl: false,
    );
  }

  /// Download all pages of a chapter locally.
  /// [pageUrls] should be the list of page URL paths from fetchChapterPages.
  Stream<LocalDownloadProgress> downloadChapter({
    required int mangaId,
    required int chapterId,
    required List<String> pageUrls,
    bool logDiagnostics = true,
  }) async* {
    final totalPages = pageUrls.length;
    var downloadedPages = 0;
    int? httpStatus;
    Directory? attemptPages;
    var published = false;
    // Queue callers already log their attempts, retries and final validation.
    // Direct manual saves still need diagnostics, without duplicate events.
    void record(String outcome,
        {String? reasonCode,
        Object? error,
        StackTrace? stackTrace,
        int? completedPages}) {
      if (!logDiagnostics) return;
      OperationLog.instance.record(
        'OfflineChapterCache',
        stage: 'device_cache',
        outcome: outcome,
        mangaId: mangaId,
        chapterId: chapterId,
        attempt: 1,
        reasonCode: reasonCode,
        httpStatus: httpStatus,
        completedPages: completedPages ?? downloadedPages,
        totalPages: totalPages,
        error: error,
        stackTrace: stackTrace,
      );
    }

    record('started');
    try {
      final initial = await _state(mangaId, chapterId);
      Future<void> checkAllowed() async {
        final current = await _state(mangaId, chapterId);
        if (current.clearing || current.epoch != initial.epoch) {
          throw const LocalCacheException('cache_cleared');
        }
        if (current.excluded) {
          throw const LocalCacheException('cache_excluded');
        }
        if (current != initial) {
          throw const LocalCacheException('cache_removed');
        }
      }

      await checkAllowed();
      if (totalPages == 0) throw const LocalCacheException('empty_pages');
      final existing = await getOfflinePages(mangaId, chapterId);
      if (existing?.length == totalPages) {
        await checkAllowed();
        record('already_on_device',
            reasonCode: 'already_on_device', completedPages: totalPages);
        yield LocalDownloadProgress(
          chapterId: chapterId,
          mangaId: mangaId,
          totalPages: totalPages,
          downloadedPages: totalPages,
          isComplete: true,
          alreadyCached: true,
        );
        return;
      }
      final chapterDir = await _getChapterDir(mangaId, chapterId);
      // Each attempt owns immutable pages. Concurrent engines cannot mix page
      // sets or overwrite pages referenced by a published completion manifest.
      final pages = await chapterDir.createTemp('pages-');
      attemptPages = pages;
      final baseApi = _buildBaseApi();
      for (int i = 0; i < totalPages; i++) {
        await checkAllowed();
        final url = '$baseApi${pageUrls[i]}';
        httpStatus = null;
        final response =
            await _ref.read(serverMediaHttpClientProvider).get(Uri.parse(url));
        httpStatus = response.statusCode;
        if (response.statusCode != 200) {
          throw LocalCacheException('http_status',
              httpStatus: response.statusCode);
        }
        if (response.bodyBytes.isEmpty) {
          throw const LocalCacheException('empty_page');
        }
        final expectedLength =
            int.tryParse(response.headers['content-length'] ?? '');
        // IOClient may have decompressed the body while retaining the wire
        // Content-Length. Stream errors still reject interrupted bodies.
        final encoding = response.headers['content-encoding'];
        if (expectedLength != null &&
            (encoding == null || encoding == 'identity') &&
            expectedLength != response.bodyBytes.length) {
          throw const LocalCacheException('incomplete_page');
        }
        await checkAllowed();
        await _atomicWrite(
            File(p.join(pages.path, '$i.jpg')), response.bodyBytes);
        await checkAllowed();
        downloadedPages = i + 1;
        if (downloadedPages < totalPages) {
          yield LocalDownloadProgress(
            chapterId: chapterId,
            mangaId: mangaId,
            totalPages: totalPages,
            downloadedPages: downloadedPages,
            isComplete: false,
          );
        }
      }

      await checkAllowed();
      await _writeJson(
          File(p.join(chapterDir.path,
              _manifestName(initial.epoch, initial.revision))),
          {
            'mangaId': mangaId,
            'chapterId': chapterId,
            'pageCount': totalPages,
            'pagesDirectory': p.basename(pages.path),
            'downloadedAt': DateTime.now().toIso8601String(),
          });
      published = true;
      await checkAllowed();
      record('completed');
      yield LocalDownloadProgress(
        chapterId: chapterId,
        mangaId: mangaId,
        totalPages: totalPages,
        downloadedPages: totalPages,
        isComplete: true,
      );
    } catch (error, stackTrace) {
      // Surface a safe error, never a URL, authentication detail or raw body.
      record('failed',
          reasonCode: localCacheFailureReason(error),
          error: error,
          stackTrace: stackTrace);
      yield LocalDownloadProgress(
        chapterId: chapterId,
        mangaId: mangaId,
        totalPages: totalPages,
        downloadedPages: downloadedPages,
        isComplete: false,
        error: 'Offline cache failed',
        cause: error,
        stackTrace: stackTrace,
        reasonCode: localCacheFailureReason(error),
        httpStatus: httpStatus,
      );
    } finally {
      // Only remove this attempt's unpublished, app-owned directory. A killed
      // process may leave one behind, but it can never count as a completion.
      if (!published && attemptPages != null && await attemptPages.exists()) {
        await attemptPages.delete(recursive: true);
      }
    }
  }

  /// Check if a chapter is available offline
  Future<bool> isChapterAvailableOffline(int mangaId, int chapterId) async {
    return await getOfflinePages(mangaId, chapterId) != null;
  }

  /// Get local page files for a chapter (for offline reading)
  Future<List<File>?> getOfflinePages(int mangaId, int chapterId) async {
    final state = await _state(mangaId, chapterId);
    if (state.excluded || state.clearing) return null;
    final chapterDir = Directory(
        p.join((await _getBaseDir()).path, '$mangaId', '$chapterId'));
    var metadata = await _readJson(File(p.join(
        chapterDir.path, _manifestName(state.epoch, state.revision))));
    var pagesPath = chapterDir.path;
    if (metadata != null) {
      final name = metadata['pagesDirectory'];
      if (name is! String ||
          !RegExp(r'^pages-[a-zA-Z0-9_-]+$').hasMatch(name)) {
        return null;
      }
      pagesPath = p.join(chapterDir.path, name);
    } else if (state.epoch == 'legacy' && state.revision == 'legacy') {
      metadata = (await _getMetadata())['${mangaId}_$chapterId'];
    }
    final pageCount = metadata?['pageCount'];
    if (pageCount is! int || pageCount <= 0) return null;
    final files = <File>[];
    for (var i = 0; i < pageCount; i++) {
      final file = File(p.join(pagesPath, '$i.jpg'));
      try {
        if (await file.length() == 0) return null;
      } on FileSystemException {
        if (!await file.exists()) return null;
        rethrow;
      }
      files.add(file);
    }
    return await _state(mangaId, chapterId) == state ? files : null;
  }

  /// Delete a locally downloaded chapter
  Future<void> deleteOfflineChapter(int mangaId, int chapterId) async {
    await _writeJson(await _chapterStateFile(mangaId, chapterId), {
      'generation': _newGeneration(),
      'excluded': true,
    });
    final chapterDir = await _getChapterDir(mangaId, chapterId);
    if (await chapterDir.exists()) {
      await chapterDir.delete(recursive: true);
    }
  }

  /// Get list of all offline chapter IDs for a manga
  Future<List<int>> getOfflineChapterIds(int mangaId) async {
    final metadata = await _getMetadata();
    final ids = metadata.entries
        .where((e) => e.key.startsWith('${mangaId}_'))
        .map((e) => e.value['chapterId'] as int)
        .toSet();
    final mangaDir =
        Directory(p.join((await _getBaseDir()).path, '$mangaId'));
    if (await mangaDir.exists()) {
      await for (final entity in mangaDir.list(followLinks: false)) {
        final id = int.tryParse(p.basename(entity.path));
        if (entity is Directory && id != null) ids.add(id);
      }
    }
    final available = <int>[];
    for (final id in ids) {
      if (await isChapterAvailableOffline(mangaId, id)) available.add(id);
    }
    return available;
  }

  /// Get total offline storage size in bytes
  Future<int> getOfflineStorageSize() async {
    final baseDir = await _getBaseDir();
    if (!await baseDir.exists()) return 0;
    int totalSize = 0;
    await for (final entity in baseDir.list(recursive: true)) {
      if (entity is File) {
        totalSize += await entity.length();
      }
    }
    return totalSize;
  }

  /// Delete all offline data
  Future<void> clearAllOfflineData() async {
    final clearFile = File(p.join((await _getStateDir()).path, 'clear.json'));
    await _writeJson(clearFile, {
      'generation': _newGeneration(),
      'clearing': true,
    });
    // Fail closed if interrupted: a subsequent successful clear can release
    // the barrier. A second generation invalidates every pre-clear writer.
    final baseDir = await _getBaseDir();
    final chapters = <(int, int)>{};
    for (final value in (await _getMetadata()).values) {
      chapters.add((value['mangaId'] as int, value['chapterId'] as int));
    }
    await for (final manga in baseDir.list(followLinks: false)) {
      final mangaId = int.tryParse(p.basename(manga.path));
      if (manga is! Directory || mangaId == null) continue;
      await for (final chapter in manga.list(followLinks: false)) {
        final chapterId = int.tryParse(p.basename(chapter.path));
        if (chapter is Directory && chapterId != null) {
          chapters.add((mangaId, chapterId));
        }
      }
    }
    for (final (mangaId, chapterId) in chapters) {
      await deleteOfflineChapter(mangaId, chapterId);
    }
    if (await baseDir.exists()) {
      await baseDir.delete(recursive: true);
    }
    await _writeJson(clearFile, {
      'generation': _newGeneration(),
      'clearing': false,
    });
  }

  Future<Map<String, Map<String, dynamic>>> _getMetadata() async {
    final prefs = _ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(_metadataKey);
    if (raw == null) return {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v)));
  }

}

@riverpod
OfflineChapterManager offlineChapterManager(Ref ref) {
  return OfflineChapterManager(ref);
}

/// Provider that checks if a specific chapter is available offline
@riverpod
Future<bool> isChapterOffline(
  Ref ref, {
  required int mangaId,
  required int chapterId,
}) {
  return ref
      .watch(offlineChapterManagerProvider)
      .isChapterAvailableOffline(mangaId, chapterId);
}
