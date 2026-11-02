import 'dart:math';

/// One write the shopkeeper asked for, however many times it has to be sent.
///
/// Its value goes up as the `Idempotency-Key` header; the server replays its
/// first answer for the same shop, route and key, so a write whose answer was
/// lost (a timeout, a dropped connection) can be sent again without being
/// done twice — a second sale, a second bill, a second voice job.
///
/// The key is kept only across such a loss. Once the server has answered,
/// 2xx or 4xx, [answered] gives the next send a new key: a refusal is never
/// replayed at a corrected request, and the same request sent again on
/// purpose is a new write. A changed request (a different [fingerprint])
/// gets a new key by itself, so an edit after a lost answer is never
/// refused as `key_reused`.
class IdempotencyKey {
  String _value = _fresh();
  String? _fingerprint;

  /// The key for a request whose content is [fingerprint] (the JSON body,
  /// or what identifies an upload): the same while the content is the same.
  String keyFor(String fingerprint) {
    if (fingerprint != _fingerprint) {
      _fingerprint = fingerprint;
      _value = _fresh();
    }
    return _value;
  }

  /// The server answered the attempt under the current key; the next send is
  /// a new attempt.
  void answered() {
    _value = _fresh();
    _fingerprint = null;
  }

  static final _random = Random.secure();
  static String _fresh() =>
      List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
