import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gst_bill_app/core/api/api_client.dart';
import 'package:gst_bill_app/core/config/legal_documents.dart';
import 'package:gst_bill_app/features/auth/presentation/account_screen.dart';
import 'package:gst_bill_app/features/auth/presentation/legal_screen.dart';
import 'package:gst_bill_app/features/auth/presentation/login_screen.dart';

/// The Terms of Service and Privacy Policy: well formed, reachable before and
/// after sign-in, and a condition of creating an account (DPDP Act s.6:
/// consent by a clear affirmative action).
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.instance.token = null;
  });

  test('both documents exist, are versioned, and have no empty section', () {
    final ids = legalDocuments.map((d) => d.id).toList();
    expect(ids, ['terms', 'privacy']);
    for (final d in legalDocuments) {
      expect(d.version, isNotEmpty);
      expect(d.effectiveDate, isNotEmpty);
      expect(d.sections, isNotEmpty);
      for (final s in d.sections) {
        expect(s.heading, isNotEmpty);
        expect(s.paragraphs.length + s.bullets.length + s.after.length, greaterThan(0), reason: s.heading);
      }
    }
    expect(legalDocumentById('privacy').title, 'Privacy Policy');
  });

  test('the privacy policy says what the law asks a notice to say', () {
    final text = legalDocumentToMarkdown(kPrivacyPolicy);
    // DPDP s.5 / Rules r.3: itemised data, purposes, rights, how to complain.
    expect(text, contains('What we collect'));
    expect(text, contains('Why we use it'));
    expect(text, contains('Your rights'));
    expect(text, contains('Data Protection Board'));
    // SPDI Rules r.4 and r.5(9): disclosure, security, a Grievance Officer.
    expect(text, contains('Who else handles it'));
    expect(text, contains('How we protect it'));
    expect(text, contains('Grievance Officer'));
    // Apple 5.1.1(i): retention/deletion and how to revoke consent.
    expect(text, contains('How long we keep data'));
    expect(text, contains('Withdraw consent'));
    // Markers are resolved, never shown.
    expect(text, isNot(contains('{{')));
  });

  test('compareLegalVersions orders dotted versions as numbers', () {
    expect(compareLegalVersions('1.1', '1.1'), 0);
    expect(compareLegalVersions('1.0', '1.1'), lessThan(0));
    expect(compareLegalVersions('1.2', '1.10'), lessThan(0));
    expect(compareLegalVersions('2.0', '1.9'), greaterThan(0));
    expect(compareLegalVersions('1', '1.0'), 0);
    expect(compareLegalVersions('1.1', ''), greaterThan(0));
  });

  test('no placeholder is left in the documents', () {
    // The owner supplied every fact on 2026-10-19; a bracketed value here
    // would be shown to a shop as-is.
    expect(legalPlaceholdersLeft(), isEmpty);
    for (final d in legalDocuments) {
      expect(legalDocumentToMarkdown(d), isNot(contains(RegExp(r'\[[A-Z][^\]]*\]'))));
    }
  });

  testWidgets('a document renders every section heading', (tester) async {
    await tester.pumpWidget(MaterialApp(home: LegalScreen(document: legalDocumentById('terms'))));
    expect(find.text('Terms of Service'), findsWidgets);
    expect(find.text(kTermsOfService.sections.first.heading), findsOneWidget);
    await tester.scrollUntilVisible(find.text(kTermsOfService.sections.last.heading), 400);
    expect(find.text(kTermsOfService.sections.last.heading), findsOneWidget);
  });

  testWidgets('signup needs the agreement ticked; the links open the documents', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    // Login mode: no checkbox, and the footer still links both documents.
    expect(find.byType(Checkbox), findsNothing);
    expect(find.text('Privacy Policy'), findsOneWidget);

    await tester.tap(find.text('Sign up'));
    await tester.pumpAndSettle();
    final create = find.widgetWithText(FilledButton, 'Create account');
    expect(create, findsOneWidget);
    expect(tester.widget<FilledButton>(create).onPressed, isNull, reason: 'disabled until the terms are accepted');

    await tester.ensureVisible(find.byKey(const ValueKey('accept-terms')));
    await tester.tap(find.byKey(const ValueKey('accept-terms')));
    await tester.pump();
    expect(tester.widget<FilledButton>(create).onPressed, isNotNull);

    await tester.ensureVisible(find.text('Privacy Policy'));
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();
    expect(find.byType(LegalScreen), findsOneWidget);
    expect(find.text(kPrivacyPolicy.sections.first.heading), findsOneWidget);
  });

  testWidgets('Account links to both documents', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AccountScreen()));
    await tester.pump(); // the account request fails without a server; the screen still builds
    await tester.pumpAndSettle();
    // Below the shop details, which grew with the bill's fields (DAS-121).
    await tester.scrollUntilVisible(find.text('Terms of Service'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Terms of Service'), findsOneWidget);
    await tester.tap(find.text('Terms of Service'));
    await tester.pumpAndSettle();
    expect(find.byType(LegalScreen), findsOneWidget);
  });
}
