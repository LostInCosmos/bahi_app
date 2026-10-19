import '../../../core/api/api_client.dart';
import '../../../core/config/business_types.dart';
import '../models/account.dart';

extension AuthApi on ApiClient {
  Future<void> signup({
    required String tenantName,
    required String email,
    required String password,
    String? businessType,
  }) async {
    final res = await postJson(
        '/auth/signup',
        {
          'tenant_name': tenantName,
          'email': email,
          'password': password,
          'business_type': businessType,
        },
        auth: false);
    await saveToken(ApiClient.jsonObject(res)['access_token'] as String);
    await saveBusinessType(businessType ?? kDefaultBusinessType);
  }

  Future<void> login({required String email, required String password}) async {
    // No token sent, so a 401 here is a wrong password, not a session ending.
    final res = await postJson('/auth/login', {'email': email, 'password': password}, auth: false);
    await saveToken(ApiClient.jsonObject(res)['access_token'] as String);
    await getAccount(); // picks up business_type for theming
  }

  Future<AccountInfo> getAccount() async {
    final account = AccountInfo.fromJson(ApiClient.jsonObject(await get('/account')));
    await saveBusinessType(account.businessType);
    return account;
  }

  Future<AccountInfo> updateAccount({
    String? tenantName,
    String? gstin,
    String? address,
    String? businessType,
  }) async {
    final res = await patchJson('/account', {
      if (tenantName != null) 'tenant_name': tenantName,
      if (gstin != null) 'gstin': gstin,
      if (address != null) 'address': address,
      if (businessType != null) 'business_type': businessType,
    });
    final account = AccountInfo.fromJson(ApiClient.jsonObject(res));
    await saveBusinessType(account.businessType);
    return account;
  }
}
