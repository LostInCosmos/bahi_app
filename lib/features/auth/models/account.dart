library;

class AccountInfo {
  final String tenantName;
  final String? gstin;
  final String? address;
  final String email;
  final String businessType;

  AccountInfo({
    required this.tenantName,
    this.gstin,
    this.address,
    required this.email,
    required this.businessType,
  });

  factory AccountInfo.fromJson(Map<String, dynamic> json) => AccountInfo(
        tenantName: json['tenant_name'] as String,
        gstin: json['gstin'] as String?,
        address: json['address'] as String?,
        email: json['email'] as String,
        businessType: json['business_type'] as String? ?? 'medical',
      );
}
