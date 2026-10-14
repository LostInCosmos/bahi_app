import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/features/invoice/models/purchase_export.dart';
import 'package:gst_bill_app/features/invoice/presentation/purchases_screen.dart';

/// Export in a Purchases folder's menu, then the GSTR2 file: GET /export/excel?folder_id=N.
///
/// A server that predates the filter ignores it and sends every bill, so the
/// app shares nothing unless the server echoes the folder id back.

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

const _folders = [
  {'id': 2, 'parent_id': null, 'name': 'Oct', 'created_at': '2026-10-01T00:00:00', 'bill_count': 3},
];

/// A fake server. [echo] is what it says in X-Export-Folder-Id (null: nothing,
/// as an old server would).
class _Server {
  _Server({this.echo, this.exportStatus = 200, this.basisEcho, this.count = '3', this.excluded});
  final String? echo;
  final int exportStatus;

  /// What it says in X-Export-Date-Basis (null: nothing, as an old server).
  final String? basisEcho;
  final String count;

  /// What it says in X-Export-Excluded-Under-Review (null: nothing, as an old server).
  final String? excluded;
  final exports = <Uri>[];
  final lists = <Uri>[];

  http.Response handle(http.Request req) {
    final path = req.url.path;
    if (path == '/folders') return _json(_folders);
    if (path == '/invoices') {
      lists.add(req.url);
      return _json([]);
    }
    if (path == '/export/excel') {
      exports.add(req.url);
      if (exportStatus != 200) return _json({'detail': 'Folder not found'}, exportStatus);
      return http.Response.bytes([1, 2, 3], 200, headers: {
        if (echo != null) 'x-export-folder-id': echo!,
        'x-export-bill-count': count,
        if (basisEcho != null) 'x-export-date-basis': basisEcho!,
        if (excluded != null) 'x-export-excluded-under-review': excluded!,
      });
    }
    return _json({'detail': 'unexpected $path'}, 404);
  }
}

void main() {
  final api = ApiClient.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'token': 't'});
    api.token = 't';
  });

  group('exportExcel', () {
    test('a folder export sends the folder and nothing else', () async {
      final server = _Server(echo: '2');
      final out = await http.runWithClient(() => api.exportExcel(folderId: 2), () => MockClient((r) async => server.handle(r)));
      expect(server.exports.single.queryParameters, {'folder_id': '2'});
      expect(out.bytes, [1, 2, 3]);
      expect(out.billCount, 3);
    });

    test('a range is sent as "uploaded between" and accepted when the server says so', () async {
      final server = _Server(basisEcho: 'uploaded');
      final out = await http.runWithClient(
          () => api.exportExcel(startDate: '2026-04-01', endDate: '2026-04-30'), () => MockClient((r) async => server.handle(r)));
      expect(server.exports.single.queryParameters,
          {'start_date': '2026-04-01', 'end_date': '2026-04-30', 'date_basis': 'uploaded'});
      expect(out.dateBasis, 'uploaded');
    });

    test('a server that did not echo the date basis is refused (it matched bill dates)', () async {
      for (final echo in [null, 'bill']) {
        final server = _Server(basisEcho: echo);
        await expectLater(
          http.runWithClient(() => api.exportExcel(startDate: '2026-04-01'), () => MockClient((r) async => server.handle(r))),
          throwsA(isA<ApiException>().having((e) => e.message, 'message', contains("by upload date"))),
          reason: 'echo: $echo',
        );
      }
    });

    test('with no range there is no basis to send or check', () async {
      final server = _Server();
      final out = await http.runWithClient(() => api.exportExcel(), () => MockClient((r) async => server.handle(r)));
      expect(server.exports.single.queryParameters, isEmpty);
      expect(out.folderId, isNull);
    });

    test('the bill list uses the same basis, so list and file agree', () async {
      final server = _Server();
      await http.runWithClient(() async {
        await api.listInvoices(startDate: '2026-04-01', endDate: '2026-04-30');
        await api.listInvoices();
      }, () => MockClient((r) async => server.handle(r)));
      expect(server.lists.first.queryParameters['date_basis'], 'uploaded');
      expect(server.lists.last.queryParameters.containsKey('date_basis'), isFalse);
    });

    test('a server that does not echo the folder is refused (it sent every bill)', () async {
      final server = _Server();
      await expectLater(
        http.runWithClient(() => api.exportExcel(folderId: 2), () => MockClient((r) async => server.handle(r))),
        throwsA(isA<ApiException>().having((e) => e.message, 'message', contains("can't export a single folder"))),
      );
    });

    test('an echo for a different folder is refused', () async {
      final server = _Server(echo: '9');
      await expectLater(
        http.runWithClient(() => api.exportExcel(folderId: 2), () => MockClient((r) async => server.handle(r))),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('Purchases folder menu', () {
    Future<_Server> exportFromMenu(WidgetTester tester, _Server server) async {
      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PurchasesScreen())));
        // Loads only when its tab is selected, as HomeScreen does.
        final state = tester.state<PurchasesScreenState>(find.byType(PurchasesScreen));
        await tester.runAsync(() => state.refresh());
        await tester.pump();
        await tester.longPress(find.text('Oct'));
        await tester.pumpAndSettle();
        // The screen's own whole-range Export button shares the word.
        await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('Export')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('GSTR2 purchase register'));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pumpAndSettle();
      }, () => MockClient((r) async => server.handle(r)));
      return server;
    }

    testWidgets('a folder deleted elsewhere says so and reloads', (tester) async {
      final server = await exportFromMenu(tester, _Server(exportStatus: 404));
      expect(find.text('That folder no longer exists.'), findsOneWidget);
      expect(server.exports, hasLength(1));
    });

    testWidgets('the main Export button opens the same sheet, for all saved bills with no range', (tester) async {
      final server = _Server(count: '0');
      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PurchasesScreen())));
        final state = tester.state<PurchasesScreenState>(find.byType(PurchasesScreen));
        await tester.runAsync(() => state.refresh());
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Export'));
        await tester.pumpAndSettle();
        expect(find.text('All saved bills'), findsOneWidget);
        await tester.tap(find.text('GSTR2 purchase register'));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pumpAndSettle();
      }, () => MockClient((r) async => server.handle(r)));
      // An empty file is not shared.
      expect(find.text('No bills in this range.'), findsOneWidget);
      expect(server.exports.single.queryParameters, isEmpty);
    });

    testWidgets('bills left out because they are under review are mentioned, and an all-excluded export is not shared', (tester) async {
      final server = _Server(count: '0', excluded: '4');
      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PurchasesScreen())));
        final state = tester.state<PurchasesScreenState>(find.byType(PurchasesScreen));
        await tester.runAsync(() => state.refresh());
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Export'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('GSTR2 purchase register'));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pumpAndSettle();
      }, () => MockClient((r) async => server.handle(r)));
      expect(find.text('4 bills are still being checked and were not included.'), findsOneWidget);
      expect(find.text('No bills in this range.'), findsNothing);
    });

    testWidgets('the pickers say the range is by upload date', (tester) async {
      await http.runWithClient(() async {
        await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PurchasesScreen())));
      }, () => MockClient((r) async => _Server().handle(r)));
      expect(find.text('Uploaded from'), findsOneWidget);
      expect(find.text('Uploaded to'), findsOneWidget);
    });

    testWidgets('an old server shares nothing and says why', (tester) async {
      await exportFromMenu(tester, _Server());
      expect(find.text("This server can't export a single folder yet."), findsOneWidget);
    });
  });

  test('the excluded count is read from the header; absent means none left out', () {
    expect(PurchaseExport.fromResponse(const [], {'x-export-excluded-under-review': '3'}).excludedUnderReview, 3);
    expect(PurchaseExport.fromResponse(const [], {'x-export-excluded-under-review': '0'}).excludedUnderReview, 0);
    expect(PurchaseExport.fromResponse(const [], {}).excludedUnderReview, 0);
    expect(PurchaseExport.fromResponse(const [], {'x-export-excluded-under-review': 'x'}).excludedUnderReview, 0);
  });

  test('the note for bills left out', () {
    expect(excludedNote(0), isNull);
    expect(excludedNote(1), '1 bill is still being checked and was not included.');
    expect(excludedNote(12), '12 bills are still being checked and were not included.');
  });

  test('the sheet names what the range selects', () {
    expect(exportRangeLabel(), 'All saved bills');
    expect(exportRangeLabel(start: '2026-04-01', end: '2026-04-30'), 'Bills uploaded 2026-04-01 to 2026-04-30');
    expect(exportRangeLabel(start: '2026-04-01'), 'Bills uploaded from 2026-04-01');
    expect(exportRangeLabel(end: '2026-04-30'), 'Bills uploaded up to 2026-04-30');
    expect(exportRangeLabel(start: '2026-04-01', vendorGstin: ' 09AAA '), 'Bills uploaded from 2026-04-01 · supplier 09AAA');
    expect(exportRangeLabel(vendorGstin: ' '), 'All saved bills');
  });
}
