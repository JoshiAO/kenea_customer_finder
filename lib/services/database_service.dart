import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:excel/excel.dart' as xl;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sembast_web/sembast_web.dart';
import 'package:sembast_sqflite/sembast_sqflite.dart' as sqf;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';
import '../models/customer.dart';
import '../models/dsp.dart';
import '../models/counts.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Database? _database;
  final customerStore = intMapStoreFactory.store('customers');
  final dspStore = intMapStoreFactory.store('dsps');
  Uint8List? _dspMasterOverrideBytes;
  Uint8List? _areaMasterOverrideBytes;
  Uint8List? _customerClassOverrideBytes;
  bool _attemptedLocationRepair = false;

  Future<String?> _persistedDspCsvPath() async {
    if (kIsWeb) return null;
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'dsp_master_override.csv');
  }

  Future<String?> _persistedAreaCsvPath() async {
    if (kIsWeb) return null;
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'area_master_override.csv');
  }

  Future<String?> _persistedCustomerClassPath() async {
    if (kIsWeb) return null;
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'customer_class_override.bin');
  }

  Future<String?> _persistedCmlPath() async {
    if (kIsWeb) return null;
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'last_cml_import.bin');
  }

  Future<String?> _persistedCmlMetaPath() async {
    if (kIsWeb) return null;
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'last_cml_import_meta.json');
  }

  Future<void> _savePersistedCml(Uint8List bytes, {required bool isXlsx}) async {
    final cmlPath = await _persistedCmlPath();
    final metaPath = await _persistedCmlMetaPath();
    if (cmlPath == null || metaPath == null) return;

    await File(cmlPath).writeAsBytes(bytes, flush: true);
    final meta = jsonEncode({'isXlsx': isXlsx});
    await File(metaPath).writeAsString(meta, flush: true);
  }

  Future<Map<String, dynamic>?> _readPersistedCml() async {
    final cmlPath = await _persistedCmlPath();
    final metaPath = await _persistedCmlMetaPath();
    if (cmlPath == null || metaPath == null) return null;

    final cmlFile = File(cmlPath);
    final metaFile = File(metaPath);
    if (!await cmlFile.exists() || !await metaFile.exists()) return null;

    final bytes = Uint8List.fromList(await cmlFile.readAsBytes());
    final metaRaw = await metaFile.readAsString();
    final meta = jsonDecode(metaRaw) as Map<String, dynamic>;
    return {
      'bytes': bytes,
      'isXlsx': meta['isXlsx'] == true,
    };
  }

  Future<void> _savePersistedDspCsv(Uint8List bytes) async {
    final path = await _persistedDspCsvPath();
    if (path == null) return;
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<Uint8List?> _readPersistedDspCsv() async {
    final path = await _persistedDspCsvPath();
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return Uint8List.fromList(await file.readAsBytes());
  }

  Future<void> _savePersistedAreaCsv(Uint8List bytes) async {
    final path = await _persistedAreaCsvPath();
    if (path == null) return;
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<Uint8List?> _readPersistedAreaCsv() async {
    final path = await _persistedAreaCsvPath();
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return Uint8List.fromList(await file.readAsBytes());
  }

  Future<void> _savePersistedCustomerClassFile(Uint8List bytes) async {
    final path = await _persistedCustomerClassPath();
    if (path == null) return;
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<Uint8List?> _readPersistedCustomerClassFile() async {
    final path = await _persistedCustomerClassPath();
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return Uint8List.fromList(await file.readAsBytes());
  }

  String _normalizeHeader(String raw) {
    return raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_');
  }

  String _normalizeDspCode(String raw) {
    return raw
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'\.0+$'), '');
  }

  String _normalizeLocationValue(String? raw) {
    return _cleanLocationValue(raw)
        .toUpperCase()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  String _canonicalLocationValue(String? raw) {
    return _normalizeLocationValue(raw).replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  bool _locationMatches({
    required String selectedCanonical,
    required String actualRaw,
  }) {
    if (selectedCanonical.isEmpty) return true;
    final actualCanonical = _canonicalLocationValue(actualRaw);
    if (actualCanonical.isEmpty) return false;
    return actualCanonical == selectedCanonical ||
        actualCanonical.contains(selectedCanonical) ||
        selectedCanonical.contains(actualCanonical);
  }

  String _cleanLocationValue(String? raw) {
    final trimmed = (raw ?? '').trim();
    return trimmed
      .replaceAll(RegExp("^['\"]+"), '')
      .replaceAll(RegExp("['\"]+\$"), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
  }

  static String _cleanLocationStatic(String? raw) {
    final trimmed = (raw ?? '').trim();
    return trimmed
      .replaceAll(RegExp("^['\"]+"), '')
      .replaceAll(RegExp("['\"]+\$"), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
  }

  @visibleForTesting
  static Map<String, String> extractCanonicalLocationFields(Map<String, dynamic> raw) {
    String read(List<String> keys) {
      for (final key in keys) {
        final value = raw[key];
        final cleaned = _cleanLocationStatic(value?.toString());
        if (cleaned.isNotEmpty) return cleaned;
      }
      return '';
    }

    final province = read([
      'province',
      'Province',
      'PROVINCE',
      'prov',
      'Prov',
      'province_name',
      'province name',
      'Province Name',
    ]);
    final city = read([
      'city',
      'City',
      'CITY',
      'municipality',
      'Municipality',
      'city_municipality',
      'city municipality',
      'city/municipality',
      'town',
      'City/Town',
    ]);
    final barangay = read([
      'barangay',
      'Barangay',
      'BRGY',
      'brgy',
      'barangay_name',
      'barangay name',
      'brgy_name',
      'brgy name',
      'barangay/brgy',
    ]);

    return {
      'province': province,
      'city': city,
      'barangay': barangay,
    };
  }

  String _cellString(List<dynamic> row, int index) {
    if (index < 0 || index >= row.length) return '';
    return row[index].toString().trim();
  }

  List<Map<String, String>> _parseDspMasterFromBytes(Uint8List bytes) {
    final csvContent = String.fromCharCodes(bytes).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final csvTable = CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(csvContent);
    if (csvTable.isEmpty) return [];

    final header = csvTable.first.map((h) => _normalizeHeader(h.toString())).toList();
    final indexByHeader = <String, int>{};
    for (var i = 0; i < header.length; i++) {
      indexByHeader[header[i]] = i;
    }

    int idx(List<String> aliases) {
      for (final key in aliases) {
        final normalized = _normalizeHeader(key);
        if (indexByHeader.containsKey(normalized)) return indexByHeader[normalized]!;
      }
      return -1;
    }

    var codeIdx = idx(['dsp_code', 'dsp code', 'sales_rep_id', 'sales rep id']);
    final nameIdx = idx(['dsp_name', 'dsp name', 'sales_rep_name', 'sales rep name']);
    final teamIdx = idx(['team']);
    final supervisorIdx = idx(['supervisor']);

    // Fallback: if code column header is non-standard, assume first column is code.
    if (codeIdx < 0 && header.isNotEmpty) {
      codeIdx = 0;
    }

    final parsed = <Map<String, String>>[];
    for (var i = 1; i < csvTable.length; i++) {
      final row = csvTable[i];
      final code = _normalizeDspCode(_cellString(row, codeIdx));
      if (code.isEmpty) continue;

      parsed.add({
        'sales_rep_id': code,
        'sales_rep_name': _cellString(row, nameIdx),
        'team': _cellString(row, teamIdx),
        'supervisor': _cellString(row, supervisorIdx),
      });
    }

    return parsed;
  }

  List<Map<String, dynamic>> _parseAreaMasterFromBytes(Uint8List bytes) {
    final csvContent = utf8
        .decode(bytes, allowMalformed: true)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final csvTable = CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(csvContent);
    if (csvTable.isEmpty) return [];

    var startIndex = 0;
    if (csvTable.first.length >= 3) {
      final firstA = _cleanLocationValue(csvTable.first[0].toString()).toLowerCase();
      final firstB = _cleanLocationValue(csvTable.first[1].toString()).toLowerCase();
      final firstC = _cleanLocationValue(csvTable.first[2].toString()).toLowerCase();
      if (firstA == 'province' && firstB == 'city' && firstC == 'barangay') {
        startIndex = 1;
      }
    }

    final seen = <String>{};
    final rows = <Map<String, dynamic>>[];

    for (var i = startIndex; i < csvTable.length; i++) {
      final row = csvTable[i];
      if (row.length < 3) continue;

      final province = _cleanLocationValue(row[0].toString());
      final city = _cleanLocationValue(row[1].toString());
      final barangay = _cleanLocationValue(row[2].toString());
      if (province.isEmpty || city.isEmpty || barangay.isEmpty) continue;

      final key = '${_canonicalLocationValue(province)}|${_canonicalLocationValue(city)}|${_canonicalLocationValue(barangay)}';
      if (!seen.add(key)) continue;

      rows.add({
        'province': province,
        'city': city,
        'barangay': barangay,
      });
    }

    rows.sort((a, b) {
      final p = (a['province'] as String).compareTo(b['province'] as String);
      if (p != 0) return p;
      final c = (a['city'] as String).compareTo(b['city'] as String);
      if (c != 0) return c;
      return (a['barangay'] as String).compareTo(b['barangay'] as String);
    });

    return rows;
  }

  List<String> _parseCustomerClassRowsFromBytes(Uint8List bytes, {required bool isXlsx}) {
    List<List<dynamic>> table;

    if (isXlsx) {
      final excel = xl.Excel.decodeBytes(bytes);
      if (excel.tables.isEmpty) return [];
      final sheet = excel.tables.values.first;
      table = sheet.rows
          .map((row) => row.map((cell) => cell?.value?.toString() ?? '').toList())
          .toList();
    } else {
      final csvContent = utf8
          .decode(bytes, allowMalformed: true)
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n');
      table = CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(csvContent);
    }

    if (table.isEmpty) return [];

    final headerAliases = {
      'party_classification_description',
      'party classification description',
      'party_classification',
      'party classification',
      'classification',
      'customer_class',
      'customer class',
      'class',
    };

    int columnIndex = 0;
    var startIndex = 0;
    final firstRow = table.first;
    if (firstRow.isNotEmpty) {
      for (var i = 0; i < firstRow.length; i++) {
        final raw = firstRow[i].toString().trim().toLowerCase();
        if (raw.isNotEmpty && headerAliases.contains(raw)) {
          columnIndex = i;
          startIndex = 1;
          break;
        }
      }
    }

    final seen = <String>{};
    final values = <String>[];

    for (var i = startIndex; i < table.length; i++) {
      final row = table[i];
      if (row.isEmpty) continue;

      final value = (columnIndex < row.length ? row[columnIndex] : row.first)
          .toString()
          .trim();
      if (value.isEmpty) continue;

      final canonical = value.toLowerCase();
      if (seen.add(canonical)) {
        values.add(value);
      }
    }

    return values;
  }

  List<String> _tryParseCustomerClassRowsFromBytes(Uint8List bytes, {required bool isXlsx}) {
    try {
      return _parseCustomerClassRowsFromBytes(bytes, isXlsx: isXlsx);
    } catch (_) {
      return <String>[];
    }
  }

  Future<List<Map<String, String>>> _loadDspMasterRows() async {
    if (_dspMasterOverrideBytes != null) {
      final rows = _parseDspMasterFromBytes(_dspMasterOverrideBytes!);
      if (rows.isNotEmpty) return rows;
    }

    final persistedBytes = await _readPersistedDspCsv();
    if (persistedBytes != null) {
      _dspMasterOverrideBytes = persistedBytes;
      final rows = _parseDspMasterFromBytes(persistedBytes);
      if (rows.isNotEmpty) return rows;
    }

    try {
      final assetBytes = await rootBundle.load('assets/DSP.csv');
      return _parseDspMasterFromBytes(assetBytes.buffer.asUint8List());
    } catch (_) {
      return <Map<String, String>>[];
    }
  }

  Future<List<Map<String, dynamic>>> _loadAreaMasterRows() async {
    if (_areaMasterOverrideBytes != null) {
      final rows = _parseAreaMasterFromBytes(_areaMasterOverrideBytes!);
      if (rows.isNotEmpty) return rows;
    }

    final persistedBytes = await _readPersistedAreaCsv();
    if (persistedBytes != null) {
      _areaMasterOverrideBytes = persistedBytes;
      final rows = _parseAreaMasterFromBytes(persistedBytes);
      if (rows.isNotEmpty) return rows;
    }

    try {
      final assetBytes = await rootBundle.load('assets/Area.csv');
      return _parseAreaMasterFromBytes(assetBytes.buffer.asUint8List());
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<List<String>> _loadCustomerClassRows() async {
    if (_customerClassOverrideBytes != null) {
      var rows = _tryParseCustomerClassRowsFromBytes(_customerClassOverrideBytes!, isXlsx: false);
      if (rows.isNotEmpty) return rows;
      rows = _tryParseCustomerClassRowsFromBytes(_customerClassOverrideBytes!, isXlsx: true);
      if (rows.isNotEmpty) return rows;
    }

    final persistedBytes = await _readPersistedCustomerClassFile();
    if (persistedBytes != null) {
      _customerClassOverrideBytes = persistedBytes;
      var rows = _tryParseCustomerClassRowsFromBytes(persistedBytes, isXlsx: false);
      if (rows.isNotEmpty) return rows;
      rows = _tryParseCustomerClassRowsFromBytes(persistedBytes, isXlsx: true);
      if (rows.isNotEmpty) return rows;
    }

    try {
      final assetBytes = await rootBundle.load('assets/Customer_Class.csv');
      return _parseCustomerClassRowsFromBytes(assetBytes.buffer.asUint8List(), isXlsx: false);
    } catch (_) {
      return <String>[];
    }
  }

  static String _sanitizeFolderSegment(String input) {
    return input
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String customerImageFolderName(Customer customer) {
    final code = _sanitizeFolderSegment(customer.customerCode);
    final name = _sanitizeFolderSegment(customer.customerName);
    return '$code - $name';
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    DatabaseFactory dbFactory;
    String dbPath;

    if (kIsWeb) {
      dbFactory = databaseFactoryWeb;
      dbPath = 'kenea_sembast.db';
    } else {
      final dbsPath = await sqflite.getDatabasesPath();
      dbPath = p.join(dbsPath, 'kenea_sembast.db'); // new name avoids conflict with old sqflite db
      dbFactory = sqf.getDatabaseFactorySqflite(sqflite.databaseFactory);
    }

    return await dbFactory.openDatabase(dbPath, version: 1, onVersionChanged: _onVersionChanged);
  }

  Future<void> _onVersionChanged(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 1) {
      // Create stores if needed, but sembast handles it
    }
  }

  Future<List<Customer>> _parseCustomersFromBytes(
    Uint8List bytes, {
    required bool isXlsx,
    void Function(double)? onProgress,
  }) async {
    onProgress?.call(0.02);
    final parsedRows = await Isolate.run(
      () => _parseCustomerRowsInIsolate(bytes: bytes, isXlsx: isXlsx),
    );

    if (parsedRows.isEmpty) {
      onProgress?.call(1.0);
      return const <Customer>[];
    }

    final customers = <Customer>[];
    final total = parsedRows.length;
    for (var i = 0; i < parsedRows.length; i++) {
      customers.add(Customer.fromJson(parsedRows[i]));
      if ((i + 1) % 250 == 0 || i == parsedRows.length - 1) {
        onProgress?.call((i + 1) / total);
        await Future<void>.delayed(Duration.zero);
      }
    }

    onProgress?.call(1.0);
    return customers;
  }

  Map<String, dynamic> _buildDspRecord(Customer customer) {
    return {
      'sales_rep_id': customer.salesRepId,
      'sales_rep_name': customer.salesRepName,
      'branch_name': customer.branchName,
      'cdam': customer.cdam,
      'fs': customer.fs,
      'channel': customer.channel,
    };
  }

  Future<void> importCML(Uint8List bytes, {bool isXlsx = false, void Function(double)? onProgress}) async {
    final db = await database;
    final customers = await _parseCustomersFromBytes(
      bytes,
      isXlsx: isXlsx,
      onProgress: (p) => onProgress?.call(p * 0.35),
    );

    final total = customers.length;
    await db.transaction((txn) async {
      await customerStore.delete(txn);
      await dspStore.delete(txn);
    });

    final seenDspIds = <String>{};
    const batchSize = 400;
    for (var start = 0; start < customers.length; start += batchSize) {
      final end = (start + batchSize > customers.length) ? customers.length : start + batchSize;
      final batch = customers.sublist(start, end);

      await db.transaction((txn) async {
        for (final customer in batch) {
          await customerStore.add(txn, customer.toJson());

          if (customer.salesRepId.isNotEmpty && seenDspIds.add(customer.salesRepId)) {
            await dspStore.add(txn, _buildDspRecord(customer));
          }
        }
      });

      if (total > 0) {
        onProgress?.call(0.35 + ((end / total) * 0.65));
      }
      await Future<void>.delayed(Duration.zero);
    }

    await _savePersistedCml(bytes, isXlsx: isXlsx);
    _attemptedLocationRepair = true;
  }

  Future<void> importDSPList(Uint8List bytes) async {
    final rows = _parseDspMasterFromBytes(bytes);
    if (rows.isEmpty) {
      throw Exception('No valid DSP rows found in CSV.');
    }

    _dspMasterOverrideBytes = bytes;
    await _savePersistedDspCsv(bytes);
  }

  Future<int> importAreaHierarchyCsv(Uint8List bytes) async {
    final rows = _parseAreaMasterFromBytes(bytes);
    if (rows.isEmpty) {
      throw Exception('No valid area rows found. Expected Province,City,Barangay CSV.');
    }

    _areaMasterOverrideBytes = bytes;
    await _savePersistedAreaCsv(bytes);
    return rows.length;
  }

  Future<int> importCustomerClassFile(Uint8List bytes, {required bool isXlsx}) async {
    final rows = _parseCustomerClassRowsFromBytes(bytes, isXlsx: isXlsx);
    if (rows.isEmpty) {
      throw Exception('No valid party classification rows found in file.');
    }

    _customerClassOverrideBytes = bytes;
    await _savePersistedCustomerClassFile(bytes);
    return rows.length;
  }

  Future<int> updateCML(Uint8List bytes, {bool isXlsx = false, void Function(double)? onProgress}) async {
    final db = await database;
    final incomingCustomers = await _parseCustomersFromBytes(
      bytes,
      isXlsx: isXlsx,
      onProgress: (p) => onProgress?.call(p * 0.30),
    );

    if (incomingCustomers.isEmpty) {
      onProgress?.call(1.0);
      return 0;
    }

    final existingDspRecords = await dspStore.find(db);
    final existingDspIds = existingDspRecords
        .map((record) => (record.value['sales_rep_id'] as String? ?? '').trim())
        .where((code) => code.isNotEmpty)
        .toSet();

    var added = 0;
    final total = incomingCustomers.length;
    for (var i = 0; i < incomingCustomers.length; i++) {
      final customer = incomingCustomers[i];
      final code = customer.customerCode.trim();
      if (code.isNotEmpty) {
        final existing = await customerStore.findFirst(
          db,
          finder: Finder(filter: Filter.equals('customer_code', code)),
        );

        if (existing == null) {
          await customerStore.add(db, customer.toJson());
          if (customer.salesRepId.isNotEmpty && existingDspIds.add(customer.salesRepId)) {
            await dspStore.add(db, _buildDspRecord(customer));
          }
          added++;
        }
      }

      if ((i + 1) % 100 == 0 || i == incomingCustomers.length - 1) {
        if (total > 0) {
          onProgress?.call(0.30 + (((i + 1) / total) * 0.70));
        }
        await Future<void>.delayed(Duration.zero);
      }
    }

    await _savePersistedCml(bytes, isXlsx: isXlsx);
    _attemptedLocationRepair = true;

    return added;
  }

  Future<void> _ensureLocationRepairAttempted() async {
    if (_attemptedLocationRepair) return;
    _attemptedLocationRepair = true;
    try {
      await repairMissingLocationFieldsFromPersistedCml();
    } catch (_) {
      // Best-effort repair; keep normal app flow even if repair is unavailable.
    }
  }

  Future<int> repairMissingLocationFieldsFromPersistedCml() async {
    final persisted = await _readPersistedCml();
    if (persisted == null) return 0;

    final bytes = persisted['bytes'] as Uint8List;
    final isXlsx = persisted['isXlsx'] == true;
    final importedCustomers = await _parseCustomersFromBytes(bytes, isXlsx: isXlsx);
    if (importedCustomers.isEmpty) return 0;

    final importedByCode = <String, Customer>{
      for (final c in importedCustomers)
        if (c.customerCode.trim().isNotEmpty) c.customerCode.trim(): c,
    };
    if (importedByCode.isEmpty) return 0;

    final db = await database;
    final records = await customerStore.find(db);
    var repaired = 0;

    for (final record in records) {
      final raw = Map<String, dynamic>.from(record.value);
      final code = (raw['customer_code'] as String? ?? '').trim();
      if (code.isEmpty) continue;

      final source = importedByCode[code];
      if (source == null) continue;

      final currentProvince = _cleanLocationValue(Customer.fromJson(raw).province);
      final currentCity = _cleanLocationValue(Customer.fromJson(raw).city);
      final currentBarangay = _cleanLocationValue(Customer.fromJson(raw).barangay);

      final sourceProvince = _cleanLocationValue(source.province);
      final sourceCity = _cleanLocationValue(source.city);
      final sourceBarangay = _cleanLocationValue(source.barangay);

      var changed = false;
      if (currentProvince.isEmpty && sourceProvince.isNotEmpty) {
        raw['province'] = sourceProvince;
        changed = true;
      }
      if (currentCity.isEmpty && sourceCity.isNotEmpty) {
        raw['city'] = sourceCity;
        changed = true;
      }
      if (currentBarangay.isEmpty && sourceBarangay.isNotEmpty) {
        raw['barangay'] = sourceBarangay;
        changed = true;
      }

      if (changed) {
        await customerStore.record(record.key).update(db, raw);
        repaired++;
      }
    }

    return repaired;
  }

  Future<List<Customer>> getCustomers() async {
    return getCustomersForCityBrgyCards();
  }

  Future<List<Customer>> getCustomersByDSP(String dspId, {String? status, String? coverageDay, String? wklyCoverage}) async {
    final db = await database;
    var filter = Filter.equals('sales_rep_id', dspId);
    if (status != null) {
      filter = filter & Filter.equals('status', status);
    }
    if (coverageDay != null) {
      filter = filter & Filter.equals('coverage_day', coverageDay);
    }
    if (wklyCoverage != null) {
      filter = filter & Filter.equals('wkly_coverage', wklyCoverage);
    }
    final records = await customerStore.find(db, finder: Finder(filter: filter));
    return records.map((record) => Customer.fromJson(record.value)).toList();
  }

  Future<List<Customer>> getCustomersFiltered({String? province, String? city, String? barangay, String? status}) async {
    await _ensureLocationRepairAttempted();
    return getCustomersForCityBrgyCards(
      province: province,
      city: city,
      barangay: barangay,
      status: status,
    );
  }

  Future<List<Customer>> getCustomersForCityBrgyCards({
    String? province,
    String? city,
    String? barangay,
    String? status,
  }) async {
    await _ensureLocationRepairAttempted();

    final db = await database;
    final selectedProvince = _canonicalLocationValue(province);
    final selectedCity = _canonicalLocationValue(city);
    final selectedBarangay = _canonicalLocationValue(barangay);
    final selectedStatus = (status ?? '').trim();

    final records = await customerStore.find(db);
    final result = <Customer>[];

    for (final record in records) {
      final raw = Map<String, dynamic>.from(record.value);
      final extracted = extractCanonicalLocationFields(raw);

      final canonicalProvince = extracted['province'] ?? '';
      final canonicalCity = extracted['city'] ?? '';
      final canonicalBarangay = extracted['barangay'] ?? '';

      raw['province'] = canonicalProvince;
      raw['city'] = canonicalCity;
      raw['barangay'] = canonicalBarangay;

      final customer = Customer.fromJson(raw);
      if (!_locationMatches(selectedCanonical: selectedProvince, actualRaw: customer.province)) {
        continue;
      }
      if (!_locationMatches(selectedCanonical: selectedCity, actualRaw: customer.city)) {
        continue;
      }
      if (!_locationMatches(selectedCanonical: selectedBarangay, actualRaw: customer.barangay)) {
        continue;
      }
      if (selectedStatus.isNotEmpty && customer.status.trim() != selectedStatus) {
        continue;
      }
      result.add(customer);
    }

    return result;
  }

  Future<void> updateCustomer(Customer customer) async {
    final db = await database;
    final record = await customerStore.findFirst(db, finder: Finder(filter: Filter.equals('customer_code', customer.customerCode)));
    if (record != null) {
      await customerStore.record(record.key).update(db, customer.toJson());
    }
  }

  Future<CustomerCounts> getCounts() async {
    final db = await database;
    final overall = await customerStore.count(db);
    final active = await customerStore.count(
      db,
      filter: Filter.equals('status', 'Active/Approved'),
    );
    final inactive = overall - active;
    return CustomerCounts(overall: overall, active: active, inactive: inactive);
  }

  Future<int> getEditedCount() async {
    final db = await database;
    return customerStore.count(db, filter: Filter.and([
      Filter.notEquals('edited_fields', null),
      Filter.notEquals('edited_fields', ''),
    ]));
  }

  Future<List<DSP>> fetchDSPs() async {
    final db = await database;
    final masterByCode = <String, Map<String, dynamic>>{};
    final masterRows = await _loadDspMasterRows();
    for (final row in masterRows) {
      final code = _normalizeDspCode((row['sales_rep_id'] ?? '').toString());
      if (code.isEmpty) continue;
      masterByCode[code] = row;
    }

    final customerRecords = await customerStore.find(db);
    final dspMap = <String, Map<String, dynamic>>{};

    for (var record in customerRecords) {
      final data = record.value;
      final rawSalesRepId = (data['sales_rep_id'] as String? ?? '').trim();
      final salesRepId = _normalizeDspCode(rawSalesRepId);
      if (salesRepId.isNotEmpty) {
        if (!dspMap.containsKey(salesRepId)) {
          dspMap[salesRepId] = {
            'sales_rep_id': rawSalesRepId,
            'dsp_code': '',
            'sales_rep_name': '',
            'team': '',
            'supervisor': '',
            'active_count': 0,
            'blocked_count': 0,
          };
        }
        if (data['status'] == 'Active/Approved') {
          dspMap[salesRepId]!['active_count'] = (dspMap[salesRepId]!['active_count'] as int) + 1;
        } else {
          dspMap[salesRepId]!['blocked_count'] = (dspMap[salesRepId]!['blocked_count'] as int) + 1;
        }
      }
    }

    for (final code in masterByCode.keys) {
      dspMap.putIfAbsent(
        code,
        () => {
          'sales_rep_id': '',
          'dsp_code': code,
          'sales_rep_name': '',
          'team': '',
          'supervisor': '',
          'active_count': 0,
          'blocked_count': 0,
        },
      );
    }

    for (final entry in dspMap.entries) {
      final code = entry.key;
      final master = masterByCode[code];
      if (master == null) continue;

      final masterName = (master['sales_rep_name'] as String? ?? '').trim();
      if (masterName.isNotEmpty) {
        entry.value['sales_rep_name'] = masterName;
      }
      entry.value['dsp_code'] = code;
      entry.value['team'] = (master['team'] as String? ?? '').trim();
      entry.value['supervisor'] = (master['supervisor'] as String? ?? '').trim();
    }

    final list = dspMap.values.map((dsp) => DSP.fromJson(dsp)).toList();
    list.sort((a, b) {
      final aCode = a.dspCode.isNotEmpty ? a.dspCode : a.salesRepId;
      final bCode = b.dspCode.isNotEmpty ? b.dspCode : b.salesRepId;
      return aCode.compareTo(bCode);
    });
    return list;
  }

  Future<List<Customer>> getEditedCustomers() async {
    final db = await database;
    final records = await customerStore.find(db, finder: Finder(filter: Filter.and([
      Filter.notEquals('edited_fields', null),
      Filter.notEquals('edited_fields', ''),
    ])));
    return records.map((record) => Customer.fromJson(record.value)).toList();
  }

  Future<List<Map<String, dynamic>>> loadAreas() async {
    final masterAreas = await _loadAreaMasterRows();
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];

    for (final area in masterAreas) {
      final province = _cleanLocationValue(area['province'] as String?);
      final city = _cleanLocationValue(area['city'] as String?);
      final barangay = _cleanLocationValue(area['barangay'] as String?);
      if (province.isEmpty || city.isEmpty || barangay.isEmpty) continue;

      final key = '${_canonicalLocationValue(province)}|${_canonicalLocationValue(city)}|${_canonicalLocationValue(barangay)}';
      if (seen.add(key)) {
        result.add({'province': province, 'city': city, 'barangay': barangay});
      }
    }

    final db = await database;
    final records = await customerStore.find(db);
    for (final record in records) {
      final raw = Map<String, dynamic>.from(record.value);
      final extracted = extractCanonicalLocationFields(raw);
      final province = _cleanLocationValue(extracted['province']);
      final city = _cleanLocationValue(extracted['city']);
      final barangay = _cleanLocationValue(extracted['barangay']);
      if (province.isEmpty || city.isEmpty || barangay.isEmpty) continue;

      final key = '${_canonicalLocationValue(province)}|${_canonicalLocationValue(city)}|${_canonicalLocationValue(barangay)}';
      if (seen.add(key)) {
        result.add({'province': province, 'city': city, 'barangay': barangay});
      }
    }

    // Keep dropdown values stable and easier to scan.
    result.sort((a, b) {
      final p = (a['province'] as String).compareTo(b['province'] as String);
      if (p != 0) return p;
      final c = (a['city'] as String).compareTo(b['city'] as String);
      if (c != 0) return c;
      return (a['barangay'] as String).compareTo(b['barangay'] as String);
    });

    return result;
  }

  Future<List<Map<String, dynamic>>> loadAreaHierarchy() async {
    final rows = await _loadAreaMasterRows();
    return rows;
  }

  Future<List<String>> loadPartyClassifications() async {
    return _loadCustomerClassRows();
  }

  Future<List<Map<String, dynamic>>> loadCustomerAreas() async {
    await _ensureLocationRepairAttempted();
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];

    final db = await database;
    final records = await customerStore.find(db);
    for (final record in records) {
      final raw = Map<String, dynamic>.from(record.value);
      final extracted = extractCanonicalLocationFields(raw);
      final province = _cleanLocationValue(extracted['province']);
      final city = _cleanLocationValue(extracted['city']);
      final barangay = _cleanLocationValue(extracted['barangay']);
      if (province.isEmpty || city.isEmpty || barangay.isEmpty) continue;

      final key = '${_canonicalLocationValue(province)}|${_canonicalLocationValue(city)}|${_canonicalLocationValue(barangay)}';
      if (seen.add(key)) {
        result.add({'province': province, 'city': city, 'barangay': barangay});
      }
    }

    result.sort((a, b) {
      final p = (a['province'] as String).compareTo(b['province'] as String);
      if (p != 0) return p;
      final c = (a['city'] as String).compareTo(b['city'] as String);
      if (c != 0) return c;
      return (a['barangay'] as String).compareTo(b['barangay'] as String);
    });

    // If CML DB records don't have usable location fields yet,
    // fall back to area master options so filters stay usable.
    if (result.isEmpty) {
      return loadAreas();
    }

    return result;
  }

  Future<void> clearAllData({void Function(double)? onProgress}) async {
    final db = await database;
    final customerKeys = await customerStore.findKeys(db);
    final dspKeys = await dspStore.findKeys(db);
    final total = customerKeys.length + dspKeys.length;

    if (total == 0) {
      onProgress?.call(1.0);
      return;
    }

    var processed = 0;
    for (final key in customerKeys) {
      await customerStore.record(key).delete(db);
      processed++;
      onProgress?.call(processed / total);
    }
    for (final key in dspKeys) {
      await dspStore.record(key).delete(db);
      processed++;
      onProgress?.call(processed / total);
    }
  }

  Future<String> exportEditedCustomers() async {
    final customers = await getEditedCustomers();
    List<List<dynamic>> csvData = [
      ['Customer Code', 'Customer Name', 'Barangay', 'City', 'Province', 'Status', 'Retail Environment', 'Party Classification Description', 'Coverage Day', 'Wkly Coverage', 'Freq Count', 'Freq', 'Latitude', 'Longitude', 'Phone', 'First Name', 'Last Name', 'Address', 'TIN No', 'Edited Fields']
    ];
    for (var customer in customers) {
      csvData.add([
        customer.customerCode,
        customer.customerName,
        customer.barangay,
        customer.city,
        customer.province,
        customer.status,
        customer.retailEnvironment,
        customer.partyClassificationDescription,
        customer.coverageDay,
        customer.wklyCoverage,
        customer.freqCount,
        customer.freq,
        customer.latitude,
        customer.longitude,
        customer.phone,
        customer.firstName,
        customer.lastName,
        customer.address,
        customer.tinNo,
        customer.editedFields ?? '',
      ]);
    }
    return ListToCsvConverter().convert(csvData);
  }

  Future<Uint8List> exportEditedCustomersXlsx({void Function(double)? onProgress}) async {
    final customers = await getEditedCustomers();
    final excel = xl.Excel.createExcel();
    final sheet = excel['Edited Customers'];

    sheet.appendRow([
      xl.TextCellValue('Customer Code'),
      xl.TextCellValue('Customer Name'),
      xl.TextCellValue('Barangay'),
      xl.TextCellValue('City'),
      xl.TextCellValue('Province'),
      xl.TextCellValue('Status'),
      xl.TextCellValue('Retail Environment'),
      xl.TextCellValue('Party Classification Description'),
      xl.TextCellValue('Coverage Day'),
      xl.TextCellValue('Wkly Coverage'),
      xl.TextCellValue('Freq Count'),
      xl.TextCellValue('Freq'),
      xl.TextCellValue('Latitude'),
      xl.TextCellValue('Longitude'),
      xl.TextCellValue('Phone'),
      xl.TextCellValue('First Name'),
      xl.TextCellValue('Last Name'),
      xl.TextCellValue('Address'),
      xl.TextCellValue('TIN No'),
      xl.TextCellValue('Edited Fields')
    ]);

    if (customers.isEmpty) {
      onProgress?.call(1.0);
      return Uint8List.fromList(excel.encode() ?? <int>[]);
    }

    for (var i = 0; i < customers.length; i++) {
      final customer = customers[i];
      sheet.appendRow([
        xl.TextCellValue(customer.customerCode),
        xl.TextCellValue(customer.customerName),
        xl.TextCellValue(customer.barangay),
        xl.TextCellValue(customer.city),
        xl.TextCellValue(customer.province),
        xl.TextCellValue(customer.status),
        xl.TextCellValue(customer.retailEnvironment),
        xl.TextCellValue(customer.partyClassificationDescription),
        xl.TextCellValue(customer.coverageDay),
        xl.TextCellValue(customer.wklyCoverage),
        xl.IntCellValue(customer.freqCount),
        xl.TextCellValue(customer.freq),
        xl.TextCellValue(customer.latitude?.toString() ?? ''),
        xl.TextCellValue(customer.longitude?.toString() ?? ''),
        xl.TextCellValue(customer.phone),
        xl.TextCellValue(customer.firstName),
        xl.TextCellValue(customer.lastName),
        xl.TextCellValue(customer.address),
        xl.TextCellValue(customer.tinNo),
        xl.TextCellValue(customer.editedFields ?? ''),
      ]);
      onProgress?.call((i + 1) / customers.length);
    }

    final bytes = excel.encode();
    return Uint8List.fromList(bytes ?? <int>[]);
  }

  Future<int> clearEditedCustomersFlags() async {
    final db = await database;
    final records = await customerStore.find(db, finder: Finder(filter: Filter.and([
      Filter.notEquals('edited_fields', null),
      Filter.notEquals('edited_fields', ''),
    ])));

    for (final record in records) {
      final updated = Map<String, dynamic>.from(record.value);
      updated['edited_fields'] = '';
      await customerStore.record(record.key).put(db, updated);
    }

    return records.length;
  }
}

String _normalizeHeaderForParse(String raw) {
  return raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_');
}

String _cleanLocationForParse(String? raw) {
  final trimmed = (raw ?? '').trim();
  return trimmed
      .replaceAll(RegExp("^['\"]+"), '')
      .replaceAll(RegExp("['\"]+\$"), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
}

List<Map<String, dynamic>> _parseCustomerRowsInIsolate({
  required Uint8List bytes,
  required bool isXlsx,
}) {
  List<String> header;
  List<List<dynamic>> dataRows;

  if (isXlsx) {
    final excel = xl.Excel.decodeBytes(bytes);
    if (excel.tables.isEmpty) return const <Map<String, dynamic>>[];
    final sheet = excel.tables.values.first;
    if (sheet.rows.isEmpty) return const <Map<String, dynamic>>[];

    header = sheet.rows.first
        .map((cell) => _normalizeHeaderForParse(cell?.value?.toString() ?? ''))
        .toList();
    dataRows = sheet.rows
        .skip(1)
        .map((row) => row.map((cell) => cell?.value?.toString() ?? '').toList())
        .toList();
  } else {
    final csvContent = String.fromCharCodes(bytes)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final csvTable = CsvToListConverter(eol: '\n', shouldParseNumbers: false)
        .convert(csvContent);
    if (csvTable.isEmpty) return const <Map<String, dynamic>>[];

    header = csvTable.first
        .map((value) => _normalizeHeaderForParse(value.toString()))
        .toList();
    dataRows = csvTable.skip(1).toList();
  }

  final headerMap = <String, int>{
    for (var i = 0; i < header.length; i++) header[i]: i,
  };

  int getIndex(List<String> names) {
    for (final name in names) {
      final normalized = _normalizeHeaderForParse(name);
      final idx = headerMap[normalized];
      if (idx != null) return idx;
    }
    return -1;
  }

  String field(List<String> names, List<dynamic> row, [String defaultValue = '']) {
    final idx = getIndex(names);
    if (idx < 0 || idx >= row.length) return defaultValue;
    return row[idx].toString();
  }

  final result = <Map<String, dynamic>>[];
  for (final row in dataRows) {
    if (row.every((cell) => cell == null || cell.toString().trim().isEmpty)) {
      continue;
    }

    final rawFirstName = field(['first_name', 'first name'], row);
    final rawLastName = field(['last_name', 'last name'], row);
    final rawOwner = field(['owner'], row);

    var resolvedFirstName = rawFirstName;
    var resolvedLastName = rawLastName;
    if (resolvedFirstName.trim().isEmpty &&
        resolvedLastName.trim().isEmpty &&
        rawOwner.trim().isNotEmpty) {
      final parts = rawOwner.trim().split(RegExp(r'\s+'));
      resolvedFirstName = parts.first;
      resolvedLastName = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    }

    result.add({
      'branch_name': field(['branch_name', 'branch name'], row),
      'cdam': field(['cdam'], row),
      'fs': field(['fs'], row),
      'channel': field(['channel'], row),
      'sales_rep_id': field(['sales_rep_id', 'sales rep id', 'salesrep_id', 'salesrepid'], row),
      'sales_rep_name': field(['sales_rep_name', 'sales rep name', 'salesrep_name', 'salesrepname'], row),
      'customer_code': field(['customer_code', 'customer code'], row),
      'customer_name': field(['customer_name', 'customer name'], row),
      'barangay': _cleanLocationForParse(field([
        'barangay',
        'brgy',
        'barangay_name',
        'barangay name',
        'brgy_name',
        'brgy name',
        'barangay_brgy',
        'barangay/brgy',
      ], row)),
      'city': _cleanLocationForParse(field([
        'city',
        'municipality',
        'city_municipality',
        'city municipality',
        'city/municipality',
        'city_mun',
        'city mun',
        'town',
        'city_town',
        'city/town',
      ], row)),
      'province': _cleanLocationForParse(field([
        'province',
        'province_name',
        'province name',
        'prov',
      ], row)),
      'status': field(['status'], row),
      'retail_environment': field(['retail_environment', 'retail environment'], row),
      'party_classification_description': field([
        'party_classification_description',
        'party classification description',
      ], row),
      'coverage_day': field(['coverage_day', 'coverage day'], row),
      'wkly_coverage': field(['wkly_coverage', 'wkly coverage'], row),
      'freq_count': int.tryParse(field(['freq_count', 'freq count'], row, '0')) ?? 0,
      'freq': field(['freq'], row),
      'latitude': double.tryParse(field(['latitude', 'lat', 'gps_latitude', 'gps latitude'], row)),
      'longitude': double.tryParse(field(['longitude', 'long', 'lng', 'gps_longitude', 'gps longitude'], row)),
      'phone': field(['phone'], row),
      'first_name': resolvedFirstName,
      'last_name': resolvedLastName,
      'address': field(['address'], row),
      'tin_no': field(['tin_no', 'tin no'], row),
    });
  }

  return result;
}