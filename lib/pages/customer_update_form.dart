import 'package:flutter/material.dart';
import '../models/customer.dart';
import '../models/dsp.dart';
import '../services/database_service.dart';
import '../widgets/branded_app_bar.dart';
import 'tin_document_capture_page.dart';

class CustomerUpdateForm extends StatefulWidget {
  final Customer customer;

  const CustomerUpdateForm({super.key, required this.customer});

  @override
  State<CustomerUpdateForm> createState() => _CustomerUpdateFormState();
}

class _CustomerUpdateFormState extends State<CustomerUpdateForm> {
  late TextEditingController _nameController;
  late TextEditingController _phoneController;
  late TextEditingController _firstNameController;
  late TextEditingController _lastNameController;
  late TextEditingController _tinNoController;
  late TextEditingController _addressController;

  String? _selectedCoverageDay;
  String? _selectedWklyCoverage;
  String? _selectedPartyClassification;
  String? _selectedProvince;
  String? _selectedCity;
  String? _selectedBarangay;
  String? _selectedSalesRepId;
  String? _selectedSalesRepName;

  List<Map<String, dynamic>> _areas = [];
  List<String> _provinces = [];
  List<String> _cities = [];
  List<String> _barangays = [];
  List<String> _partyClassifications = [];
  List<DSP> _dspOptions = [];

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

  late Customer _originalCustomer;

  String? _valueIfPresent(List<String> options, String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return options.contains(value) ? value : null;
  }

  @override
  void initState() {
    super.initState();
    _originalCustomer = widget.customer;
    _nameController = TextEditingController(text: widget.customer.customerName);
    _selectedCoverageDay = _coverageDayMap[widget.customer.coverageDay] ?? widget.customer.coverageDay;
    _selectedWklyCoverage = _wklyCoverageMap[widget.customer.wklyCoverage] ?? widget.customer.wklyCoverage;
    _selectedPartyClassification = widget.customer.partyClassificationDescription;
    _phoneController = TextEditingController(text: widget.customer.phone);
    _firstNameController = TextEditingController(text: widget.customer.firstName);
    _lastNameController = TextEditingController(text: widget.customer.lastName);
    _tinNoController = TextEditingController(text: widget.customer.tinNo);
    _selectedProvince = widget.customer.province;
    _selectedCity = widget.customer.city;
    _selectedBarangay = widget.customer.barangay;
    _selectedSalesRepId = widget.customer.salesRepId;
    _selectedSalesRepName = widget.customer.salesRepName;
    _addressController = TextEditingController(text: widget.customer.address);
    _loadAreas();
    _loadPartyClassifications();
    _loadDsps();
  }

  Future<void> _loadDsps() async {
    final dsps = await DatabaseService().fetchDSPs();
    if (!mounted) return;
    setState(() {
      _dspOptions = dsps;
    });
  }

  Future<void> _openDspSelectionModal() async {
    if (_dspOptions.isEmpty) {
      await _loadDsps();
    }
    if (!mounted) return;

    final teams = _dspOptions
        .map((dsp) => dsp.team.trim())
        .where((team) => team.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    String selectedTeam = 'All Teams';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.88,
            child: StatefulBuilder(
              builder: (context, setModalState) {
                final visibleDsps = _dspOptions.where((dsp) {
                  if (selectedTeam == 'All Teams') return true;
                  return dsp.team.trim() == selectedTeam;
                }).toList();

                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Select DSP',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(sheetContext).pop(),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: selectedTeam,
                        decoration: const InputDecoration(labelText: 'Team Filter'),
                        items: [
                          const DropdownMenuItem<String>(
                            value: 'All Teams',
                            child: Text('All Teams'),
                          ),
                          ...teams.map(
                            (team) => DropdownMenuItem<String>(
                              value: team,
                              child: Text(team),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setModalState(() {
                            selectedTeam = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: visibleDsps.isEmpty
                            ? const Center(child: Text('No DSP found for selected team.'))
                            : ListView.builder(
                                itemCount: visibleDsps.length,
                                itemBuilder: (context, index) {
                                  final dsp = visibleDsps[index];
                                  final dspCode = dsp.dspCode.isNotEmpty ? dsp.dspCode : dsp.salesRepId;
                                  return Card(
                                    child: ListTile(
                                      title: Text(
                                        dsp.salesRepName.trim().isEmpty ? 'Unnamed DSP' : dsp.salesRepName,
                                      ),
                                      subtitle: Text('Code: $dspCode'),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: () {
                                        final chosenCode = dsp.salesRepId.trim().isNotEmpty
                                            ? dsp.salesRepId.trim()
                                            : dsp.dspCode.trim();
                                        setState(() {
                                          _selectedSalesRepId = chosenCode;
                                          _selectedSalesRepName = dsp.salesRepName;
                                        });
                                        Navigator.of(sheetContext).pop();
                                      },
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _captureTinFromCamera() async {
    final result = await Navigator.push<TinCaptureResult>(
      context,
      MaterialPageRoute(
        builder: (_) => TinDocumentCapturePage(customer: widget.customer),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _tinNoController.text = result.detectedTin;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('TIN detected and image saved: ${result.savedFileName}')),
    );
  }

  Future<void> _loadPartyClassifications() async {
    final values = await DatabaseService().loadPartyClassifications();
    if (!mounted) return;

    if (_selectedPartyClassification != null &&
        _selectedPartyClassification!.trim().isNotEmpty &&
        !values.contains(_selectedPartyClassification)) {
      values.insert(0, _selectedPartyClassification!.trim());
    }

    setState(() {
      _partyClassifications = values;
    });
  }

  Future<void> _loadAreas() async {
    _areas = await DatabaseService().loadAreas();
    _provinces = _areas.map((a) => a['province'] as String).toSet().toList()..sort();
    setState(() {});
    _updateCities();
  }

  void _updateCities() {
    if (_selectedProvince != null) {
      _cities = _areas.where((a) => a['province'] == _selectedProvince).map((a) => a['city'] as String).toSet().toList()..sort();
    } else {
      _cities = [];
    }
    if (!_cities.contains(_selectedCity)) {
      _selectedCity = null;
    }
    _updateBarangays();
  }

  void _updateBarangays() {
    if (_selectedCity != null) {
      _barangays = _areas.where((a) => a['city'] == _selectedCity).map((a) => a['barangay'] as String).toSet().toList()..sort();
    } else {
      _barangays = [];
    }
    if (!_barangays.contains(_selectedBarangay)) {
      _selectedBarangay = null;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _tinNoController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  void _reset() {
    _nameController.text = widget.customer.customerName;
    _selectedCoverageDay = _coverageDayMap[widget.customer.coverageDay] ?? widget.customer.coverageDay;
    _selectedWklyCoverage = _wklyCoverageMap[widget.customer.wklyCoverage] ?? widget.customer.wklyCoverage;
    _selectedPartyClassification = widget.customer.partyClassificationDescription;
    _phoneController.text = widget.customer.phone;
    _firstNameController.text = widget.customer.firstName;
    _lastNameController.text = widget.customer.lastName;
    _tinNoController.text = widget.customer.tinNo;
    _selectedProvince = widget.customer.province;
    _selectedCity = widget.customer.city;
    _selectedBarangay = widget.customer.barangay;
    _selectedSalesRepId = widget.customer.salesRepId;
    _selectedSalesRepName = widget.customer.salesRepName;
    _addressController.text = widget.customer.address;
    _updateCities();
  }

  void _submit() async {
    List<String> editedFields = [];
    if (_nameController.text != _originalCustomer.customerName) editedFields.add('customer_name');
    if (_selectedCoverageDay != (_coverageDayMap[_originalCustomer.coverageDay] ?? _originalCustomer.coverageDay)) editedFields.add('coverage_day');
    if (_selectedWklyCoverage != (_wklyCoverageMap[_originalCustomer.wklyCoverage] ?? _originalCustomer.wklyCoverage)) editedFields.add('wkly_coverage');
    if ((_selectedPartyClassification ?? '') != _originalCustomer.partyClassificationDescription) editedFields.add('party_classification_description');
    if (_phoneController.text != _originalCustomer.phone) editedFields.add('phone');
    if (_firstNameController.text != _originalCustomer.firstName) editedFields.add('first_name');
    if (_lastNameController.text != _originalCustomer.lastName) editedFields.add('last_name');
    if (_tinNoController.text != _originalCustomer.tinNo) editedFields.add('tin_no');
    if (_selectedProvince != _originalCustomer.province) editedFields.add('province');
    if (_selectedCity != _originalCustomer.city) editedFields.add('city');
    if (_selectedBarangay != _originalCustomer.barangay) editedFields.add('barangay');
    if ((_selectedSalesRepId ?? '') != _originalCustomer.salesRepId) editedFields.add('sales_rep_id');
    if ((_selectedSalesRepName ?? '') != _originalCustomer.salesRepName) editedFields.add('sales_rep_name');
    if (_addressController.text != _originalCustomer.address) editedFields.add('address');

    Customer updatedCustomer = Customer(
      branchName: _originalCustomer.branchName,
      cdam: _originalCustomer.cdam,
      fs: _originalCustomer.fs,
      channel: _originalCustomer.channel,
      salesRepId: _selectedSalesRepId ?? _originalCustomer.salesRepId,
      salesRepName: _selectedSalesRepName ?? _originalCustomer.salesRepName,
      customerCode: _originalCustomer.customerCode,
      customerName: _nameController.text,
      barangay: _selectedBarangay ?? '',
      city: _selectedCity ?? '',
      province: _selectedProvince ?? '',
      status: _originalCustomer.status,
      partyClassificationDescription: _selectedPartyClassification ?? '',
      coverageDay: _selectedCoverageDay ?? '',
      wklyCoverage: _selectedWklyCoverage ?? '',
      latitude: _originalCustomer.latitude,
      longitude: _originalCustomer.longitude,
      phone: _phoneController.text,
      firstName: _firstNameController.text,
      lastName: _lastNameController.text,
      address: _addressController.text,
      tinNo: _tinNoController.text,
      editedFields: editedFields.isEmpty ? null : editedFields.join(', '),
    );
    await DatabaseService().updateCustomer(updatedCustomer);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: buildBrandedAppBar(
        context: context,
        title: const Text('Update Customer Info'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Assigned DSP',
                border: OutlineInputBorder(),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (_selectedSalesRepName ?? '').trim().isEmpty
                              ? 'Not assigned'
                              : _selectedSalesRepName!,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Code: ${(_selectedSalesRepId ?? '').trim().isEmpty ? '-' : _selectedSalesRepId}',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _openDspSelectionModal,
                    child: const Text('Change'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _valueIfPresent(_coverageDayMap.values.toList(), _selectedCoverageDay),
              decoration: InputDecoration(labelText: 'Coverage Day'),
              items: _coverageDayMap.entries.map((e) => DropdownMenuItem(value: e.value, child: Text(e.key))).toList(),
              onChanged: (value) => setState(() => _selectedCoverageDay = value),
            ),
            DropdownButtonFormField<String>(
              initialValue: _valueIfPresent(_wklyCoverageMap.values.toList(), _selectedWklyCoverage),
              decoration: InputDecoration(labelText: 'Wkly Coverage'),
              items: _wklyCoverageMap.entries.map((e) => DropdownMenuItem(value: e.value, child: Text(e.key))).toList(),
              onChanged: (value) => setState(() => _selectedWklyCoverage = value),
            ),
            DropdownButtonFormField<String>(
              initialValue: _valueIfPresent(_partyClassifications, _selectedPartyClassification),
              decoration: InputDecoration(labelText: 'Party Classification'),
              items: _partyClassifications
                  .map((value) => DropdownMenuItem(value: value, child: Text(value)))
                  .toList(),
              onChanged: (value) => setState(() => _selectedPartyClassification = value),
            ),
            TextField(controller: _phoneController, decoration: InputDecoration(labelText: 'Phone')),
            TextField(controller: _firstNameController, decoration: InputDecoration(labelText: 'First Name')),
            TextField(controller: _lastNameController, decoration: InputDecoration(labelText: 'Last Name')),
            TextField(
              controller: _tinNoController,
              readOnly: true,
              enableInteractiveSelection: false,
              onTap: _captureTinFromCamera,
              decoration: InputDecoration(
                labelText: 'TIN No',
                helperText: 'Captured from document only',
                suffixIcon: IconButton(
                  onPressed: _captureTinFromCamera,
                  icon: const Icon(Icons.camera_alt_outlined),
                  tooltip: 'Capture TIN',
                ),
              ),
            ),
            DropdownButtonFormField<String>(
              initialValue: _valueIfPresent(_provinces, _selectedProvince),
              decoration: InputDecoration(labelText: 'Province'),
              items: _provinces.map((prov) => DropdownMenuItem(value: prov, child: Text(prov))).toList(),
              onChanged: (value) => setState(() {
                _selectedProvince = value;
                _updateCities();
              }),
            ),
            DropdownButtonFormField<String>(
              initialValue: _valueIfPresent(_cities, _selectedCity),
              decoration: InputDecoration(labelText: 'City'),
              items: _cities.map((city) => DropdownMenuItem(value: city, child: Text(city))).toList(),
              onChanged: (value) => setState(() {
                _selectedCity = value;
                _updateBarangays();
              }),
            ),
            DropdownButtonFormField<String>(
              initialValue: _valueIfPresent(_barangays, _selectedBarangay),
              decoration: InputDecoration(labelText: 'Barangay'),
              items: _barangays.map((brgy) => DropdownMenuItem(value: brgy, child: Text(brgy))).toList(),
              onChanged: (value) => setState(() => _selectedBarangay = value),
            ),
            TextField(controller: _addressController, decoration: InputDecoration(labelText: 'Address')),
            SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(onPressed: _reset, child: Text('Reset')),
                ElevatedButton(onPressed: _submit, child: Text('Submit')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}