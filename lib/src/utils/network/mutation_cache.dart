// Copyright (c) 2022 Contributors to the Suwayomi project
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../logger/logger.dart';
import '../logger/operation_log.dart';

/// Simple file-based JSON cache for mutation results that graphql_flutter
/// doesn't cache (mutations are never written to HiveStore).
class MutationCache {
  static MutationCache? _instance;

  factory MutationCache() {
    _instance ??= MutationCache._();
    return _instance!;
  }

  MutationCache._();

  MutationCache.forDirectory(Directory directory)
      : _cacheDir = Future.value(directory);

  Future<Directory>? _cacheDir;

  Future<Directory> _getCacheDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'mutation_cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _sanitizeKey(String key) => key.replaceAll(RegExp(r'[^\w]'), '_');

  /// Save JSON data to local cache.
  Future<void> put(String key, dynamic jsonData) async {
    try {
      _cacheDir ??= _getCacheDir();
      final dir = await _cacheDir!;
      final file = File(p.join(dir.path, '${_sanitizeKey(key)}.json'));
      await file.writeAsString(jsonEncode(jsonData));
      OperationLog.instance.record('MutationCacheWrite', outcome: 'saved');
    } on FileSystemException catch (error) {
      _cacheDir = null;
      logger.w('Could not write the local mutation cache', error: error);
      OperationLog.instance
          .record('MutationCacheWrite', outcome: 'storage_error');
    }
  }

  /// Read cached JSON data. Returns null if not found.
  Future<dynamic> get(String key) async {
    try {
      _cacheDir ??= _getCacheDir();
      final dir = await _cacheDir!;
      final file = File(p.join(dir.path, '${_sanitizeKey(key)}.json'));
      if (await file.exists()) {
        final content = await file.readAsString();
        OperationLog.instance.record('MutationCacheRead', outcome: 'hit');
        return jsonDecode(content);
      }
    } on FileSystemException catch (error) {
      _cacheDir = null;
      logger.w('Could not read the local mutation cache', error: error);
      OperationLog.instance
          .record('MutationCacheRead', outcome: 'storage_error');
    } on FormatException catch (error) {
      logger.w('Invalid JSON in the local mutation cache', error: error);
      OperationLog.instance
          .record('MutationCacheRead', outcome: 'invalid_json');
    }
    OperationLog.instance.record('MutationCacheRead', outcome: 'miss');
    return null;
  }

  /// Remove a cached entry.
  Future<void> remove(String key) async {
    _cacheDir ??= _getCacheDir();
    final dir = await _cacheDir!;
    final file = File(p.join(dir.path, '${_sanitizeKey(key)}.json'));
    if (await file.exists()) await file.delete();
  }

  Future<Map<String, dynamic>> entries() async {
    _cacheDir ??= _getCacheDir();
    final directory = await _cacheDir!;
    final result = <String, dynamic>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && p.extension(entity.path) == '.json') {
        result[p.basenameWithoutExtension(entity.path)] =
            jsonDecode(await entity.readAsString());
      }
    }
    return result;
  }

  Future<int> clear() async {
    _cacheDir ??= _getCacheDir();
    final directory = await _cacheDir!;
    var removed = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && p.extension(entity.path) == '.json') {
        await entity.delete();
        removed++;
      }
    }
    return removed;
  }

  Future<void> removeMangas(Set<int> mangaIds) async {
    final snapshot = await entries();
    final keys = <String>{};
    final chapterIds = <int>{};
    for (final entry in snapshot.entries) {
      final listMatch = RegExp(r'^chapter_list_(\d+)$').firstMatch(entry.key);
      final listMangaId = listMatch == null ? null : int.parse(listMatch[1]!);
      if (mangaIds.contains(listMangaId)) {
        keys.add(entry.key);
        final chapters = entry.value;
        if (chapters is List) {
          for (final chapter in chapters) {
            if (chapter is Map && chapter['id'] is int) {
              chapterIds.add(chapter['id'] as int);
            }
          }
        }
      }
      final value = entry.value;
      if (value is Map && mangaIds.contains(value['mangaId'])) {
        keys.add(entry.key);
        if (value['id'] is int) chapterIds.add(value['id'] as int);
      }
    }
    for (final id in chapterIds) {
      keys.add('chapter_$id');
      keys.add('chapter_pages_$id');
    }
    for (final key in keys) {
      await remove(key);
    }
  }
}
