import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../services/database_service.dart';
import '../services/app_customization_notifier.dart';
import '../models/customer.dart';
import '../widgets/customer_info_modal.dart';
import '../widgets/branded_app_bar.dart';

class CityBrgyPage extends StatefulWidget {
  const CityBrgyPage({super.key});

  @override
  State<CityBrgyPage> createState() => _CityBrgyPageState();
}

class _CityBrgyPageState extends State<CityBrgyPage> {
  late Future<List<Customer>> _customersFuture;
  String? _selectedProvince;
  String? _selectedCity;
  String? _selectedBarangay;
  String? _selectedStatus;
  bool _onlyWithLocation = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  List<String> _provinces = [];
  List<String> _cities = [];
  List<String> _barangays = [];
  List<Map<String, dynamic>> _allAreas = [];

  String _normalizeLocationValue(String? value) {
    return (value ?? '')
      .replaceAll(RegExp("^['\"]+"), '')
      .replaceAll(RegExp("['\"]+\$"), '')
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  String _canonicalLocationValue(String? value) {
    return _normalizeLocationValue(value).replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  @override
  void initState() {
    super.initState();
    _loadAreas();
    _loadCustomers();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAreas() async {
    final areas = await DatabaseService().loadAreaHierarchy();
    _allAreas = areas;
    _provinces = areas
        .map<String>((a) => (a['province'] as String? ?? '').trim())
        .toSet()
        .where((s) => s.isNotEmpty)
        .toList()
      ..sort();

    if (_selectedProvince != null && !_provinces.contains(_selectedProvince)) {
      _selectedProvince = null;
      _selectedCity = null;
      _selectedBarangay = null;
      _cities = [];
      _barangays = [];
    }

    if (mounted) {
      setState(() {
        _loadCustomers();
      });
    }
  }

  Future<void> _importGeoHierarchyUpdate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Update Geo Hierarchy'),
          content: const Text(
            'Import a new Area.csv to overwrite the active geo hierarchy used by Province, City, and Barangay dropdowns?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Import'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    final selected = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      withData: true,
    );
    if (selected == null || selected.files.isEmpty) return;

    final bytes = selected.files.single.bytes;
    if (bytes == null || bytes.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to read selected CSV file.')),
      );
      return;
    }

    try {
      final count = await DatabaseService().importAreaHierarchyCsv(bytes);
      await _loadAreas();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Geo hierarchy updated. Loaded $count area rows.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Geo hierarchy update failed: $e')),
      );
    }
  }

  Future<void> _importPartyClassificationUpdate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Update Party Classification'),
          content: const Text(
            'Import a Party Classification file (CSV/XLSX) to refresh dropdown options used in Update Customer Info?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Import'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    final selected = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx'],
      withData: true,
    );
    if (selected == null || selected.files.isEmpty) return;

    final file = selected.files.single;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to read selected file.')),
      );
      return;
    }

    final isXlsx = (file.extension ?? '').toLowerCase() == 'xlsx';

    try {
      final count = await DatabaseService().importCustomerClassFile(bytes, isXlsx: isXlsx);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Party Classification updated. Loaded $count options.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Party Classification update failed: $e')),
      );
    }
  }

  void _updateCities() {
    if (_selectedProvince != null) {
      final selectedProvince = _canonicalLocationValue(_selectedProvince);
      _cities = _allAreas
          .where((a) => _canonicalLocationValue(a['province'] as String?) == selectedProvince)
          .map<String>((a) => (a['city'] as String? ?? '').trim())
          .toSet()
          .where((s) => s.isNotEmpty)
          .toList()
        ..sort();
      if (!_cities.contains(_selectedCity)) _selectedCity = null;
    } else {
      _cities = [];
      _selectedCity = null;
    }
    _updateBarangays();
    setState(() {});
  }

  void _updateBarangays() {
    if (_selectedProvince != null && _selectedCity != null) {
      final selectedProvince = _canonicalLocationValue(_selectedProvince);
      final selectedCity = _canonicalLocationValue(_selectedCity);
      _barangays = _allAreas
          .where((a) =>
          _canonicalLocationValue(a['province'] as String?) == selectedProvince &&
          _canonicalLocationValue(a['city'] as String?) == selectedCity)
          .map<String>((a) => (a['barangay'] as String? ?? '').trim())
          .toSet()
          .where((s) => s.isNotEmpty)
          .toList()
        ..sort();
      if (!_barangays.contains(_selectedBarangay)) _selectedBarangay = null;
    } else {
      _barangays = [];
      _selectedBarangay = null;
    }
    setState(() {});
  }

  void _loadCustomers() {
    _customersFuture = DatabaseService().getCustomersForCityBrgyCards(
      province: _selectedProvince,
      city: _selectedCity,
      barangay: _selectedBarangay,
      status: _selectedStatus,
    );
  }

  void _resetFilters() {
    setState(() {
      _selectedProvince = null;
      _selectedCity = null;
      _selectedBarangay = null;
      _selectedStatus = null;
      _onlyWithLocation = false;
      _searchQuery = '';
      _searchController.clear();
      _cities = [];
      _barangays = [];
      _loadCustomers();
    });
  }

  bool _hasValidLocation(Customer customer) {
    final lat = customer.latitude;
    final lng = customer.longitude;
    if (lat == null || lng == null) return false;
    return lat != 0 && lng != 0;
  }

  Widget _buildDropdown({
    required String hint,
    required String? value,
    required List<String> items,
    required void Function(String?) onChanged,
    required bool isJoshiTheme,
    required ColorScheme scheme,
    bool enabled = true,
  }) {
    final safeValue = (value != null && items.contains(value)) ? value : null;
    final baseBorderColor = isJoshiTheme
        ? Color.alphaBlend(scheme.primary.withValues(alpha: 0.70), scheme.surface)
        : scheme.outline;
    final focusedBorderColor = isJoshiTheme
        ? Color.alphaBlend(scheme.tertiary.withValues(alpha: 0.85), scheme.surface)
        : scheme.primary;

    return DropdownButtonFormField<String>(
      isExpanded: true,
      dropdownColor: isJoshiTheme
          ? Color.alphaBlend(scheme.primary.withValues(alpha: 0.30), scheme.surface)
          : null,
      style: TextStyle(
        color: isJoshiTheme ? Colors.white.withValues(alpha: 0.96) : scheme.onSurface,
      ),
      iconEnabledColor: isJoshiTheme ? Colors.white.withValues(alpha: 0.92) : null,
      iconDisabledColor: isJoshiTheme ? Colors.white.withValues(alpha: 0.42) : null,
      decoration: InputDecoration(
        filled: isJoshiTheme,
        fillColor: isJoshiTheme
            ? Color.alphaBlend(scheme.primary.withValues(alpha: 0.14), scheme.surface)
            : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: baseBorderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: baseBorderColor, width: 1.2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: focusedBorderColor, width: 1.6),
        ),
        isDense: true,
      ),
      hint: Text(
        hint,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isJoshiTheme ? Colors.white.withValues(alpha: 0.74) : null,
        ),
      ),
      initialValue: safeValue,
      items: [
        DropdownMenuItem<String>(
          value: null,
          child: Text(
            hint,
            style: TextStyle(
              color: isJoshiTheme ? Colors.white.withValues(alpha: 0.74) : Colors.grey[600],
            ),
          ),
        ),
        ...items.map(
          (item) => DropdownMenuItem<String>(
            value: item,
            child: Text(
              item,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isJoshiTheme ? Colors.white.withValues(alpha: 0.96) : null,
              ),
            ),
          ),
        ),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final customization = context.watch<AppCustomizationNotifier>();
    final isJoshiTheme = customization.isJoshiAOTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: buildBrandedAppBar(
        context: context,
        title: Text('City/Brgy'),
        actions: [
          IconButton(
            onPressed: _importGeoHierarchyUpdate,
            icon: const Icon(Icons.upload_file),
            tooltip: 'Geo Hierarchy Update',
          ),
          IconButton(
            onPressed: _importPartyClassificationUpdate,
            icon: const Icon(Icons.rule_folder),
            tooltip: 'Party Classification Update',
          ),
          IconButton(
            onPressed: () {
              setState(() {
                _onlyWithLocation = !_onlyWithLocation;
              });
            },
            icon: Icon(
              _onlyWithLocation ? Icons.location_on : Icons.location_off,
            ),
            tooltip: 'Only with Long-Lat',
          ),
          IconButton(
            onPressed: _resetFilters,
            icon: const Icon(Icons.filter_alt_off),
            tooltip: 'Reset Filters',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _searchController,
                    style: TextStyle(
                      color: isJoshiTheme ? Colors.white.withValues(alpha: 0.96) : scheme.onSurface,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Search by Customer Code, Name, or Person...',
                      hintStyle: TextStyle(
                        color: isJoshiTheme
                            ? Colors.white.withValues(alpha: 0.72)
                            : scheme.onSurface.withValues(alpha: 0.62),
                      ),
                      prefixIcon: Icon(
                        Icons.search,
                        color: isJoshiTheme ? Colors.white.withValues(alpha: 0.92) : null,
                      ),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: Icon(
                                Icons.clear,
                                color: isJoshiTheme ? Colors.white.withValues(alpha: 0.92) : null,
                              ),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      filled: isJoshiTheme,
                      fillColor: isJoshiTheme
                          ? Color.alphaBlend(scheme.primary.withValues(alpha: 0.14), scheme.surface)
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: isJoshiTheme
                              ? Color.alphaBlend(scheme.primary.withValues(alpha: 0.70), scheme.surface)
                              : scheme.outline,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: isJoshiTheme
                              ? Color.alphaBlend(scheme.primary.withValues(alpha: 0.70), scheme.surface)
                              : scheme.outline,
                          width: 1.2,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                          color: isJoshiTheme
                              ? Color.alphaBlend(scheme.tertiary.withValues(alpha: 0.85), scheme.surface)
                              : scheme.primary,
                          width: 1.6,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                      isDense: true,
                    ),
                    onChanged: (value) => setState(() => _searchQuery = value.toLowerCase()),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 1,
                  child: _buildDropdown(
                    hint: 'Status',
                    value: _selectedStatus,
                    items: const ['Active/Approved', 'Blocked/On hold'],
                    isJoshiTheme: isJoshiTheme,
                    scheme: scheme,
                    onChanged: (value) {
                      setState(() {
                        _selectedStatus = value;
                        _loadCustomers();
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: _buildDropdown(
                    hint: 'Province',
                    value: _selectedProvince,
                    items: _provinces,
                    isJoshiTheme: isJoshiTheme,
                    scheme: scheme,
                    onChanged: (value) {
                      setState(() {
                        _selectedProvince = value;
                        _updateCities();
                        _loadCustomers();
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildDropdown(
                    hint: 'City',
                    value: _selectedCity,
                    items: _cities,
                    isJoshiTheme: isJoshiTheme,
                    scheme: scheme,
                    enabled: _selectedProvince != null,
                    onChanged: (value) {
                      setState(() {
                        _selectedCity = value;
                        _updateBarangays();
                        _loadCustomers();
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildDropdown(
                    hint: 'Barangay',
                    value: _selectedBarangay,
                    items: _barangays,
                    isJoshiTheme: isJoshiTheme,
                    scheme: scheme,
                    enabled: _selectedCity != null,
                    onChanged: (value) {
                      setState(() {
                        _selectedBarangay = value;
                        _loadCustomers();
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Customer>>(
              future: _customersFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                } else if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                } else {
                  final allCustomers = snapshot.data!;
                    final searchedCustomers = _searchQuery.isEmpty
                      ? allCustomers
                      : allCustomers.where((c) =>
                          c.customerCode.toLowerCase().contains(_searchQuery) ||
                          c.customerName.toLowerCase().contains(_searchQuery) ||
                        c.fullName.toLowerCase().contains(_searchQuery)).toList();

                    final customers = _onlyWithLocation
                      ? searchedCustomers.where(_hasValidLocation).toList()
                      : searchedCustomers;

                  if (customers.isEmpty) {
                    return const Center(child: Text('No customers found.'));
                  }

                  return ListView.builder(
                    itemCount: customers.length,
                    itemBuilder: (context, index) {
                      final customer = customers[index];
                      final provinceText = customer.province.trim().isEmpty ? 'N/A' : customer.province.trim();
                      final cityText = customer.city.trim().isEmpty ? 'N/A' : customer.city.trim();
                      final barangayText = customer.barangay.trim().isEmpty ? 'N/A' : customer.barangay.trim();
                      final isActive = customer.status == 'Active/Approved';
                      final statusColor = isActive ? Colors.green : Colors.red;
                      final hasLocation = _hasValidLocation(customer);
                      final mapColor = hasLocation ? Colors.green : Colors.red;

                      final tile = ListTile(
                        title: Text(customer.customerName),
                        subtitle: Text(
                          '${customer.customerCode} • ${customer.fullName}\n'
                          'Province: $provinceText\n'
                          'City: $cityText\n'
                          'Barangay: $barangayText',
                        ),
                        isThreeLine: true,
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Icon(Icons.map, size: 18, color: mapColor),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.circle, size: 10, color: statusColor),
                                const SizedBox(width: 6),
                                Text(
                                  customer.status,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: statusColor,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        onTap: () async {
                          final didUpdate = await showModalBottomSheet<bool>(
                            context: context,
                            isScrollControlled: true,
                            builder: (context) => CustomerInfoModal(customer: customer),
                          );
                          if (didUpdate == true && mounted) {
                            setState(_loadCustomers);
                          }
                        },
                      );

                      if (!isJoshiTheme) {
                        return Card(
                          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: tile,
                        );
                      }

                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        clipBehavior: Clip.antiAlias,
                        color: Colors.transparent,
                        child: Ink(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color.alphaBlend(
                                  scheme.primary.withValues(alpha: 0.26),
                                  scheme.surface,
                                ),
                                Color.alphaBlend(
                                  scheme.tertiary.withValues(alpha: 0.22),
                                  scheme.surface,
                                ),
                              ],
                            ),
                            border: Border.all(color: scheme.outline.withValues(alpha: 0.35)),
                          ),
                          child: ListTileTheme(
                            textColor: Colors.white.withValues(alpha: 0.96),
                            iconColor: Colors.white.withValues(alpha: 0.96),
                            child: tile,
                          ),
                        ),
                      );
                    },
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