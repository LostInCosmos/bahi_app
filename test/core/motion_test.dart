import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/app/theme/app_theme.dart';

/// Quality pass: every animation asks `motion()` for its duration, so a
/// device set to reduced motion gets the change without the movement.
void main() {
  Future<Duration> read(WidgetTester tester, {required bool reduced}) async {
    late Duration got;
    await tester.pumpWidget(MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Builder(builder: (context) {
        got = motion(context, 220);
        return const SizedBox();
      }),
    ));
    return got;
  }

  testWidgets('the asked-for duration normally, none under reduced motion', (tester) async {
    expect(await read(tester, reduced: false), const Duration(milliseconds: 220));
    expect(await read(tester, reduced: true), Duration.zero);
  });
}
