import 'package:flutter_test/flutter_test.dart';

import 'package:tachidesk_sorayomi/src/features/browse_center/domain/extension/extension_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/chapter_model.dart';
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/chapter/graphql/__generated__/fragment.graphql.dart'
    as chapter;
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/manga/graphql/__generated__/fragment.graphql.dart'
    as manga;
import 'package:tachidesk_sorayomi/src/features/manga_book/domain/manga/manga_model.dart';
import 'package:tachidesk_sorayomi/src/graphql/__generated__/schema.graphql.dart';
import 'package:tachidesk_sorayomi/src/utils/misc/scalars.dart';

ChapterDto chapterFixture() => ChapterDto(
      chapterNumber: 1,
      fetchedAt: '1720000000',
      id: 12,
      user: chapter.Fragment$ChapterDto$user(
        isBookmarked: true,
        isDownloaded: true,
        isRead: true,
        lastPageRead: 9,
        lastReadAt: '1720000010',
      ),
      mangaId: 37,
      name: 'Chapter 1',
      pageCount: 10,
      sourceOrder: 1,
      uploadDate: '1710000000',
      url: '/chapter/1',
      meta: [],
    );

void main() {
  test('chapter state is read from the current user payload', () {
    final original = chapterFixture();
    final value = ChapterDto.fromJson({
      ...original.toJson(),
      'isRead': false,
      'isDownloaded': false,
      'lastPageRead': 0,
    });
    expect(value.isRead, isTrue);
    expect(value.isDownloaded, isTrue);
    expect(value.isBookmarked, isTrue);
    expect(value.lastPageRead, 9);
    expect(value.lastReadAt, '1720000010');
    expect(value.toJson(), contains('user'));
    expect(value.toJson(), isNot(contains('isRead')));
  });

  test('legacy offline chapters retain their progress during migration', () {
    final original = chapterFixture();
    final legacy = original.toJson()..remove('user');
    legacy.addAll(original.user.toJson()..remove('__typename'));
    expect(chapterFromJson(legacy), original);
    expect(legacy, isNot(contains('user')));
  });

  test('current offline chapter data round-trips without migration', () {
    final original = chapterFixture();
    expect(chapterFromJson(original.toJson()), original);
  });

  test('malformed offline state is rejected instead of resetting progress', () {
    final legacy = chapterFixture().toJson()..remove('user');
    expect(() => chapterFromJson(legacy), throwsA(isA<TypeError>()));
  });

  test('manga membership, counts and resume chapter use user data', () {
    final value = MangaDto(
      genre: [],
      id: 37,
      initialized: true,
      meta: [],
      sourceId: '9007199254740993',
      status: Enum$MangaStatus.ONGOING,
      title: 'Manga',
      user: manga.Fragment$MangaDto$user(
        inLibrary: true,
        inLibraryAt: '1720000000',
        unreadCount: 4,
        downloadCount: 2,
        lastReadChapter: chapterFixture(),
      ),
      updateStrategy: Enum$UpdateStrategy.ALWAYS_UPDATE,
      url: '/manga/37',
    );
    final parsed = MangaDto.fromJson(value.toJson());
    expect(parsed.inLibrary, isTrue);
    expect(parsed.inLibraryAt, '1720000000');
    expect(parsed.unreadCount, 4);
    expect(parsed.downloadCount, 2);
    expect(parsed.lastReadChapter?.lastPageRead, 9);
    expect(parsed.source, isNull);
    expect(parsed.toJson(), isNot(contains('inLibrary')));
  });

  test('optimistic library changes preserve the other user fields', () {
    final value = MangaBaseDto(
      genre: [],
      id: 37,
      initialized: true,
      meta: [],
      sourceId: '1',
      status: Enum$MangaStatus.ONGOING,
      title: 'Manga',
      user: manga.Fragment$MangaUserDto(
        inLibrary: false,
        inLibraryAt: '1720000000',
        unreadCount: 7,
      ),
      updateStrategy: Enum$UpdateStrategy.ALWAYS_UPDATE,
      url: '/manga/37',
    );
    final updated = value.copyWith(user: value.user.copyWith(inLibrary: true));
    expect(updated.inLibrary, isTrue);
    expect(updated.unreadCount, 7);
    expect(updated.inLibraryAt, value.inLibraryAt);
  });

  for (final warning in Enum$ContentWarning.values) {
    test('content warning $warning preserves NSFW filtering', () {
      final extension = Extension(
        hasUpdate: false,
        iconUrl: '/icon',
        isInstalled: false,
        contentWarning: warning,
        isObsolete: false,
        lang: 'en',
        name: 'Extension',
        pkgName: 'example.extension',
        versionCodeLong: '9007199254740993',
        versionName: '1.6.0',
      );
      expect(extension.isNsfw, warning != Enum$ContentWarning.SAFE);
      expect(Extension.fromJson(extension.toJson()).versionCodeLong,
          '9007199254740993');
    });
  }

  test('opaque cursors survive composite and large values exactly', () {
    for (final cursor in ['37-1720000010', '9007199254740993', '0']) {
      expect(cursorToJson(cursorFromJson(cursor)), cursor);
    }
    expect(() => cursorFromJson(37), throwsA(isA<TypeError>()));
  });
}
