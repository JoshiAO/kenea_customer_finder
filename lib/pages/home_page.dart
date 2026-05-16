import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../config/app_private_config.dart';
import '../services/database_service.dart';
import '../services/app_customization_notifier.dart';
import '../services/import_notifier.dart';
import '../models/counts.dart';
import '../models/customer.dart';
import 'customer_update_form.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Future<CustomerCounts> _countsFuture;
  late Future<int> _editedCountFuture;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  void _loadData() {
    _countsFuture = DatabaseService().getCounts();
    _editedCountFuture = DatabaseService().getEditedCount();
  }

  void _refresh() {
    setState(() {
      _loadData();
    });
  }

  String _timestamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  Future<String?> _saveZipToDownloads(Uint8List bytes, String fileName) async {
    if (kIsWeb) {
      await FileSaver.instance.saveFile(
        name: fileName.replaceAll('.zip', ''),
        bytes: bytes,
        ext: 'zip',
        mimeType: MimeType.zip,
      );
      return 'Downloads';
    }

    try {
      Directory? targetDir;

      if (Platform.isAndroid) {
        final androidDownloads = Directory('/storage/emulated/0/Download');
        if (await androidDownloads.exists()) {
          targetDir = androidDownloads;
        }
      } else {
        targetDir = await getDownloadsDirectory();
      }

      if (targetDir != null) {
        final file = File('${targetDir.path}/$fileName');
        await file.writeAsBytes(bytes, flush: true);
        return file.path;
      }
    } catch (_) {
      // fall through to FileSaver fallback
    }

    await FileSaver.instance.saveFile(
      name: fileName.replaceAll('.zip', ''),
      bytes: bytes,
      ext: 'zip',
      mimeType: MimeType.zip,
    );
    return null;
  }

  Future<_CmlSelection?> _pickCmlFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx'],
      withData: true,
    );
    if (result == null) return null;

    final file = result.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      throw Exception('Unable to read file bytes from selected file.');
    }

    return _CmlSelection(
      bytes: bytes,
      isXlsx: file.extension?.toLowerCase() == 'xlsx',
    );
  }

  Future<Uint8List> _buildEditedCustomersZip({void Function(double)? onProgress}) async {
    final customers = await DatabaseService().getEditedCustomers();
    final archive = Archive();

    final xlsxBytes = await DatabaseService().exportEditedCustomersXlsx(
      onProgress: (pVal) => onProgress?.call(pVal * 0.4),
    );
    archive.addFile(ArchiveFile('edited_customers.xlsx', xlsxBytes.length, xlsxBytes));

    if (kIsWeb || customers.isEmpty) {
      onProgress?.call(1.0);
      return Uint8List.fromList(ZipEncoder().encode(archive) ?? <int>[]);
    }

    final appDir = await getApplicationDocumentsDirectory();
    final capturesRoot = Directory(p.join(appDir.path, 'captured_images'));

    for (var i = 0; i < customers.length; i++) {
      final customer = customers[i];
      final folderName = DatabaseService.customerImageFolderName(customer);
      final customerDir = Directory(p.join(capturesRoot.path, folderName));

      if (await customerDir.exists()) {
        final imageFiles = customerDir
            .listSync()
            .whereType<File>()
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

        for (final imageFile in imageFiles) {
          final bytes = await imageFile.readAsBytes();
          final zipPath = '$folderName/${p.basename(imageFile.path)}';
          archive.addFile(ArchiveFile(zipPath, bytes.length, bytes));
        }
      }

      onProgress?.call(0.4 + ((i + 1) / customers.length) * 0.6);
    }

    return Uint8List.fromList(ZipEncoder().encode(archive) ?? <int>[]);
  }

  Future<void> _importCML() async {
    final counts = await DatabaseService().getCounts();
    if (!mounted) return;
    if (counts.overall > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please clear data first before importing a new CML file.'),
        ),
      );
      return;
    }

    final notifier = context.read<ImportNotifier>();
    final selected = await _pickCmlFile();
    if (selected == null) return;

    final opId = notifier.start(label: 'Importing CML', type: 'import');

    try {
      await DatabaseService().importCML(
        selected.bytes,
        isXlsx: selected.isXlsx,
        onProgress: (p) => notifier.update(opId, p),
      );
      setState(() => _loadData());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Import successful. Existing records were replaced by the new CML data.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import failed: $e')),
        );
      }
    } finally {
      notifier.finish(opId);
    }
  }

  Future<void> _updateCML() async {
    final notifier = context.read<ImportNotifier>();
    final selected = await _pickCmlFile();
    if (selected == null) return;

    final opId = notifier.start(label: 'Updating CML', type: 'update');

    try {
      final added = await DatabaseService().updateCML(
        selected.bytes,
        isXlsx: selected.isXlsx,
        onProgress: (p) => notifier.update(opId, p),
      );

      setState(() => _loadData());
      if (mounted) {
        final msg = added == 0
            ? 'Local database and the new CML file have the same customer records.'
            : 'Update successful. Added $added new customer(s).';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update failed: $e')),
        );
      }
    } finally {
      notifier.finish(opId);
    }
  }

  Future<void> _clearData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Clear Data'),
          content: const Text(
            'This will remove all customer and DSP records from local storage. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Clear'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;
    if (!mounted) return;

    final notifier = context.read<ImportNotifier>();
    final opId = notifier.start(label: 'Clearing local data', type: 'clear');

    try {
      await DatabaseService().clearAllData(
        onProgress: (p) => notifier.update(opId, p),
      );
      if (!mounted) return;
      setState(() => _loadData());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Local data cleared.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Clear data failed: $e')),
      );
    } finally {
      notifier.finish(opId);
    }
  }

  Future<void> _exportEdited() async {
    final notifier = context.read<ImportNotifier>();
    final opId = notifier.start(label: 'Exporting edited customers archive', type: 'export');

    try {
      final zipBytes = await _buildEditedCustomersZip(
        onProgress: (p) => notifier.update(opId, p),
      );
      final fileName = 'edited_customers_archive_${_timestamp()}.zip';
      final savedPath = await _saveZipToDownloads(zipBytes, fileName);
      final cleared = await DatabaseService().clearEditedCustomersFlags();
      if (!mounted) return;

      setState(() => _loadData());
      final message = savedPath == null
          ? 'Exported ZIP archive. Check your Downloads folder. Cleared $cleared edited record(s).'
          : 'Exported ZIP to: $savedPath. Cleared $cleared edited record(s).';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    } finally {
      notifier.finish(opId);
    }
  }

  Future<void> _showEditedCustomers() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.9,
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Edited Customers',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: FutureBuilder<List<Customer>>(
                      future: DatabaseService().getEditedCustomers(),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return const Center(child: CircularProgressIndicator());
                        }
                        if (snapshot.hasError) {
                          return Center(child: Text('Error: ${snapshot.error}'));
                        }

                        final editedCustomers = snapshot.data ?? <Customer>[];
                        if (editedCustomers.isEmpty) {
                          return const Center(child: Text('No edited customers found.'));
                        }

                        return ListView.builder(
                          itemCount: editedCustomers.length,
                          itemBuilder: (context, index) {
                            final customer = editedCustomers[index];
                            final editedFields = (customer.editedFields ?? '').trim();

                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 6),
                              child: Padding(
                                padding: const EdgeInsets.all(12.0),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            customer.customerName,
                                            style: const TextStyle(fontWeight: FontWeight.w600),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(customer.customerCode),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.center,
                                        children: [
                                          const Text(
                                            'Edited Fields',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            editedFields.isEmpty ? '-' : editedFields,
                                            textAlign: TextAlign.center,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                        minimumSize: const Size(0, 32),
                                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      onPressed: () async {
                                        await Navigator.of(sheetContext).push(
                                          MaterialPageRoute(
                                            builder: (_) => CustomerUpdateForm(customer: customer),
                                          ),
                                        );
                                        if (!mounted) return;
                                        setState(_loadData);
                                      },
                                      child: const Text('View'),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickHomeBackgroundImage() async {
    final pickerResult = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );

    if (pickerResult == null || pickerResult.files.isEmpty) return;
    final selected = pickerResult.files.single;
    final bytes = selected.bytes;
    if (bytes == null || bytes.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to read selected image.')),
      );
      return;
    }

    final extRaw = selected.extension?.toLowerCase() ?? 'png';
    final ext = extRaw.startsWith('.') ? extRaw : '.$extRaw';
    if (!mounted) return;
    final customization = context.read<AppCustomizationNotifier>();
    await customization.setHomeBackgroundImage(bytes: bytes, extension: ext);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Home background updated.')),
    );
  }

  Future<void> _pickLaunchLogoImage() async {
    final pickerResult = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );

    if (pickerResult == null || pickerResult.files.isEmpty) return;
    final selected = pickerResult.files.single;
    final bytes = selected.bytes;
    if (bytes == null || bytes.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to read selected launch image.')),
      );
      return;
    }

    final extRaw = selected.extension?.toLowerCase() ?? 'png';
    final ext = extRaw.startsWith('.') ? extRaw : '.$extRaw';
    if (!mounted) return;
    final customization = context.read<AppCustomizationNotifier>();
    await customization.setLaunchLogoImage(bytes: bytes, extension: ext);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Launch logo updated.')),
    );
  }

  Future<void> _showThemeCustomizationSheet() async {
    const seedOptions = <Color>[
      Color(0xFF2F3240),
      Color(0xFF2F7FD1),
      Color(0xFF0F766E),
      Color(0xFFB45309),
      Color(0xFF9D174D),
      Color(0xFF4C1D95),
      Color(0xFF374151),
    ];

    if (!mounted) return;
    final customization = context.read<AppCustomizationNotifier>();
    var launchTitleDraft = customization.launchTitle;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return Consumer<AppCustomizationNotifier>(
          builder: (context, customizationState, _) {
            final scheme = Theme.of(context).colorScheme;
            final isJoshiLocked = customizationState.isJoshiAOTheme;
            return SafeArea(
              child: AnimatedPadding(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
                child: FractionallySizedBox(
                  heightFactor: 0.9,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
              Text(
                'Theme & Personalization',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: customizationState.themeName,
                decoration: const InputDecoration(
                  labelText: 'Theme Preset',
                  border: OutlineInputBorder(),
                ),
                items: customizationState.availableThemeNames
                    .map((name) => DropdownMenuItem<String>(
                          value: name,
                          child: Text(name),
                        ))
                    .toList(),
                onChanged: (value) {
                  if (value == null) return;
                  customization.setThemeName(value);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ThemeMode>(
                initialValue: customizationState.themeMode,
                decoration: InputDecoration(
                  labelText: 'Theme Mode',
                  border: OutlineInputBorder(),
                  helperText: isJoshiLocked ? 'Locked in JoshiAO Theme (Dark mode).' : null,
                ),
                items: const [
                  DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
                  DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                  DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
                ],
                onChanged: isJoshiLocked ? null : (value) {
                  if (value == null) return;
                  customization.setThemeMode(value);
                },
              ),
              const SizedBox(height: 14),
              Text(
                'Accent Color',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final color in seedOptions)
                    InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: isJoshiLocked ? null : () => customization.setSeedColor(color),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: customizationState.seedColor.toARGB32() == color.toARGB32()
                                ? scheme.onSurface
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (isJoshiLocked)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Accent color is locked for JoshiAO Theme.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickHomeBackgroundImage,
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('Import Background'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextButton.icon(
                      onPressed: customizationState.homeBackgroundImageProvider == null
                          ? null
                          : customization.clearHomeBackgroundImage,
                      icon: const Icon(Icons.hide_image_outlined),
                      label: const Text('Remove Background'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                'Launch Branding',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              TextFormField(
                initialValue: launchTitleDraft,
                onChanged: (value) {
                  launchTitleDraft = value;
                },
                decoration: const InputDecoration(
                  labelText: 'Launch Text',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => customization.setLaunchTitle(launchTitleDraft),
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save Launch Text'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickLaunchLogoImage,
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('Import Launch Logo'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextButton.icon(
                      onPressed: customizationState.launchLogoImageProvider == null
                          ? null
                          : customization.clearLaunchLogoImage,
                      icon: const Icon(Icons.restore_outlined),
                      label: const Text('Use Default Launch Logo'),
                    ),
                  ),
                ],
              ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final customization = context.watch<AppCustomizationNotifier>();
    final scheme = Theme.of(context).colorScheme;
    final backgroundImage = customization.homeBackgroundImageProvider;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: isDark
            ? Colors.white.withValues(alpha: 0.98)
            : scheme.onSurface.withValues(alpha: 0.94),
        iconTheme: IconThemeData(
          color: isDark
              ? Colors.white.withValues(alpha: 0.98)
              : scheme.onSurface.withValues(alpha: 0.94),
        ),
        actionsIconTheme: IconThemeData(
          color: isDark
              ? Colors.white.withValues(alpha: 0.98)
              : scheme.onSurface.withValues(alpha: 0.94),
        ),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(
                  scheme.primary.withValues(alpha: isDark ? 0.42 : 0.20),
                  scheme.surface,
                ),
                Color.alphaBlend(
                  scheme.tertiary.withValues(alpha: isDark ? 0.34 : 0.16),
                  scheme.surface,
                ),
              ],
            ),
            border: Border(
              bottom: BorderSide(
                color: scheme.outline.withValues(alpha: isDark ? 0.38 : 0.22),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: isDark ? 0.22 : 0.12),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
        ),
        leadingWidth: 64,
        leading: Padding(
          padding: const EdgeInsets.only(left: 10, top: 8, bottom: 8),
          child: Material(
            color: scheme.surface.withValues(alpha: isDark ? 0.20 : 0.32),
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: _showThemeCustomizationSheet,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.palette_outlined),
              ),
            ),
          ),
        ),
        title: Text(
          AppPrivateConfig.appName,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
            color: isDark
                ? Colors.white.withValues(alpha: 0.98)
                : scheme.onSurface.withValues(alpha: 0.94),
          ),
        ),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10, top: 8, bottom: 8),
            child: Material(
              color: scheme.surface.withValues(alpha: isDark ? 0.20 : 0.32),
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: _refresh,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.refresh),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color.alphaBlend(
                      scheme.primary.withValues(alpha: isDark ? 0.12 : 0.06),
                      scheme.surface,
                    ),
                    Color.alphaBlend(
                      scheme.secondary.withValues(alpha: isDark ? 0.16 : 0.08),
                      scheme.surface,
                    ),
                    scheme.surface,
                  ],
                ),
              ),
            ),
          ),
          if (backgroundImage != null)
            Positioned.fill(
              child: IgnorePointer(
                child: Image(
                  image: backgroundImage,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                ),
              ),
            ),
          if (backgroundImage != null)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: isDark
                      ? Colors.black.withValues(alpha: 0.35)
                      : Colors.white.withValues(alpha: 0.28),
                ),
              ),
            ),
          Positioned(
            left: -24,
            right: -24,
            bottom: -20,
            child: IgnorePointer(
              child: Opacity(
                opacity: isDark ? 0.10 : 0.18,
                child: Image.asset(
                  'assets/images/Cluster 1-6.png',
                  fit: BoxFit.fitWidth,
                  errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      if (isDark) ...[
                        Colors.black.withValues(alpha: 0.26),
                        Colors.black.withValues(alpha: 0.18),
                        Colors.black.withValues(alpha: 0.10),
                      ] else ...[
                        const Color(0xCCFFFFFF),
                        const Color(0xB3FFFFFF),
                        const Color(0x99FFFFFF),
                      ],
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: FutureBuilder<CustomerCounts>(
              future: _countsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const CircularProgressIndicator();
                } else if (snapshot.hasError) {
                  return Text('Error: ${snapshot.error}');
                } else {
                  final counts = snapshot.data!;
                  const actionButtonsWidth = 258.0;
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 18),
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Color.alphaBlend(
                              scheme.primary.withValues(alpha: 0.10),
                              scheme.surface,
                            ).withValues(alpha: 0.94)
                          : scheme.surface.withValues(alpha: 0.84),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: isDark
                            ? scheme.outline.withValues(alpha: 0.35)
                            : scheme.primaryContainer,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: isDark ? 0.24 : 0.15),
                          blurRadius: 16,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Overall - ${counts.overall}',
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'Active - ${counts.active}',
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'Inactive - ${counts.inactive}',
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 20),
                        FutureBuilder<int>(
                          future: _editedCountFuture,
                          builder: (context, editedSnapshot) {
                            if (editedSnapshot.hasData) {
                              return Text(
                                'Edited Customers - ${editedSnapshot.data}',
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              );
                            }
                            return const SizedBox();
                          },
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: actionButtonsWidth,
                          child: Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: ElevatedButton(
                                  onPressed: _importCML,
                                  child: const Text('Import CML'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 2,
                                child: ElevatedButton(
                                  onPressed: _clearData,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: scheme.errorContainer,
                                    foregroundColor: scheme.onErrorContainer,
                                  ),
                                  child: const Icon(Icons.delete_outline),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: actionButtonsWidth,
                          child: ElevatedButton(
                            onPressed: _updateCML,
                            child: const Text('Update CML'),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: actionButtonsWidth,
                          child: Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: _showEditedCustomers,
                                  child: const Text('Show Edit'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: _exportEdited,
                                  child: const Text('Export Edit'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CmlSelection {
  const _CmlSelection({required this.bytes, required this.isXlsx});

  final Uint8List bytes;
  final bool isXlsx;
}