import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../models/product_search.dart';
import 'inventory_api.dart';

/// The shop's whole product list, held once for every product search on the
/// phone — Inventory, the sale screen and a voice sale's "Add item" (DAS-94).
///
/// Search used to be a server call on submit. The list is now fetched whole
/// (the request the Inventory tab already made on every visit: ~1,000
/// products, ~23 KiB over the wire) and searched on the phone as each letter
/// is typed. The server's search is only "name contains", so nothing is lost.
///
/// Fetched again whenever a screen asks — tab opened, a sale made, a pull —
/// which is what keeps stock right after a sale or a saved bill. A screen
/// shows the list it has while the next one loads.
///
/// Held per sign-in (keyed on the session's token): a list fetched for one
/// shop is never shown to the next one signed in, nor after a sign-out.
/// Revisit if a shop passes ~5,000 products (Backend would add an ETag
/// first) — see the vault's Flutter App note.
class ProductCatalog extends ChangeNotifier {
  ProductCatalog._();
  static final instance = ProductCatalog._();

  ProductIndex? _index;
  String? _session;
  Future<void>? _fetching;
  String? _fetchingFor;

  /// Why the last fetch failed, until one succeeds.
  Object? lastError;

  /// The signed-in shop's products, or null before they first arrive.
  ProductIndex? get index => _session != null && _session == ApiClient.instance.token ? _index : null;

  bool get isLoading => _fetching != null;

  /// Fetch the list again. Callers at the same moment share one request, and
  /// a failure is kept in [lastError] rather than thrown: whatever list is
  /// already held stays on screen.
  Future<void> refresh() {
    final running = _fetching;
    // A fetch begun for an earlier sign-in would be thrown away on arrival.
    if (running != null && _fetchingFor == ApiClient.instance.token) return running;
    _fetchingFor = ApiClient.instance.token;
    final fetch = _fetch();
    _fetching = fetch;
    notifyListeners();
    return fetch;
  }

  Future<void> _fetch() async {
    final session = ApiClient.instance.token;
    try {
      final products = await ApiClient.instance.searchProducts();
      // Signed out, or another shop signed in, while it was on its way.
      if (session == null || session != ApiClient.instance.token) return;
      _index = ProductIndex(products);
      _session = session;
      lastError = null;
    } catch (e) {
      lastError = e;
    } finally {
      if (_fetchingFor == session) _fetching = null;
      notifyListeners();
    }
  }
}
