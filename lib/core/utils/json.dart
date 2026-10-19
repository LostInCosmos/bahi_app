/// Reading a server JSON object into a model, in one place.
///
/// Every model used to spell these casts out by hand — `(json['x'] as num?)
/// ?.toDouble() ?? 0` some two hundred times — and the three ways a date was
/// trimmed to `YYYY-MM-DD` had quietly drifted. A model's `fromJson` now reads
/// as the field list it is, and a server that sends an `int` where a `double`
/// was expected (or the other way round) is read the same everywhere.
///
/// `xxx` is nullable, `xxxOr` takes a default, `xxxReq` throws on a missing
/// field exactly as the bare cast did — a required field the server stopped
/// sending should still fail loudly, not silently read as zero.
extension JsonReads on Map<String, dynamic> {
  String? str(String key) => this[key] as String?;
  String strOr(String key, [String fallback = '']) => this[key] as String? ?? fallback;
  String strReq(String key) => this[key] as String;

  /// A non-empty, trimmed string, or null — for fields the server may send
  /// as `""` to mean "nothing".
  String? text(String key) {
    final value = (this[key] as String? ?? '').trim();
    return value.isEmpty ? null : value;
  }

  double? dbl(String key) => (this[key] as num?)?.toDouble();
  double dblOr(String key, [double fallback = 0]) => (this[key] as num?)?.toDouble() ?? fallback;
  double dblReq(String key) => (this[key] as num).toDouble();

  int? integer(String key) => (this[key] as num?)?.toInt();
  int intOr(String key, [int fallback = 0]) => (this[key] as num?)?.toInt() ?? fallback;
  int intReq(String key) => (this[key] as num).toInt();

  bool? boolean(String key) => this[key] as bool?;
  bool boolOr(String key, [bool fallback = false]) => this[key] as bool? ?? fallback;
  bool boolReq(String key) => this[key] as bool;

  /// A date the server may send with a time part (`2026-10-01T00:00:00`),
  /// trimmed to the day.
  String? dateOnly(String key) => (this[key] as String?)?.split('T').first;
  String dateOnlyReq(String key) => (this[key] as String).split('T').first;

  /// An ISO timestamp as UTC, or null when absent.
  DateTime? utc(String key) {
    final raw = this[key] as String?;
    return raw == null ? null : DateTime.parse(raw).toUtc();
  }

  /// An ISO timestamp as UTC; unparseable reads as null.
  DateTime? utcLenient(String key) {
    final raw = this[key] as String?;
    return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
  }

  /// A nested object, or null.
  Map<String, dynamic>? obj(String key) => this[key] as Map<String, dynamic>?;

  /// A nested object read with [fromJson], or null when absent.
  T? objOf<T>(String key, T Function(Map<String, dynamic>) fromJson) {
    final raw = this[key] as Map<String, dynamic>?;
    return raw == null ? null : fromJson(raw);
  }

  /// A list of objects read with [fromJson]; absent reads as empty.
  List<T> listOf<T>(String key, T Function(Map<String, dynamic>) fromJson) =>
      [for (final e in this[key] as List<dynamic>? ?? const []) fromJson(e as Map<String, dynamic>)];

  /// A list of strings; absent reads as empty.
  List<String> strList(String key) => [for (final e in this[key] as List<dynamic>? ?? const []) e as String];

  /// A list of ids; absent reads as empty.
  List<int> intList(String key) => [for (final e in this[key] as List<dynamic>? ?? const []) (e as num).toInt()];
}

/// A list of objects from a decoded JSON array.
List<T> jsonListOf<T>(List<dynamic> raw, T Function(Map<String, dynamic>) fromJson) =>
    [for (final e in raw) fromJson(e as Map<String, dynamic>)];
