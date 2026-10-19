import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/core/utils/json.dart';

/// The one place every model reads the server's JSON through. These pin the
/// rules the hand-written casts followed before: a required field still
/// throws when missing, a nullable one reads as null, a numeric field accepts
/// an int or a double, and a date with a time part is trimmed to the day.
void main() {
  final json = <String, dynamic>{
    'i': 7,
    'd': 2.5,
    'whole': 3,
    's': 'x',
    'blank': '   ',
    'b': true,
    'date': '2026-10-01T00:00:00',
    'day': '2026-10-01',
    'when': '2026-10-01T10:00:00Z',
    'bad_when': 'not a date',
    'list': [
      {'n': 1},
      {'n': 2}
    ],
    'strs': ['a', 'b'],
    'ids': [1, 2.0],
    'obj': {'n': 9},
  };

  test('numbers read as int or double regardless of how the server spelled them', () {
    expect(json.dbl('i'), 7.0);
    expect(json.dblReq('whole'), 3.0);
    expect(json.integer('d'), 2);
    expect(json.intReq('i'), 7);
    expect(json.dblOr('missing', 1.5), 1.5);
    expect(json.intOr('missing'), 0);
  });

  test('a required field that is missing still throws, as the bare cast did', () {
    expect(() => json.dblReq('missing'), throwsA(isA<TypeError>()));
    expect(() => json.strReq('missing'), throwsA(isA<TypeError>()));
    expect(() => json.intReq('missing'), throwsA(isA<TypeError>()));
    expect(() => json.boolReq('missing'), throwsA(isA<TypeError>()));
  });

  test('strings: nullable, defaulted, and blank-means-nothing', () {
    expect(json.str('s'), 'x');
    expect(json.str('missing'), isNull);
    expect(json.strOr('missing', 'd'), 'd');
    expect(json.strOr('missing'), '');
    expect(json.text('blank'), isNull);
    expect(json.text('s'), 'x');
  });

  test('dates are trimmed to the day, timestamps read as UTC', () {
    expect(json.dateOnly('date'), '2026-10-01');
    expect(json.dateOnly('day'), '2026-10-01');
    expect(json.dateOnly('missing'), isNull);
    expect(json.dateOnlyReq('date'), '2026-10-01');
    expect(json.utc('when'), DateTime.utc(2026, 10, 1, 10));
    expect(json.utc('missing'), isNull);
    expect(json.utcLenient('bad_when'), isNull);
    expect(() => json.utc('bad_when'), throwsFormatException);
  });

  test('lists and objects, absent reading as empty or null', () {
    expect(json.listOf('list', (m) => m['n'] as int), [1, 2]);
    expect(json.listOf('missing', (m) => m), isEmpty);
    expect(json.strList('strs'), ['a', 'b']);
    expect(json.intList('ids'), [1, 2]);
    expect(json.objOf('obj', (m) => m['n'] as int), 9);
    expect(json.objOf('missing', (m) => m), isNull);
    expect(json.obj('obj'), {'n': 9});
    expect(json.boolOr('b'), isTrue);
    expect(json.boolOr('missing'), isFalse);
  });
}
