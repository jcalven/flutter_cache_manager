import 'dart:async';
import 'dart:io';

import 'package:flutter_cache_manager/src/storage/cache_info_repositories/cache_info_repository.dart';
import 'package:flutter_cache_manager/src/storage/cache_info_repositories/helper_methods.dart';
import 'package:flutter_cache_manager/src/storage/cache_object.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite_async/sqlite_async.dart';

const _tableCacheObject = 'cacheObject';

/// SQLite-backed cache info repository using `sqlite_async` (FFI direct).
///
/// On-disk schema matches what previous sqflite-based versions of this package
/// wrote, so a database written by an older release is readable as-is.
class SqliteAsyncCacheRepository extends CacheInfoRepository
    with CacheInfoRepositoryHelperMethods {
  SqliteDatabase? _db;
  String? _path;
  String? databaseName;

  /// Either [path] (full file path ending in `.db`) or [databaseName] should be
  /// provided. If [path] is given it must end with `${databaseName}.db`.
  SqliteAsyncCacheRepository({String? path, this.databaseName}) : _path = path;

  @override
  Future<bool> open() async {
    if (!shouldOpenOnNewConnection()) {
      return openCompleter!.future;
    }
    final path = await _getPath();
    await Directory(dirname(path)).create(recursive: true);

    final migrations = SqliteMigrations()
      ..add(SqliteMigration(1, (tx) async {
        await tx.execute('''
          CREATE TABLE IF NOT EXISTS $_tableCacheObject (
            ${CacheObject.columnId} INTEGER PRIMARY KEY,
            ${CacheObject.columnUrl} TEXT,
            ${CacheObject.columnKey} TEXT,
            ${CacheObject.columnPath} TEXT,
            ${CacheObject.columnETag} TEXT,
            ${CacheObject.columnValidTill} INTEGER,
            ${CacheObject.columnTouched} INTEGER,
            ${CacheObject.columnLength} INTEGER
          );
        ''');
        await tx.execute('''
          CREATE UNIQUE INDEX IF NOT EXISTS
            $_tableCacheObject${CacheObject.columnKey}
            ON $_tableCacheObject (${CacheObject.columnKey});
        ''');
      }));

    _db = SqliteDatabase(
      path: path,
      // Tuning for a small-payload, write-light, read-heavy cache:
      //  - WAL: concurrent reads while a write is in flight.
      //  - NORMAL sync: durable enough for a rebuildable cache (FULL is overkill).
      // Both match sqlite_async's defaults today; set explicitly to anchor
      // behaviour against future package-default drift.
      options: const SqliteOptions(
        journalMode: SqliteJournalMode.wal,
        synchronous: SqliteSynchronous.normal,
      ),
    );
    await migrations.migrate(_db!);
    return opened();
  }

  @override
  Future<dynamic> updateOrInsert(CacheObject cacheObject) {
    if (cacheObject.id == null) {
      return insert(cacheObject);
    }
    return update(cacheObject);
  }

  @override
  Future<CacheObject> insert(CacheObject cacheObject,
      {bool setTouchedToNow = true}) async {
    final map = cacheObject.toMap(setTouchedToNow: setTouchedToNow);
    final result = await _db!.execute(
      '''
      INSERT INTO $_tableCacheObject (
        ${CacheObject.columnUrl}, ${CacheObject.columnKey},
        ${CacheObject.columnPath}, ${CacheObject.columnETag},
        ${CacheObject.columnValidTill}, ${CacheObject.columnTouched},
        ${CacheObject.columnLength}
      ) VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING ${CacheObject.columnId};
      ''',
      [
        map[CacheObject.columnUrl],
        map[CacheObject.columnKey],
        map[CacheObject.columnPath],
        map[CacheObject.columnETag],
        map[CacheObject.columnValidTill],
        map[CacheObject.columnTouched],
        map[CacheObject.columnLength],
      ],
    );
    final id = result.first[CacheObject.columnId] as int;
    return cacheObject.copyWith(id: id);
  }

  @override
  Future<CacheObject?> get(String key) async {
    final rows = await _db!.getAll(
      'SELECT * FROM $_tableCacheObject '
      'WHERE ${CacheObject.columnKey} = ? LIMIT 1;',
      [key],
    );
    if (rows.isEmpty) return null;
    return CacheObject.fromMap(_rowToMap(rows.first));
  }

  @override
  Future<int> delete(int id) async {
    await _db!.execute(
      'DELETE FROM $_tableCacheObject WHERE ${CacheObject.columnId} = ?;',
      [id],
    );
    return 1;
  }

  @override
  Future<int> deleteAll(Iterable<int> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return 0;
    final placeholders = List.filled(list.length, '?').join(',');
    await _db!.execute(
      'DELETE FROM $_tableCacheObject '
      'WHERE ${CacheObject.columnId} IN ($placeholders);',
      list,
    );
    return list.length;
  }

  @override
  Future<int> update(CacheObject cacheObject,
      {bool setTouchedToNow = true}) async {
    final map = cacheObject.toMap(setTouchedToNow: setTouchedToNow);
    await _db!.execute(
      '''
      UPDATE $_tableCacheObject SET
        ${CacheObject.columnUrl} = ?, ${CacheObject.columnKey} = ?,
        ${CacheObject.columnPath} = ?, ${CacheObject.columnETag} = ?,
        ${CacheObject.columnValidTill} = ?, ${CacheObject.columnTouched} = ?,
        ${CacheObject.columnLength} = ?
      WHERE ${CacheObject.columnId} = ?;
      ''',
      [
        map[CacheObject.columnUrl],
        map[CacheObject.columnKey],
        map[CacheObject.columnPath],
        map[CacheObject.columnETag],
        map[CacheObject.columnValidTill],
        map[CacheObject.columnTouched],
        map[CacheObject.columnLength],
        cacheObject.id,
      ],
    );
    // sqlite_async's ResultSet doesn't expose changes() on simple execute.
    // Callers only check non-zero; return 1 on success.
    return 1;
  }

  @override
  Future<List<CacheObject>> getAllObjects() async {
    final rows = await _db!.getAll('SELECT * FROM $_tableCacheObject;');
    return rows.map((r) => CacheObject.fromMap(_rowToMap(r))).toList();
  }

  @override
  Future<Map<String, CacheObject>> getMany(Iterable<String> keys) async {
    final list = keys.toList();
    if (list.isEmpty) return const {};
    final placeholders = List.filled(list.length, '?').join(',');
    final rows = await _db!.getAll(
      'SELECT * FROM $_tableCacheObject '
      'WHERE ${CacheObject.columnKey} IN ($placeholders);',
      list,
    );
    final result = <String, CacheObject>{};
    for (final row in rows) {
      final obj = CacheObject.fromMap(_rowToMap(row));
      result[obj.key] = obj;
    }
    return result;
  }

  @override
  Future<List<CacheObject>> getObjectsOverCapacity(int capacity) async {
    final cutoff = DateTime.now()
        .subtract(const Duration(days: 1))
        .millisecondsSinceEpoch;
    final rows = await _db!.getAll(
      '''
      SELECT * FROM $_tableCacheObject
      WHERE ${CacheObject.columnTouched} < ?
      ORDER BY ${CacheObject.columnTouched} DESC
      LIMIT 100 OFFSET ?;
      ''',
      [cutoff, capacity],
    );
    return rows.map((r) => CacheObject.fromMap(_rowToMap(r))).toList();
  }

  @override
  Future<List<CacheObject>> getOldObjects(Duration maxAge) async {
    final cutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    final rows = await _db!.getAll(
      '''
      SELECT * FROM $_tableCacheObject
      WHERE ${CacheObject.columnTouched} < ?
      LIMIT 100;
      ''',
      [cutoff],
    );
    return rows.map((r) => CacheObject.fromMap(_rowToMap(r))).toList();
  }

  @override
  Future<bool> close() async {
    if (!shouldClose()) return false;
    await _db?.close();
    _db = null;
    return true;
  }

  @override
  Future<void> deleteDataFile() async {
    final path = await _getPath();
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<bool> exists() async {
    final path = await _getPath();
    return File(path).exists();
  }

  Future<String> _getPath() async {
    if (_path != null && _path!.endsWith('.db')) {
      return _path!;
    }
    final directory = _path != null
        ? Directory(dirname(_path!))
        : await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    _path = join(directory.path, '$databaseName.db');
    return _path!;
  }

  Map<String, dynamic> _rowToMap(dynamic row) {
    return <String, dynamic>{
      CacheObject.columnId: row[CacheObject.columnId],
      CacheObject.columnUrl: row[CacheObject.columnUrl],
      CacheObject.columnKey: row[CacheObject.columnKey],
      CacheObject.columnPath: row[CacheObject.columnPath],
      CacheObject.columnETag: row[CacheObject.columnETag],
      CacheObject.columnValidTill: row[CacheObject.columnValidTill],
      CacheObject.columnTouched: row[CacheObject.columnTouched],
      CacheObject.columnLength: row[CacheObject.columnLength],
    };
  }
}
