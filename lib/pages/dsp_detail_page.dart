import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/database_service.dart';
import '../services/app_customization_notifier.dart';
import '../models/dsp.dart';
import '../models/customer.dart';
import '../widgets/customer_info_modal.dart';
import '../widgets/branded_app_bar.dart';

class DSPDetailPage extends StatefulWidget {
  final DSP dsp;

  const DSPDetailPage({super.key, required this.dsp});

  @override
  State<DSPDetailPage> createState() => _DSPDetailPageState();
}

class _DSPDetailPageState extends State<DSPDetailPage> {
  late Future<List<Customer>> _customersFuture;
  late TextEditingController _searchController;
  String? _selectedStatus;
  String? _selectedCoverageDay;
  String? _selectedWklyCoverage;
  bool _onlyWithLocation = false;
  String _searchQuery = '';

  final Map<String, String> _coverageDayMap = {
    'Monday': 'MON',
    'Tuesday': 'TUE',
    'Wednesday': 'WED',
    'Thursday': 'THU',
    'Friday': 'FRI',
    'Saturday': 'SAT',
  };

  final Map<String, String> _wklyCoverageMap = {
    'Weekly': 'WKLY',
    'Week 1 and 3': 'W1&W3',
    'Week 2 and 4': 'W2&W4',
  };

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _loadCustomers();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _loadCustomers() {
    _customersFuture = DatabaseService().getCustomersByDSP(
      widget.dsp.salesRepId,
      status: _selectedStatus,
      coverageDay: _selectedCoverageDay,
      wklyCoverage: _selectedWklyCoverage,
    );
  }

  void _resetFilters() {
    setState(() {
      _selectedStatus = null;
      _selectedCoverageDay = null;
      _selectedWklyCoverage = null;
      _onlyWithLocation = false;
      _searchController.clear();
      _searchQuery = '';
      _loadCustomers();
    });
  }

  bool _matchesSearchQuery(Customer customer) {
    if (_searchQuery.isEmpty) return true;
    final query = _searchQuery.toLowerCase();
    return customer.customerCode.toLowerCase().contains(query) ||
        customer.customerName.toLowerCase().contains(query) ||
        customer.firstName.toLowerCase().contains(query) ||
        customer.lastName.toLowerCase().contains(query);
  }

  bool _hasValidLocation(Customer customer) {
    final lat = customer.latitude;
    final lng = customer.longitude;
    if (lat == null || lng == null) return false;
    return lat != 0 && lng != 0;
  }

  @override
  Widget build(BuildContext context) {
    final customization = context.watch<AppCustomizationNotifier>();
    final isJoshiTheme = customization.isJoshiAOTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: buildBrandedAppBar(
        context: context,
        title: Text(widget.dsp.salesRepName),
        actions: [
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
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search by Code, Name, First Name, or Last Name',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          setState(() {
                            _searchController.clear();
                            _searchQuery = '';
                          });
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    hint: Text('Status'),
                    value: _selectedStatus,
                    items: const [
                      DropdownMenuItem<String>(value: null, child: Text('Status')),
                      DropdownMenuItem<String>(value: 'Active/Approved', child: Text('Active/Approved')),
                      DropdownMenuItem<String>(value: 'Blocked/On hold', child: Text('Blocked/On hold')),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _selectedStatus = value;
                        _loadCustomers();
                      });
                    },
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<String>(
                    hint: Text('Coverage Day'),
                    value: _selectedCoverageDay,
                    items: [
                      const DropdownMenuItem<String>(value: null, child: Text('Coverage Day')),
                      ..._coverageDayMap.entries
                          .map((e) => DropdownMenuItem<String>(value: e.value, child: Text(e.key))),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _selectedCoverageDay = value;
                        _loadCustomers();
                      });
                    },
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<String>(
                    hint: Text('Wkly Coverage'),
                    value: _selectedWklyCoverage,
                    items: [
                      const DropdownMenuItem<String>(value: null, child: Text('Wkly Coverage')),
                      ..._wklyCoverageMap.entries
                          .map((e) => DropdownMenuItem<String>(value: e.value, child: Text(e.key))),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _selectedWklyCoverage = value;
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
                  return Center(child: CircularProgressIndicator());
                } else if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                } else {
                  final customers = snapshot.data!;
                  final filteredCustomers = customers
                      .where((customer) => _matchesSearchQuery(customer))
                      .where((customer) => !_onlyWithLocation || _hasValidLocation(customer))
                      .toList();

                  if (filteredCustomers.isEmpty) {
                    return const Center(child: Text('No customers found.'));
                  }

                  return ListView.builder(
                    itemCount: filteredCustomers.length,
                    itemBuilder: (context, index) {
                      final customer = filteredCustomers[index];
                      final isActive = customer.status == 'Active/Approved';
                      final statusColor = isActive ? Colors.green : Colors.red;
                      final hasLocation = _hasValidLocation(customer);
                      final mapColor = hasLocation ? Colors.green : Colors.red;

                      final tile = ListTile(
                        title: Text(customer.customerCode),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(customer.customerName),
                            Text(customer.phone),
                            Text('${customer.firstName} ${customer.lastName}'.trim()),
                            Text(customer.address),
                            Text(customer.partyClassificationDescription),
                            Text(customer.coverageDay),
                            Text(customer.wklyCoverage),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Column(
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
                          margin: const EdgeInsets.all(8.0),
                          child: tile,
                        );
                      }

                      return Card(
                        margin: const EdgeInsets.all(8.0),
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