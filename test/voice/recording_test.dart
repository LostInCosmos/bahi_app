import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gst_bill_app/features/voice/widgets/recording.dart';

/// The recording pieces the voice sale and voice command screens share.
void main() {
  test('elapsed time reads mm:ss', () {
    expect(formatElapsed(Duration.zero), '00:00');
    expect(formatElapsed(const Duration(seconds: 59)), '00:59');
    expect(formatElapsed(const Duration(minutes: 1, seconds: 5)), '01:05');
    expect(formatElapsed(const Duration(minutes: 12, seconds: 30)), '12:30');
  });

  Future<void> pumpButton(WidgetTester tester, MicButton button) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: button))));

  testWidgets('idle it shows a mic; recording, the icon its screen asked for', (tester) async {
    await pumpButton(tester, MicButton(recording: false, enabled: true, recordingIcon: Icons.stop, onTap: () {}));
    expect(find.byIcon(Icons.mic), findsOneWidget);

    await pumpButton(tester, MicButton(recording: true, enabled: true, recordingIcon: Icons.stop, onTap: () {}));
    expect(find.byIcon(Icons.stop), findsOneWidget);

    await pumpButton(tester, MicButton(recording: true, enabled: true, recordingIcon: Icons.pause, onTap: () {}));
    expect(find.byIcon(Icons.pause), findsOneWidget);
  });

  testWidgets('a disabled button ignores taps', (tester) async {
    var taps = 0;
    await pumpButton(tester, MicButton(recording: false, enabled: false, recordingIcon: Icons.stop, onTap: () => taps++));
    await tester.tap(find.byType(MicButton));
    expect(taps, 0);

    await pumpButton(tester, MicButton(recording: false, enabled: true, recordingIcon: Icons.stop, onTap: () => taps++));
    await tester.tap(find.byType(MicButton));
    expect(taps, 1);
  });
}
