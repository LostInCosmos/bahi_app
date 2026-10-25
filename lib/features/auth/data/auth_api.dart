import '../../../core/api/api_client.dart';
import '../../../core/config/business_types.dart';
import '../../../core/config/legal_documents.dart';
import '../models/account.dart';

extension AuthApi on ApiClient {
  /// Creates the shop. The signup form's tick is the acceptance of
  /// [kLegalVersion], which the server records (DAS-104). Returns the
  /// account when the server sends it (DAS-105), else null.
  Future<AccountInfo?> signup({
    required String tenantName,
    required String email,
    required String password,
    String? businessType,
    String? dlNo,
    String? phone,
  }) async {
    final res = await postJson(
        '/auth/signup',
        {
          'tenant_name': tenantName,
          'email': email,
          'password': password,
          'business_type': businessType,
          // Optional (DAS-121): the server trims, checks and stores them; an
          // older server ignores them.
          if (dlNo != null && dlNo.trim().isNotEmpty) 'dl_no': dlNo.trim(),
          if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
          'legal_version': kLegalVersion,
        },
        auth: false);
    final body = ApiClient.jsonObject(res);
    await saveToken(body['access_token'] as String);
    final account = _accountIn(body);
    await saveBusinessType(account?.businessType ?? businessType ?? kDefaultBusinessType);
    await _applyVoiceSwitch(account);
    return account;
  }

  /// Signs in and returns the account — from the login answer when the
  /// server sends it (DAS-105), else fetched — so the caller can see
  /// whether the legal documents need accepting (DAS-104).
  Future<AccountInfo> login({required String email, required String password}) async {
    // No token sent, so a 401 here is a wrong password, not a session ending.
    final res = await postJson('/auth/login', {'email': email, 'password': password}, auth: false);
    final body = ApiClient.jsonObject(res);
    await saveToken(body['access_token'] as String);
    final account = _accountIn(body);
    if (account != null) {
      await saveBusinessType(account.businessType);
      await _applyVoiceSwitch(account);
      return account;
    }
    return getAccount();
  }

  /// Records that the shop accepted the documents this build carries
  /// (DAS-104). 204; a 422 `stale_version` means the server's current text
  /// is newer than this build's — not expected, since the screen is only
  /// shown when it is not.
  Future<void> acceptLegal({String version = kLegalVersion}) =>
      postJson('/account/accept-legal', {'version': version});

  /// Takes the shop's voice switch from an account answer. A server too old to
  /// send it cannot have voice off, so no field means on — whatever this
  /// device remembered from a newer server.
  Future<void> _applyVoiceSwitch(AccountInfo? account) => setVoiceEnabled(account?.voiceEnabled ?? true);

  /// The `account` object a login or signup answer may carry (DAS-105).
  static AccountInfo? _accountIn(Map<String, dynamic> body) {
    final account = body['account'];
    return account is Map<String, dynamic> ? AccountInfo.fromJson(account) : null;
  }

  /// Deletes the shop's account (R1 of the 2026-10-19 audit; Play and Apple
  /// both require an in-app path). `204` when done: every token of the
  /// tenant is revoked and the data is purged after 30 days. A wrong
  /// password is a `403` with `error: wrong_password`, so the shopkeeper is
  /// asked again — not a `401`, which `_send` reads as a refused token and
  /// would sign the device out on a typo. The caller signs out afterwards.
  Future<void> deleteAccount({required String password}) =>
      postJson('/account/delete', {'password': password});

  Future<AccountInfo> getAccount() async {
    final account = AccountInfo.fromJson(ApiClient.jsonObject(await get('/account')));
    await saveBusinessType(account.businessType);
    await _applyVoiceSwitch(account);
    return account;
  }

  Future<AccountInfo> updateAccount({
    String? tenantName,
    String? gstin,
    String? address,
    String? businessType,
    String? dlNo,
    String? phone,
  }) async {
    // Null leaves a field as it is; an empty string clears it (DAS-121).
    final res = await patchJson('/account', {
      if (tenantName != null) 'tenant_name': tenantName,
      if (gstin != null) 'gstin': gstin,
      if (address != null) 'address': address,
      if (businessType != null) 'business_type': businessType,
      if (dlNo != null) 'dl_no': dlNo.trim(),
      if (phone != null) 'phone': phone.trim(),
    });
    final account = AccountInfo.fromJson(ApiClient.jsonObject(res));
    await saveBusinessType(account.businessType);
    return account;
  }
}
