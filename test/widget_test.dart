import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/main.dart';

void main() {
  testWidgets('app shows a loading indicator while startup state loads', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const GstBillApp());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
