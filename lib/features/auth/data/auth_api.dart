part of '../../../core/api/api_client.dart';

extension AuthApi on ApiClient {
  Future<void> signup({
    required String tenantName,
    required String email,
    required String password,
    String? businessType,
  }) async {
    final res = await http.post(
      _uri('/auth/signup'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'tenant_name': tenantName,
        'email': email,
        'password': password,
        'business_type': businessType,
      }),
    );
    _checkOk(res);
    await _saveToken(jsonDecode(res.body)['access_token'] as String);
    await _saveBusinessType(businessType ?? 'medical');
  }

  Future<void> login({required String email, required String password}) async {
    final res = await http.post(
      _uri('/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    _checkOk(res);
    await _saveToken(jsonDecode(res.body)['access_token'] as String);
    await getAccount(); // picks up business_type for theming
  }

  Future<AccountInfo> getAccount() async {
    final res = await http.get(_uri('/account'), headers: _authHeader);
    _checkOk(res);
    final account = AccountInfo.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    await _saveBusinessType(account.businessType);
    return account;
  }

  Future<AccountInfo> updateAccount({
    String? tenantName,
    String? gstin,
    String? address,
    String? businessType,
  }) async {
    final body = <String, dynamic>{};
    if (tenantName != null) body['tenant_name'] = tenantName;
    if (gstin != null) body['gstin'] = gstin;
    if (address != null) body['address'] = address;
    if (businessType != null) body['business_type'] = businessType;
    final res = await http.patch(
      _uri('/account'),
      headers: {..._authHeader, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    _checkOk(res);
    final account = AccountInfo.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    await _saveBusinessType(account.businessType);
    return account;
  }
}
