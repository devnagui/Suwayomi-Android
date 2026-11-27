// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
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
      {Future<Directory> Function()? documentsDirectory,
      Future<void> Function(File)? imageValidator,
      Future<int> Function(String)? availableBytes})
      : _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory,
        _imageValidator = imageValidator ?? validateImage,
        _availableBytes = availableBytes ?? _androidAvailableBytes;

  final Ref _ref;
  final Future<Directory> Function() _documentsDirectory;
  final Future<void> Function(File) _imageValidator;
  final Future<int> Function(String) _availableBytes;

  static const maxPageBytes = 32 * 1024 * 1024;
  static const storageReserveBytes = 16 * 1024 * 1024;
  static const _storageChannel = MethodChannel('suwayomi/offline_storage');

  static Future<int> _androidAvailableBytes(String path) async {
    if (!Platform.isAndroid) {
      throw const LocalCacheException('storage_unsupported');
    }
    return queryAndroidAvailableBytes(path);
  }

  static Future<int> queryAndroidAvailableBytes(String path) async {
    try {
      final bytes = await _storageChannel
          .invokeMethod<int>('availableBytes', {'path': path});
      if (bytes == null || bytes < 0) {
        throw const LocalCacheException('storage_unavailable');
      }
      return bytes;
    } on PlatformException catch (error, stack) {
      throw LocalCacheException('storage_unavailable',
          cause: error, stackTrace: stack);
    } on MissingPluginException catch (error, stack) {
      throw LocalCacheException('storage_unavailable',
          cause: error, stackTrace: stack);
    }
  }

  Future<void> _checkSpace(String path, int bytes) async {
    if (await _availableBytes(path) < bytes + storageReserveBytes) {
      throw const LocalCacheException('insufficient_space');
    }
  }

  /// Decode actual image content, not a MIME label or filename. Limit encoded
  /// and decoded memory, and reject truncated envelopes that codecs tolerate.
  static Future<void> validateImage(File file) async {
    final length = await file.length();
    if (length == 0) throw const LocalCacheException('empty_page');
    if (length > maxPageBytes) {
      throw const LocalCacheException('page_too_large');
    }
    final bytes = await file.readAsBytes();
    final data = ByteData.sublistView(bytes);
    bool matches(int offset, List<int> values) =>
        offset >= 0 &&
        offset + values.length <= bytes.length &&
        List.generate(values.length, (i) => bytes[offset + i])
            .asMap()
            .entries
            .every((e) => e.value == values[e.key]);
    final png = matches(0, [137, 80, 78, 71, 13, 10, 26, 10]);
    final jpeg = matches(0, [255, 216]);
    final gif = matches(0, [71, 73, 70, 56]);
    final webp = matches(0, [82, 73, 70, 70]) && matches(8, [87, 69, 66, 80]);
    if (!(png || jpeg || gif || webp)) {
      throw const LocalCacheException('invalid_image');
    }
    if ((png &&
            !matches(bytes.length - 12,
                [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130])) ||
        (jpeg && !matches(bytes.length - 2, [255, 217])) ||
        (gif && bytes.last != 59) ||
        (webp &&
            (bytes.length < 12 ||
                data.getUint32(4, Endian.little) + 8 != bytes.length))) {
      throw const LocalCacheException('incomplete_page');
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width <= 0 ||
          descriptor.height <= 0 ||
          descriptor.width * descriptor.height > 100000000) {
        throw const LocalCacheException('image_dimensions');
      }
      codec = await descriptor.instantiateCodec(
          targetWidth: min(descriptor.width, 512),
          targetHeight: min(descriptor.height, 512));
      if (codec.frameCount > 1000) {
        throw const LocalCacheException('image_frames');
      }
      for (var i = 0; i < codec.frameCount; i++) {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      }
    } on LocalCacheException {
      rethrow;
    } catch (error, stack) {
      throw LocalCacheException('invalid_image',
          cause: error, stackTrace: stack);
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  Future<void> _writePage(File target, Stream<List<int>> stream,
      {required Future<void> Function() checkAllowed,
      int? expectedLength}) async {
    final temporary = File('${target.path}.partial');
    RandomAccessFile? output;
    try {
      await checkAllowed();
      output = await temporary.open(mode: FileMode.write);
      var length = 0;
      await for (final chunk in stream) {
        length += chunk.length;
        if (length > maxPageBytes) {
          throw const LocalCacheException('page_too_large');
        }
        await checkAllowed();
        await _checkSpace(target.parent.path, chunk.length);
        await output.writeFrom(chunk);
      }
      await output.flush();
      await output.close();
      output = null;
      if (length == 0) throw const LocalCacheException('empty_page');
      if (expectedLength != null && expectedLength != length) {
        throw const LocalCacheException('incomplete_page');
      }
      await _imageValidator(temporary);
      await checkAllowed();
      await temporary.rename(target.path);
    } on FileSystemException {
      // A user clear/removal can delete the attempt while IO is pending.
      await checkAllowed();
      rethrow;
    } finally {
      await output?.close();
      if (await temporary.exists()) await temporary.delete();
    }
  }

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
    final chapter =
        await _readJson(await _chapterStateFile(mangaId, chapterId));
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
      final baseApi = _buildBaseApi();
      final existing = await getOfflinePages(mangaId, chapterId);
      final chapterDir = await _getChapterDir(mangaId, chapterId);
      final completion = await _readJson(File(p.join(
          chapterDir.path, _manifestName(initial.epoch, initial.revision))));
      bool sameSequence(Map<String, dynamic> value) =>
          value['baseApi'] == baseApi &&
          jsonEncode(value['pageUrls']) == jsonEncode(pageUrls);
      if (existing?.length == totalPages &&
          (completion?['verified'] != true || sameSequence(completion!))) {
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
      await _checkSpace(chapterDir.path, 0);
      final resumeSources = <Directory>[];
      await for (final entity in chapterDir.list(followLinks: false)) {
        if (entity is! Directory ||
            !RegExp(r'^pages-[a-zA-Z0-9_-]+$')
                .hasMatch(p.basename(entity.path))) {
          continue;
        }
        try {
          final resume =
              await _readJson(File(p.join(entity.path, 'resume.json')));
          if (resume != null &&
              resume['epoch'] == initial.epoch &&
              resume['revision'] == initial.revision &&
              sameSequence(resume)) {
            resumeSources.add(entity);
          }
        } on FormatException {
          // Ambiguous old attempts are never deleted or treated as completed.
        }
      }
      // Each attempt owns immutable pages. Concurrent engines cannot mix page
      // sets or overwrite pages referenced by a published completion manifest.
      final pages = await chapterDir.createTemp('pages-');
      attemptPages = pages;
      await _writeJson(File(p.join(pages.path, 'resume.json')), {
        'epoch': initial.epoch,
        'revision': initial.revision,
        'baseApi': baseApi,
        'pageUrls': pageUrls,
      });
      for (int i = 0; i < totalPages; i++) {
        await checkAllowed();
        final target = File(p.join(pages.path, '$i.jpg'));
        var resumed = false;
        for (final source in resumeSources) {
          final saved = File(p.join(source.path, '$i.jpg'));
          try {
            if (!await saved.exists()) continue;
            await _imageValidator(saved);
            final length = await saved.length();
            if (length <= 0 || length > maxPageBytes) continue;
            await _checkSpace(pages.path, length);
            await _writePage(target, saved.openRead(),
                checkAllowed: checkAllowed, expectedLength: length);
            resumed = true;
            break;
          } on LocalCacheException catch (error) {
            if (![
              'invalid_image',
              'incomplete_page',
              'empty_page',
              'page_too_large',
              'image_dimensions',
              'image_frames',
            ].contains(error.reasonCode)) {
              rethrow;
            }
            record('resume_rejected', reasonCode: error.reasonCode);
          } on FileSystemException {
            if (await saved.exists()) rethrow;
          }
        }
        if (!resumed) {
          // Admission happens before GET, then again before every disk write.
          await _checkSpace(pages.path, 0);
          final url = '$baseApi${pageUrls[i]}';
          httpStatus = null;
          final response = await _ref
              .read(serverMediaHttpClientProvider)
              .send(http.Request('GET', Uri.parse(url)));
          httpStatus = response.statusCode;
          final iterator = StreamIterator<List<int>>(response.stream);
          try {
            if (response.statusCode != 200) {
              throw LocalCacheException('http_status',
                  httpStatus: response.statusCode);
            }
            final contentType = response.headers['content-type']?.toLowerCase();
            if (contentType != null &&
                (contentType.contains('text/') ||
                    contentType.contains('json') ||
                    contentType.contains('xml'))) {
              throw const LocalCacheException('invalid_image');
            }
            final expectedLength =
                int.tryParse(response.headers['content-length'] ?? '');
            // IOClient may have decompressed the body while retaining the wire
            // Content-Length. Stream errors still reject interrupted bodies.
            final encoding = response.headers['content-encoding'];
            final lengthIsExact = encoding == null || encoding == 'identity';
            if (lengthIsExact && expectedLength != null) {
              if (expectedLength > maxPageBytes) {
                throw const LocalCacheException('page_too_large');
              }
              await _checkSpace(pages.path, expectedLength);
            }
            Stream<List<int>> body() async* {
              while (await iterator.moveNext()) {
                yield iterator.current;
              }
            }

            await _writePage(target, body(),
                checkAllowed: checkAllowed,
                expectedLength: lengthIsExact ? expectedLength : null);
          } finally {
            await iterator.cancel();
          }
        }
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
          File(p.join(
              chapterDir.path, _manifestName(initial.epoch, initial.revision))),
          {
            'mangaId': mangaId,
            'chapterId': chapterId,
            'pageCount': totalPages,
            'pagesDirectory': p.basename(pages.path),
            'downloadedAt': DateTime.now().toIso8601String(),
            'verified': true,
            'baseApi': baseApi,
            'pageUrls': pageUrls,
          });
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
      // Keep verified pages for a future immutable attempt. Never remove
      // another engine's attempt or rollback data; only owned partials vanish.
      if (attemptPages != null && await attemptPages.exists()) {
        await for (final entity in attemptPages.list(followLinks: false)) {
          if (entity is File && entity.path.endsWith('.partial')) {
            await entity.delete();
          }
        }
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
    final chapterDir =
        Directory(p.join((await _getBaseDir()).path, '$mangaId', '$chapterId'));
    var metadata = await _readJson(File(
        p.join(chapterDir.path, _manifestName(state.epoch, state.revision))));
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
        if (metadata?['verified'] == true) await _imageValidator(file);
      } on LocalCacheException {
        return null;
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
    final mangaDir = Directory(p.join((await _getBaseDir()).path, '$mangaId'));
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
