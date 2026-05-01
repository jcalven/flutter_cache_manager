import 'dart:io';

import 'package:flutter_cache_manager/src/storage/cache_info_repositories/sqlite_async_cache_repository.dart';
import 'package:flutter_cache_manager/src/storage/cache_object.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('fcm_sqlite_async_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  String dbPath() => join(tempDir.path, 'test_cache.db');

  group('open() + close()', () {
    test('open creates the database file', () async {
      final repo = SqliteAsyncCacheRepository(path: dbPath());
      expect(await repo.open(), isTrue);
      expect(File(dbPath()).existsSync(), isTrue);
      await repo.close();
    });

    test('open is idempotent across multiple connections', () async {
      final repo = SqliteAsyncCacheRepository(path: dbPath());
      await repo.open();
      await repo.open();
      // First close decrements but doesn't actually close — repo stays open.
      expect(await repo.close(), isFalse);
      // Second close actually closes.
      expect(await repo.close(), isTrue);
    });
  });

  group('CRUD basics', () {
    test('insert assigns id and get(key) returns the same object', () async {
      final repo = SqliteAsyncCacheRepository(path: dbPath());
      await repo.open();
      final inserted = await repo.insert(CacheObject(
        'https://example.com/a.jpg',
        relativePath: 'a.jpg',
        validTill: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      ));
      expect(inserted.id, isNotNull);

      final fetched = await repo.get('https://example.com/a.jpg');
      expect(fetched, isNotNull);
      expect(fetched!.id, inserted.id);
      expect(fetched.relativePath, 'a.jpg');

      await repo.close();
    });

    test('update mutates an existing row', () async {
      final repo = SqliteAsyncCacheRepository(path: dbPath());
      await repo.open();
      final inserted = await repo.insert(CacheObject(
        'https://example.com/b.jpg',
        relativePath: 'b.jpg',
        validTill: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      ));

      final affected =
          await repo.update(inserted.copyWith(relativePath: 'b2.jpg'));
      expect(affected, 1);

      final fetched = await repo.get('https://example.com/b.jpg');
      expect(fetched!.relativePath, 'b2.jpg');

      await repo.close();
    });

    test('updateOrInsert inserts when id is null, updates when id present',
        () async {
      final repo = SqliteAsyncCacheRepository(path: dbPath());
      await repo.open();

      final result1 = await repo.updateOrInsert(CacheObject(
        'https://example.com/c.jpg',
        relativePath: 'c.jpg',
        validTill: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      ));
      expect(result1, isA<CacheObject>());
      final inserted = result1 as CacheObject;
      expect(inserted.id, isNotNull);

      final result2 = await repo.updateOrInsert(
        inserted.copyWith(relativePath: 'c2.jpg'),
      );
      // Update path returns the affected row count (int), matching CacheObjectProvider.
      expect(result2, isA<int>());

      final fetched = await repo.get('https://example.com/c.jpg');
      expect(fetched!.relativePath, 'c2.jpg');

      await repo.close();
    });
  });

  group('delete', () {
    test('delete by id removes the row', () async {
      final repo = SqliteAsyncCacheRepository(path: dbPath());
      await repo.open();
      final inserted = await repo.insert(CacheObject(
        'https://example.com/d.jpg',
        relativePath: 'd.jpg',
        validTill: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      ));

      final deleted = await repo.delete(inserted.id!);
      expect(deleted, 1);
      expect(await repo.get('https://example.com/d.jpg'), isNull);

      await repo.close();
    });

    test('deleteAll removes all matching rows', () async {
      final repo = SqliteAsyncCacheRepository(path: dbPath());
      await repo.open();
      final a = await repo.insert(CacheObject(
        'https://example.com/e1.jpg',
        relativePath: 'e1.jpg',
        validTill: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      ));
      final b = await repo.insert(CacheObject(
        'https://example.com/e2.jpg',
        relativePath: 'e2.jpg',
        validTill: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      ));

      final deleted = await repo.deleteAll([a.id!, b.id!]);
      expect(deleted, 2);
      expect(await repo.get('https://example.com/e1.jpg'), isNull);
      expect(await repo.get('https://example.com/e2.jpg'), isNull);

      await repo.close();
    });

    test('deleteAll on empty iterable is a no-op', () async {
      final repo = SqliteAsyncCacheRepository(path: dbPath());
      await repo.open();
      final deleted = await repo.deleteAll(<int>[]);
      expect(deleted, 0);
      await repo.close();
    });
  });

  group('bulk reads', () {
    test('getAllObjects returns every row', () async {
      final repo = SqliteAsyncCacheRepository(path: dbPath());
      await repo.open();
      await repo.insert(
          CacheObject('u1', relativePath: 'p1', validTill: DateTime(2030)));
      await repo.insert(
          CacheObject('u2', relativePath: 'p2', validTill: DateTime(2030)));
      final all = await repo.getAllObjects();
      expect(all.map((c) => c.url), unorderedEquals(['u1', 'u2']));
      await repo.close();
    });

    test('getOldObjects returns only items touched before maxAge', () async {
      final repo = SqliteAsyncCacheRepository(path: dbPath());
      await repo.open();
      final old = CacheObject(
        'old',
        relativePath: 'old.jpg',
        validTill: DateTime(2030),
        touched: DateTime.now().subtract(const Duration(days: 60)),
      );
      final fresh = CacheObject(
        'fresh',
        relativePath: 'fresh.jpg',
        validTill: DateTime(2030),
      );
      await repo.insert(old, setTouchedToNow: false);
      await repo.insert(fresh);
      final results = await repo.getOldObjects(const Duration(days: 30));
      expect(results.map((c) => c.url), ['old']);
      await repo.close();
    });

    test('getObjectsOverCapacity returns rows above the capacity', () async {
      final repo = SqliteAsyncCacheRepository(path: dbPath());
      await repo.open();
      // 5 rows, all touched > 1 day ago so they qualify for cleanup.
      final base = DateTime.now().subtract(const Duration(days: 2));
      for (var i = 0; i < 5; i++) {
        await repo.insert(
          CacheObject(
            'u$i',
            relativePath: 'p$i',
            validTill: DateTime(2030),
            touched: base.add(Duration(minutes: i)),
          ),
          setTouchedToNow: false,
        );
      }
      final overCap = await repo.getObjectsOverCapacity(2);
      expect(overCap.length, 3); // 5 - 2
      await repo.close();
    });
  });

  group('exists + deleteDataFile', () {
    test('exists is false before open, true after', () async {
      final repo = SqliteAsyncCacheRepository(path: dbPath());
      expect(await repo.exists(), isFalse);
      await repo.open();
      expect(await repo.exists(), isTrue);
      await repo.close();
    });

    test('deleteDataFile removes the database file', () async {
      final repo = SqliteAsyncCacheRepository(path: dbPath());
      await repo.open();
      await repo.close();
      expect(File(dbPath()).existsSync(), isTrue);
      await repo.deleteDataFile();
      expect(File(dbPath()).existsSync(), isFalse);
    });
  });
}
