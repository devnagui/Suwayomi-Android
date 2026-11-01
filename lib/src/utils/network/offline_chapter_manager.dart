// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../constants/endpoints.dart';
import '../../features/settings/presentation/server/widget/client/server_port_tile/server_port_tile.dart';
import '../../features/settings/presentation/server/widget/client/server_url_tile/server_url_tile.dart';
import '../../global_providers/global_providers.dart';
import '../extensions/custom_extensions.dart';
import 'auth_http_client.dart';

part 'offline_chapter_manager.g.dart';

/// Tracks local download progress for chapters
class LocalDownloadProgress {
  final int chapterId;
  final int mangaId;
  final int totalPages;
  final int downloadedPages;
  final bool isComplete;
  final String? error;

  const LocalDownloadProgress({
    required this.chapterId,
    required this.mangaId,
    required this.totalPages,
    required this.downloadedPages,
    required this.isComplete,
    this.error,
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
  }) async* {
    final chapterDir = await _getChapterDir(mangaId, chapterId);
    final baseApi = _buildBaseApi();
    final totalPages = pageUrls.length;

    for (int i = 0; i < totalPages; i++) {
      try {
        final pageFile = File(p.join(chapterDir.path, '$i.jpg'));
        if (await pageFile.exists()) {
          // Already downloaded, skip
          yield LocalDownloadProgress(
            chapterId: chapterId,
            mangaId: mangaId,
            totalPages: totalPages,
            downloadedPages: i + 1,
            isComplete: i == totalPages - 1,
          );
          continue;
        }

        final url = '$baseApi${pageUrls[i]}';
        final response =
            await _ref.read(serverMediaHttpClientProvider).get(Uri.parse(url));

        if (response.statusCode == 200) {
          await pageFile.writeAsBytes(response.bodyBytes);
        } else {
          yield LocalDownloadProgress(
            chapterId: chapterId,
            mangaId: mangaId,
            totalPages: totalPages,
            downloadedPages: i,
            isComplete: false,
            error: 'Failed to download page $i: HTTP ${response.statusCode}',
          );
          return;
        }
      } catch (e) {
        yield LocalDownloadProgress(
          chapterId: chapterId,
          mangaId: mangaId,
          totalPages: totalPages,
          downloadedPages: i,
          isComplete: false,
          error: 'Error downloading page $i: $e',
        );
        return;
      }

      yield LocalDownloadProgress(
        chapterId: chapterId,
        mangaId: mangaId,
        totalPages: totalPages,
        downloadedPages: i + 1,
        isComplete: i == totalPages - 1,
      );
    }

    // Save metadata
    await _saveChapterMetadata(mangaId, chapterId, totalPages);
  }

  /// Check if a chapter is available offline
  Future<bool> isChapterAvailableOffline(int mangaId, int chapterId) async {
    final metadata = await _getMetadata();
    final key = '${mangaId}_$chapterId';
    if (!metadata.containsKey(key)) return false;

    final chapterDir = await _getChapterDir(mangaId, chapterId);
    final pageCount = metadata[key]!['pageCount'] as int;

    for (int i = 0; i < pageCount; i++) {
      final file = File(p.join(chapterDir.path, '$i.jpg'));
      if (!await file.exists()) return false;
    }
    return true;
  }

  /// Get local page files for a chapter (for offline reading)
  Future<List<File>?> getOfflinePages(int mangaId, int chapterId) async {
    if (!await isChapterAvailableOffline(mangaId, chapterId)) return null;

    final metadata = await _getMetadata();
    final key = '${mangaId}_$chapterId';
    final pageCount = metadata[key]!['pageCount'] as int;
    final chapterDir = await _getChapterDir(mangaId, chapterId);

    return List.generate(
      pageCount,
      (i) => File(p.join(chapterDir.path, '$i.jpg')),
    );
  }

  /// Delete a locally downloaded chapter
  Future<void> deleteOfflineChapter(int mangaId, int chapterId) async {
    final chapterDir = await _getChapterDir(mangaId, chapterId);
    if (await chapterDir.exists()) {
      await chapterDir.delete(recursive: true);
    }
    await _removeChapterMetadata(mangaId, chapterId);
  }

  /// Get list of all offline chapter IDs for a manga
  Future<List<int>> getOfflineChapterIds(int mangaId) async {
    final metadata = await _getMetadata();
    return metadata.entries
        .where((e) => e.key.startsWith('${mangaId}_'))
        .map((e) => e.value['chapterId'] as int)
        .toList();
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
    final baseDir = await _getBaseDir();
    if (await baseDir.exists()) {
      await baseDir.delete(recursive: true);
    }
    final prefs = _ref.read(sharedPreferencesProvider);
    await prefs.remove(_metadataKey);
  }

  Future<Map<String, Map<String, dynamic>>> _getMetadata() async {
    final prefs = _ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(_metadataKey);
    if (raw == null) return {};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v)));
  }

  Future<void> _saveChapterMetadata(
      int mangaId, int chapterId, int pageCount) async {
    final metadata = await _getMetadata();
    final key = '${mangaId}_$chapterId';
    metadata[key] = {
      'mangaId': mangaId,
      'chapterId': chapterId,
      'pageCount': pageCount,
      'downloadedAt': DateTime.now().toIso8601String(),
    };
    final prefs = _ref.read(sharedPreferencesProvider);
    await prefs.setString(_metadataKey, jsonEncode(metadata));
  }

  Future<void> _removeChapterMetadata(int mangaId, int chapterId) async {
    final metadata = await _getMetadata();
    metadata.remove('${mangaId}_$chapterId');
    final prefs = _ref.read(sharedPreferencesProvider);
    await prefs.setString(_metadataKey, jsonEncode(metadata));
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
