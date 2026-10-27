import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../models/product.dart';
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

  /// What every screen says when a product or batch it was holding has been
  /// merged into another by our team (DAS-93): the list is fetched again and
  /// the shopkeeper picks again.
  static const mergedAwayMessage =
      'That medicine was merged into another one. The list has been refreshed — pick it again.';

  ProductIndex? _index;
  String? _session;

  /// The `ETag` of the held list, sent back as `If-None-Match` so an
  /// unchanged list costs a 304 and no parse (DAS-105). Per sign-in like
  /// the list itself.
  String? _etag;
  Future<void>? _fetching;
  String? _fetchingFor;

  /// Why the last fetch failed, until one succeeds.
  Object? lastError;

  /// Each product's batches, fetched once and kept while the list above is
  /// unchanged, so the sale screen's batch sheet opens at once (fast billing).
  /// A sale, a saved bill or a merge changes the list (a new `ETag`), and
  /// that clears them; a tab opened on an unchanged list (a `304`) keeps them.
  /// Per sign-in like the list. A few hundred at most, about 1 KB each.
  final Map<int, ProductDetail> _details = {};
  final Map<int, Future<ProductDetail>> _detailsLoading = {};
  String? _detailsSession;
  /// Bumped each time what is held is thrown away, so a load begun before
  /// is not kept after.
  int _detailsGeneration = 0;
  static const _maxDetails = 300;

  /// How many products [prefetchDetails] loads at once while a search is
  /// typed: the top of the list, which is what gets tapped.
  static const prefetchCount = 3;

  /// The signed-in shop's products, or null before they first arrive.
  ProductIndex? get index => _session != null && _session == ApiClient.instance.token ? _index : null;

  bool get isLoading => _fetching != null;

  /// The product's batches if already fetched for this sign-in, else null.
  ProductDetail? detailFor(int productId) {
    _checkDetailsSession();
    return _details[productId];
  }

  /// The product's batches, from what is held or else from the server.
  /// Callers at the same moment share one request. Throws as
  /// `getProductDetail` does (404: merged away).
  Future<ProductDetail> loadDetail(int productId) {
    _checkDetailsSession();
    final held = _details[productId];
    if (held != null) return Future.value(held);
    final running = _detailsLoading[productId];
    if (running != null) return running;
    final generation = _detailsGeneration;
    late final Future<ProductDetail> load;
    load = ApiClient.instance.getProductDetail(productId).then((detail) {
      _checkDetailsSession();
      if (generation == _detailsGeneration) rememberDetail(detail);
      return detail;
    }).whenComplete(() {
      if (identical(_detailsLoading[productId], load)) _detailsLoading.remove(productId);
    });
    _detailsLoading[productId] = load;
    return load;
  }

  /// Starts loading the batches of [productIds] that are not held yet, in the
  /// background. A failure is ignored: the sheet asks again when opened.
  void prefetchDetails(Iterable<int> productIds) {
    for (final id in productIds) {
      unawaited(loadDetail(id).then((_) {}, onError: (_) {}));
    }
  }

  /// Keeps a product's batches a screen has just fetched or changed (the
  /// inventory screen's MRP edit), so the sale sheet shows the same.
  void rememberDetail(ProductDetail detail) {
    _checkDetailsSession();
    _details.remove(detail.id);
    _details[detail.id] = detail; // last-used at the end
    while (_details.length > _maxDetails) {
      _details.remove(_details.keys.first);
    }
  }

  void _checkDetailsSession() {
    final session = ApiClient.instance.token;
    if (_detailsSession == session) return;
    _forgetDetails();
    _detailsSession = session;
  }

  void _forgetDetails() {
    _details.clear();
    _detailsLoading.clear();
    _detailsGeneration++;
  }

  /// A product or batch the server says no longer exists: the held list is
  /// stale, so fetch it again in the background. The caller shows
  /// [mergedAwayMessage].
  void noteMergedAway() => unawaited(refresh());

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
      final held = _session == session && _index != null ? _etag : null;
      final page = await ApiClient.instance.fetchProducts(ifNoneMatch: held);
      // Signed out, or another shop signed in, while it was on its way.
      if (session == null || session != ApiClient.instance.token) return;
      if (page != null) {
        _index = ProductIndex(page.products);
        _etag = page.etag;
        // Stock or batches changed somewhere: what was held may be wrong.
        _forgetDetails();
      }
      // null: a 304 — the list held is the server's current one.
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
