part of '../../../core/api/api_client.dart';

extension AuthApi on ApiClient {
  Future<void> signup({
    required String tenantName,
    required String email,
    required String password,
    String? businessType,
  }) async {
    final res = await _postJson(
        '/auth/signup',
        {
          'tenant_name': tenantName,
          'email': email,
          'password': password,
          'business_type': businessType,
        },
        auth: false);
    await _saveToken(ApiClient._object(res)['access_token'] as String);
    await _saveBusinessType(businessType ?? 'medical');
  }

  Future<void> login({required String email, required String password}) async {
    // No token sent, so a 401 here is a wrong password, not a session ending.
    final res = await _postJson('/auth/login', {'email': email, 'password': password}, auth: false);
    await _saveToken(ApiClient._object(res)['access_token'] as String);
    await getAccount(); // picks up business_type for theming
  }

  Future<AccountInfo> getAccount() async {
    final account = AccountInfo.fromJson(ApiClient._object(await _get('/account')));
    await _saveBusinessType(account.businessType);
    return account;
  }

  Future<AccountInfo> updateAccount({
    String? tenantName,
    String? gstin,
    String? address,
    String? businessType,
  }) async {
    final res = await _patchJson('/account', {
      if (tenantName != null) 'tenant_name': tenantName,
      if (gstin != null) 'gstin': gstin,
      if (address != null) 'address': address,
      if (businessType != null) 'business_type': businessType,
    });
    final account = AccountInfo.fromJson(ApiClient._object(res));
    await _saveBusinessType(account.businessType);
    return account;
  }
}
