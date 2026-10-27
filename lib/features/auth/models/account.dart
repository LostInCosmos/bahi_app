library;

import '../../../core/config/business_types.dart';
import '../../../core/config/legal_documents.dart';
import '../../../core/utils/json.dart';

class AccountInfo {
  final String tenantName;
  final String? gstin;
  final String? address;
  final String email;
  final String businessType;

  /// Printed on the shop's bills (DAS-121); null when not set, and from a
  /// server older than the fields. [phone] comes back as its 10 digits.
  final String? dlNo;
  final String? phone;

  /// Whether the admin has voice switched on for this shop (DAS-112); null
  /// from a server older than the switch, which leaves voice as it is.
  final bool? voiceEnabled;

  /// Where the shop stands on the legal documents (DAS-104); null from a
  /// server older than the field, which then never asks for acceptance.
  final LegalStatus? legal;

  /// The shop's public stock page (DAS-80), e.g. `https://dastavez.co.in/<slug>`;
  /// null until our team publishes one, and from a server older than the field.
  final String? publicStockUrl;

  AccountInfo({
    required this.tenantName,
    this.gstin,
    this.address,
    required this.email,
    required this.businessType,
    this.dlNo,
    this.phone,
    this.voiceEnabled,
    this.legal,
    this.publicStockUrl,
  });

  factory AccountInfo.fromJson(Map<String, dynamic> json) => AccountInfo(
        tenantName: json.strReq('tenant_name'),
        gstin: json.str('gstin'),
        address: json.str('address'),
        email: json.strReq('email'),
        businessType: json.strOr('business_type', kDefaultBusinessType),
        dlNo: json.str('dl_no'),
        phone: json.str('phone'),
        voiceEnabled: json.boolean('voice_enabled'),
        legal: json.objOf('legal', LegalStatus.fromJson),
        publicStockUrl: json.str('public_stock_url'),
      );

  /// Whether this build must show the acceptance screen before going on:
  /// the server says acceptance is required AND this build carries the
  /// server's current text or newer — a build whose documents are older
  /// could not show what it would be recording, so it asks nothing (the
  /// version gate is the tool for that). Soft on purpose: the server never
  /// refuses a request over it, so old builds keep working.
  bool get needsLegalAcceptance {
    final l = legal;
    return l != null && l.requiresAcceptance && compareLegalVersions(l.currentVersion, kLegalVersion) <= 0;
  }
}

/// The `legal` object on the account (DAS-104): the server's current
/// version, what the shop last accepted, and the server's own verdict.
class LegalStatus {
  final String currentVersion;
  final String? acceptedVersion;
  final DateTime? acceptedAt;
  final bool requiresAcceptance;

  const LegalStatus({
    required this.currentVersion,
    this.acceptedVersion,
    this.acceptedAt,
    required this.requiresAcceptance,
  });

  factory LegalStatus.fromJson(Map<String, dynamic> json) => LegalStatus(
        currentVersion: json.strOr('current_version', kLegalVersion),
        acceptedVersion: json.str('accepted_version'),
        acceptedAt: json.utc('accepted_at'),
        requiresAcceptance: json.boolOr('requires_acceptance'),
      );
}
