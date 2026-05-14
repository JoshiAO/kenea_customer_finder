class Customer {
  final String branchName;
  final String cdam;
  final String fs;
  final String channel;
  final String salesRepId;
  final String salesRepName;
  final String customerCode;
  final String customerName;
  final String barangay;
  final String city;
  final String province;
  final String status;
  final String partyClassificationDescription;
  final String coverageDay;
  final String wklyCoverage;
  final double? latitude;
  final double? longitude;
  final String phone;
  final String firstName;
  final String lastName;
  final String address;
  final String tinNo;
  final String? editedFields;

  Customer({
    required this.branchName,
    required this.cdam,
    required this.fs,
    required this.channel,
    required this.salesRepId,
    required this.salesRepName,
    required this.customerCode,
    required this.customerName,
    required this.barangay,
    required this.city,
    required this.province,
    required this.status,
    required this.partyClassificationDescription,
    required this.coverageDay,
    required this.wklyCoverage,
    this.latitude,
    this.longitude,
    required this.phone,
    required this.firstName,
    required this.lastName,
    required this.address,
    required this.tinNo,
    this.editedFields,
  });

  String get fullName {
    final full = '$firstName $lastName'.trim();
    return full;
  }

  static String _readString(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString();
      }
    }
    return '';
  }

  factory Customer.fromJson(Map<String, dynamic> json) {
    final rawFirstName = _readString(json, ['first_name', 'First Name', 'FIRST_NAME']).trim();
    final rawLastName = _readString(json, ['last_name', 'Last Name', 'LAST_NAME']).trim();
    final legacyOwner = _readString(json, ['owner', 'Owner', 'OWNER']).trim();

    String resolvedFirstName = rawFirstName;
    String resolvedLastName = rawLastName;

    if (resolvedFirstName.isEmpty && resolvedLastName.isEmpty && legacyOwner.isNotEmpty) {
      final parts = legacyOwner.split(RegExp(r'\s+'));
      resolvedFirstName = parts.first;
      resolvedLastName = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    }

    return Customer(
      branchName: _readString(json, ['branch_name', 'branch name', 'Branch Name']),
      cdam: _readString(json, ['cdam', 'CDAM']),
      fs: _readString(json, ['fs', 'FS']),
      channel: _readString(json, ['channel', 'Channel']),
      salesRepId: _readString(json, ['sales_rep_id', 'sales rep id', 'Sales Rep ID']),
      salesRepName: _readString(json, ['sales_rep_name', 'sales rep name', 'Sales Rep Name']),
      customerCode: _readString(json, ['customer_code', 'customer code', 'Customer Code']),
      customerName: _readString(json, ['customer_name', 'customer name', 'Customer Name']),
      barangay: _readString(json, ['barangay', 'Barangay', 'BRGY', 'brgy']),
      city: _readString(json, ['city', 'City', 'CITY', 'municipality', 'Municipality']),
      province: _readString(json, ['province', 'Province', 'PROVINCE', 'prov', 'Prov']),
      status: _readString(json, ['status', 'Status']),
      partyClassificationDescription: _readString(
        json,
        ['party_classification_description', 'party classification description', 'Party Classification Description'],
      ),
      coverageDay: _readString(json, ['coverage_day', 'coverage day', 'Coverage Day']),
      wklyCoverage: _readString(json, ['wkly_coverage', 'wkly coverage', 'Wkly Coverage']),
      latitude: json['latitude'] != null ? double.tryParse(json['latitude'].toString()) : null,
      longitude: json['longitude'] != null ? double.tryParse(json['longitude'].toString()) : null,
      phone: _readString(json, ['phone', 'Phone']),
      firstName: resolvedFirstName,
      lastName: resolvedLastName,
      address: _readString(json, ['address', 'Address']),
      tinNo: _readString(json, ['tin_no', 'tin no', 'TIN No']),
      editedFields: _readString(json, ['edited_fields', 'edited fields']).isEmpty
          ? null
          : _readString(json, ['edited_fields', 'edited fields']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'branch_name': branchName,
      'cdam': cdam,
      'fs': fs,
      'channel': channel,
      'sales_rep_id': salesRepId,
      'sales_rep_name': salesRepName,
      'customer_code': customerCode,
      'customer_name': customerName,
      'barangay': barangay,
      'city': city,
      'province': province,
      'status': status,
      'party_classification_description': partyClassificationDescription,
      'coverage_day': coverageDay,
      'wkly_coverage': wklyCoverage,
      'latitude': latitude,
      'longitude': longitude,
      'phone': phone,
      'first_name': firstName,
      'last_name': lastName,
      'address': address,
      'tin_no': tinNo,
      'edited_fields': editedFields,
    };
  }

  Customer copyWith({
    String? branchName,
    String? cdam,
    String? fs,
    String? channel,
    String? salesRepId,
    String? salesRepName,
    String? customerCode,
    String? customerName,
    String? barangay,
    String? city,
    String? province,
    String? status,
    String? partyClassificationDescription,
    String? coverageDay,
    String? wklyCoverage,
    double? latitude,
    double? longitude,
    String? phone,
    String? firstName,
    String? lastName,
    String? address,
    String? tinNo,
    String? editedFields,
  }) {
    return Customer(
      branchName: branchName ?? this.branchName,
      cdam: cdam ?? this.cdam,
      fs: fs ?? this.fs,
      channel: channel ?? this.channel,
      salesRepId: salesRepId ?? this.salesRepId,
      salesRepName: salesRepName ?? this.salesRepName,
      customerCode: customerCode ?? this.customerCode,
      customerName: customerName ?? this.customerName,
      barangay: barangay ?? this.barangay,
      city: city ?? this.city,
      province: province ?? this.province,
      status: status ?? this.status,
      partyClassificationDescription: partyClassificationDescription ?? this.partyClassificationDescription,
      coverageDay: coverageDay ?? this.coverageDay,
      wklyCoverage: wklyCoverage ?? this.wklyCoverage,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      phone: phone ?? this.phone,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      address: address ?? this.address,
      tinNo: tinNo ?? this.tinNo,
      editedFields: editedFields ?? this.editedFields,
    );
  }
}