library;

import '../../../core/utils/format.dart';
import '../../../core/utils/json.dart';

/// How a medicine is counted when it is sold by the tablet (DAS-160). The
/// server sends these beside `quantity_on_hand`, which stays in packs for
/// older builds; a server without them, or a medicine whose pack is not
/// known, reads as [none] and is sold in packs exactly as before.
class LooseStock {
  /// Tablets (or capsules) in one pack, e.g. 10 for a strip of 10.
  final int? unitsPerPack;

  /// The server's effective answer: true means every sale line counts tablets.
  final bool soldLoose;

  /// "tablet", "capsule", or null when the pack gives only a count.
  final String? unitKind;

  /// Stock in tablets, already summed per batch by the server.
  final int? unitsOnHand;

  /// MRP ÷ [unitsPerPack], rounded down: the price a tablet starts at.
  final double? unitMrp;

  /// The server answered at all: false from one older than DAS-160.
  final bool reported;

  const LooseStock(
      {this.unitsPerPack, this.soldLoose = false, this.unitKind, this.unitsOnHand, this.unitMrp, this.reported = false});

  static const none = LooseStock();

  factory LooseStock.fromJson(Map<String, dynamic> json) => LooseStock(
        unitsPerPack: json.integer('units_per_pack'),
        soldLoose: json.boolean('sold_loose') ?? false,
        unitKind: json.str('unit_kind'),
        unitsOnHand: json.integer('units_on_hand'),
        unitMrp: json.dbl('unit_mrp'),
        reported: json.containsKey('sold_loose'),
      );

  /// Sold by the tablet. The server refuses a loose line without a pack size,
  /// so both must be there.
  bool get loose => soldLoose && unitsPerPack != null;

  /// A server that knows about loose sales says this one is sold only as a
  /// whole pack: a bottle, syrup or tube, or a pack it cannot count.
  bool get wholeOnly => reported && !loose;

  /// "tablet" / "capsule" / "unit", singular.
  String get word => unitWord(unitKind);

  /// "Tablets": the quantity field's label on a loose line.
  String get fieldLabel => unitFieldLabel(unitKind);

  /// [n] in this medicine's smallest unit: "20 tablets".
  String count(num n) => unitCount(n, unitKind);

  /// The stock to show: "45 tablets" when sold loose, else the pack count as
  /// before ("3").
  String stock(double packs) {
    final units = unitsOnHand;
    return loose && units != null ? count(units) : qty(packs);
  }

  /// "4 strips + 5" for 45 tablets in strips of 10, or null when there is no
  /// whole pack, or the stock is in more than one pack size (a box of 100 and
  /// strips of 10 do not split into one kind of pack).
  String? packBreakdown(double packs) {
    final per = unitsPerPack;
    final units = unitsOnHand;
    if (!loose || per == null || per <= 1 || units == null || units <= 0) return null;
    if ((packs * per).round() != units) return null;
    final whole = units ~/ per;
    if (whole == 0) return null;
    final rest = units % per;
    final packWord = plural(whole, per <= 30 ? 'strip' : 'pack');
    return rest == 0 ? packWord : '$packWord + $rest';
  }

  /// "Strip of 10, so 2 strips = 20 tablets": how a strip becomes a count.
  String? get typingHint {
    final per = unitsPerPack;
    if (!loose || per == null || per <= 1) return null;
    final pack = per <= 30 ? 'strip' : 'pack';
    return '${pack[0].toUpperCase()}${pack.substring(1)} of $per, so 2 ${pack}s = ${count(2 * per)}';
  }
}

/// The singular word for a loose unit kind from the server.
String unitWord(String? unitKind) => switch (unitKind) {
      'tablet' => 'tablet',
      'capsule' => 'capsule',
      _ => 'unit',
    };

/// "20 tablets", "1 capsule".
String unitCount(num n, String? unitKind) => '${qty(n)} ${n == 1 ? unitWord(unitKind) : '${unitWord(unitKind)}s'}';

/// "Tablets" / "Capsules" / "Units".
String unitFieldLabel(String? unitKind) {
  final w = unitWord(unitKind);
  return '${w[0].toUpperCase()}${w.substring(1)}s';
}
