import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/features/capture/presentation/capture_screen.dart';

/// Saving a bill from the capture list (DAS-71).
///
/// The shopkeeper no longer corrects a flagged bill, and no longer answers a
/// question about the supplier's GSTIN. A bill — clean or flagged — is saved
/// by job: the phone sends no values, and the server saves what it read (its
/// own, or our team's correction, so the phone can never overwrite one).

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _invoice() => {
      'seller_name': 'ACME',
      'seller_gstin': '',
      'invoice_no': 'A-9',
      'invoice_date': '2026-08-01',
      'line_items': [
        {'product_name': 'Pan 40', 'qty': 2, 'rate': 50, 'gst_pct': 12, 'gross_amount': 100},
      ],
      'totals': {'subtotal': 100, 'total_cgst': 6, 'total_sgst': 6, 'grand_total': 112},
    };

class _Server {
  _Server({this.saveStatus = 200, this.saveDetail});

  /// What the save route answers.
  final int saveStatus;
  final String? saveDetail;

  final requests = <String>[];
  final saveBodies = <Map<String, dynamic>>[];
  final unsaveBodies = <Map<String, dynamic>>[];

  /// The rows of the shop's list.
  final jobs = <Map<String, dynamic>>[
    {
      'job_id': 9,
      'status': 'done',
      'source_image': '8/9.jpg',
      'created_at': '2026-10-08T12:00:00Z',
      'issue_count': 0,
      'review_state': 'none',
      'seller_name': 'CLEAN CO',
    },
    {
      'job_id': 8,
      'status': 'done',
      'source_image': '8/8.jpg',
      'created_at': '2026-10-08T11:00:00Z',
      'issue_count': 2,
      'review_state': 'pending',
      'seller_name': 'FLAGGED CO',
    },
    {
      'job_id': 7,
      'status': 'done',
      'source_image': '8/7.jpg',
      'created_at': '2026-10-08T10:00:00Z',
      'issue_count': 2,
      'review_state': 'pending',
      'invoice_id': 70,
      'seller_name': 'SAVED CO',
    },
  ];

  MockClient get client => MockClient((req) async {
        final path = req.url.path;
        requests.add('${req.method} $path');
        if (req.method == 'GET' && path == '/folders') return _json([]);
        if (req.method == 'GET' && path == '/invoices/extract') {
          return _json({'jobs': jobs, 'next_before_id': null});
        }
        final job = RegExp(r'^/invoices/extract/(\d+)$').firstMatch(path);
        if (req.method == 'GET' && job != null) {
          return _json({
            'job_id': int.parse(job.group(1)!),
            'status': 'done',
            'result': {
              'invoice': _invoice(),
              'extraction_meta': {'source_image': '8/${job.group(1)}.jpg', 'method': 'llm'},
              'issues': job.group(1) == '8'
                  ? [
                      {'field': 'totals.grand_total', 'severity': 'error', 'message': 'totals do not add up'},
                    ]
                  : [],
            },
          });
        }
        final save = RegExp(r'^/invoices/extract/(\d+)/save$').firstMatch(path);
        if (req.method == 'POST' && save != null) {
          saveBodies.add(jsonDecode(req.body) as Map<String, dynamic>);
          if (saveStatus != 200) return _json({'detail': saveDetail ?? 'no'}, saveStatus);
          return _json({'invoice_id': 99, 'review_state': 'pending'});
        }
        if (req.method == 'GET' && path == '/invoices/70') {
          return _json({
            'id': 70,
            'vendor_gstin': '',
            'vendor_name': 'SAVED CO',
            'invoice_no': 'A-70',
            'invoice_date': '2026-08-01T00:00:00',
            'subtotal': 100,
            'total_cgst': 6,
            'total_sgst': 6,
            'grand_total': 112,
            'source_image_path': '8/7.jpg',
            'extraction_method': 'llm',
            'reviewed': false,
            'review_state': 'pending',
          });
        }
        if (req.method == 'POST' && path == '/invoices/70/unsave') {
          unsaveBodies.add(jsonDecode(req.body) as Map<String, dynamic>);
          return _json({'ok': true, 'job_id': 7, 'folder_id': null, 'stock_removed': true});
        }
        if (req.method == 'POST' && path == '/invoices/extract/status') {
          await Future<void>.delayed(const Duration(seconds: 25));
          return _json({'jobs': [], 'changed': false});
        }
        return http.Response('not found', 404);
      });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _ignoreOverflow() {
  final original = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    original?.call(details);
  };
  addTearDown(() => FlutterError.onError = original);
}

Future<void> _open(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(400, 1000));
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: CaptureScreen(onBatchFinished: () {}))));
  await _settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 40));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a clean bill is saved by job: no values are sent, and nothing is asked about the GSTIN', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('j:9')));
      await _settle(tester);
      expect(find.text('Edit'), findsOneWidget, reason: 'a clean bill keeps the review form');
      await tester.tap(find.text('Looks good — save'));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1)); // the saved tick
      await _settle(tester);

      expect(server.requests, contains('POST /invoices/extract/9/save'));
      expect(server.requests, isNot(contains('POST /invoices')), reason: 'no values go back');
      expect(server.requests, isNot(contains('POST /invoices/vendor-lookup')));
      expect(server.saveBodies.single, isEmpty, reason: 'no folder was chosen, and no body');
      expect(find.textContaining('GSTIN'), findsNothing);
      await _finish(tester);
    }, () => server.client);
  });

  testWidgets('a flagged bill can be saved with one tap, and has no Edit', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('j:8')));
      await _settle(tester);

      expect(find.text('Edit'), findsNothing, reason: 'it is with our team, not the shopkeeper');
      expect(find.text('Looks good — save'), findsNothing, reason: 'nobody is asked to vouch for it');
      expect(find.text('Review & save'), findsNothing, reason: 'the review form does not open');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);

      expect(server.requests, contains('POST /invoices/extract/8/save'));
      expect(server.requests, isNot(contains('POST /invoices')));
      await _finish(tester);
    }, () => server.client);
  });

  testWidgets('a bill that is already saved is not a failure', (tester) async {
    _ignoreOverflow();
    final server = _Server(saveStatus: 409, saveDetail: 'This bill is already saved.');
    await http.runWithClient(() async {
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('j:9')));
      await _settle(tester);
      await tester.tap(find.text('Looks good — save'));
      await _settle(tester);

      expect(find.text('This bill is already saved.'), findsOneWidget);
      expect(find.text('Failed'), findsNothing);
      await _finish(tester);
    }, () => server.client);
  });

  testWidgets('moving a saved bill under review back asks nothing about its stock', (tester) async {
    _ignoreOverflow();
    final server = _Server();
    await http.runWithClient(() async {
      await _open(tester);
      final cross = find.descendant(of: find.byKey(const ValueKey('j:7')), matching: find.byIcon(Icons.close_rounded));
      await tester.tap(cross);
      await _settle(tester);

      expect(find.text('Keep stock'), findsNothing);
      expect(find.text('Remove stock'), findsNothing);
      expect(find.textContaining('taken out of inventory'), findsOneWidget);
      await tester.tap(find.text('Move back'));
      await _settle(tester);

      expect(server.unsaveBodies.single, {'remove_stock': true});
      expect(find.textContaining('Its stock was taken out of inventory.'), findsOneWidget);
      await _finish(tester);
    }, () => server.client);
  });
}
