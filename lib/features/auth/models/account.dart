library;

import '../../../core/config/business_types.dart';
import '../../../core/utils/json.dart';

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
        tenantName: json.strReq('tenant_name'),
        gstin: json.str('gstin'),
        address: json.str('address'),
        email: json.strReq('email'),
        businessType: json.strOr('business_type', kDefaultBusinessType),
      );
}
