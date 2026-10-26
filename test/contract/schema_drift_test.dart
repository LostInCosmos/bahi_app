import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// DAS-136: the phone's JSON readers against the backend's OpenAPI document.
///
/// The phone reads server JSON through hand-written readers (`JsonReads` in
/// `core/utils/json.dart`). Nothing compared them with what the server
/// describes, so a renamed, retyped or newly optional field was found by a
/// shopkeeper, and a field the phone never sent back was found the same way
/// (DAS-9: the review screen re-sent a line without `discount`, and the
/// server flagged six errors on a clean bill).
///
/// What it checks, reading the Dart source of each model in [_models]:
/// 1. every key a `fromJson` reads exists in the schema;
/// 2. every key it reads with a `…Req` method (throws when absent) is in the
///    schema's `required` list and not nullable there;
/// 3. the JSON type the reader expects matches the schema's type;
/// 4. for a model the phone sends back (review save, revalidate), `toJson`
///    writes every property of the schema it is sent as — a field the server
///    sends and the phone drops is the DAS-9 class.
///
/// The document is `test/contract/openapi.json`, a copy of `/openapi.json`
/// from the backend's `main` (refresh: `tool/contract/refresh_openapi.sh`).
/// What it cannot catch: endpoints the server returns as an untyped dict
/// (listed in [_undescribed]); a field whose meaning changes under the same
/// name and type; anything not yet merged to the backend's main.
void main() {
  final doc = jsonDecode(File('test/contract/openapi.json').readAsStringSync()) as Map<String, dynamic>;
  final schemas = (doc['components'] as Map<String, dynamic>)['schemas'] as Map<String, dynamic>;

  for (final m in _models) {
    test('${m.dartClass} matches ${m.schema}', () {
      final source = File(m.file).readAsStringSync();
      final problems = <String>[];
      final schema = schemas[m.schema] as Map<String, dynamic>;
      final props = (schema['properties'] as Map<String, dynamic>?) ?? const {};
      final required = {...?(schema['required'] as List<dynamic>?)?.cast<String>()};

      for (final read in _reads(_fromJsonBody(source, m.dartClass))) {
        final prop = props[read.key] as Map<String, dynamic>?;
        if (prop == null) {
          problems.add("reads '${read.key}', which ${m.schema} does not have");
          continue;
        }
        final types = _types(prop, schemas);
        if (read.required) {
          if (!required.contains(read.key)) {
            problems.add("requires '${read.key}' (${read.method}), but ${m.schema} marks it optional");
          } else if (types.contains('null')) {
            problems.add("requires '${read.key}' (${read.method}), but ${m.schema} allows null");
          }
        }
        final wanted = _expected[read.method];
        if (wanted != null && types.difference({'null'}).isNotEmpty && types.intersection(wanted).isEmpty) {
          problems.add("reads '${read.key}' as ${wanted.join('/')} (${read.method}), "
              "but ${m.schema} says ${types.join('/')}");
        }
      }

      final sendsAs = m.sendsAs;
      if (sendsAs != null) {
        final sent = _writes(_toJsonBody(source, m.dartClass));
        final sendProps = ((schemas[sendsAs] as Map<String, dynamic>)['properties'] as Map<String, dynamic>).keys;
        final dropped = [for (final k in sendProps) if (!sent.contains(k)) k]..sort();
        if (dropped.isNotEmpty) {
          problems.add('toJson does not send back ${dropped.join(', ')} of $sendsAs '
              '(a field the server sends and the phone drops: the DAS-9 class)');
        }
      }

      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  test('every endpoint the phone reads is either checked above or listed as undescribed', () {
    final paths = doc['paths'] as Map<String, dynamic>;
    final untyped = <String>[];
    for (final e in _undescribed) {
      final op = (paths[e.path] as Map<String, dynamic>?)?[e.method] as Map<String, dynamic>?;
      expect(op, isNotNull, reason: '${e.method.toUpperCase()} ${e.path} is gone from the document');
      final ok = (op!['responses'] as Map<String, dynamic>).entries.where((r) => r.key.startsWith('2'));
      final described = ok.any((r) => ((r.value as Map)['content'] as Map?)?['application/json']?['schema']?['\$ref'] != null);
      if (!described) untyped.add('${e.method.toUpperCase()} ${e.path}');
    }
    // A described one should move into [_models] so it is checked.
    expect(untyped.length, _undescribed.length,
        reason: 'the server now describes some of these; add them to _models: ${_undescribed.length - untyped.length}');
  });
}

/// The phone's models and the schema each is read from. [sendsAs] is set when
/// the phone also sends the model back to the server.
class _Model {
  final String dartClass;
  final String file;
  final String schema;
  final String? sendsAs;
  const _Model(this.dartClass, this.file, this.schema, {this.sendsAs});
}

const _invoice = 'lib/features/invoice/models/invoice.dart';
const _models = [
  _Model('UploadSummary', 'lib/features/capture/models/upload_summary.dart', 'ExtractionJobBrief'),
  _Model('UploadPage', 'lib/features/capture/models/upload_summary.dart', 'ExtractionJobPage'),
  _Model('JobStatusBrief', 'lib/features/invoice/models/job_status.dart', 'JobStatusBrief'),
  _Model('JobStatusBatch', 'lib/features/invoice/models/job_status.dart', 'JobStatusBatch'),
  _Model('ExtractionJob', _invoice, 'ExtractionJobStatus'),
  _Model('ExtractionResult', _invoice, 'ExtractionResult'),
  _Model('ExtractionMeta', _invoice, 'ExtractionMeta', sendsAs: 'ExtractionMeta'),
  _Model('LineItem', _invoice, 'LineItemIn', sendsAs: 'LineItemIn'),
  _Model('Totals', _invoice, 'Totals', sendsAs: 'Totals'),
  _Model('InvoiceData', _invoice, 'InvoiceIn', sendsAs: 'InvoiceIn'),
  _Model('ValidationIssue', _invoice, 'ValidationIssue'),
  _Model('RevalidateResult', _invoice, 'RevalidateResult'),
  _Model('AccountInfo', 'lib/features/auth/models/account.dart', 'AccountOut'),
  _Model('LegalStatus', 'lib/features/auth/models/account.dart', 'LegalOut'),
  _Model('VoiceOrderJob', 'lib/features/voice/models/voice.dart', 'VoiceParseJobStatus'),
  _Model('VoiceCommandResult', 'lib/features/voice/models/voice.dart', 'VoiceCommandResponse'),
];

/// Endpoints the phone reads that the server returns without a response
/// schema today, so no reader behind them can be checked. Asking Backend to
/// declare them is the way to bring them in.
class _Endpoint {
  final String method;
  final String path;
  const _Endpoint(this.method, this.path);
}

const _undescribed = [
  _Endpoint('get', '/invoices'),
  _Endpoint('get', '/invoices/{invoice_id}'),
  _Endpoint('get', '/folders'),
  _Endpoint('get', '/inventory/products'),
  _Endpoint('get', '/inventory/products/{product_id}'),
  _Endpoint('get', '/sales'),
  _Endpoint('get', '/sales/{sale_id}'),
  _Endpoint('post', '/invoices/bulk-move'),
  _Endpoint('post', '/invoices/bulk-discard'),
];

/// The JSON types each JsonReads method accepts.
const _expected = {
  'str': {'string'}, 'strOr': {'string'}, 'strReq': {'string'}, 'text': {'string'},
  'dbl': {'number', 'integer'}, 'dblOr': {'number', 'integer'}, 'dblReq': {'number', 'integer'},
  'integer': {'integer'}, 'intOr': {'integer'}, 'intReq': {'integer'},
  'boolean': {'boolean'}, 'boolOr': {'boolean'}, 'boolReq': {'boolean'},
  'dateOnly': {'string'}, 'dateOnlyReq': {'string'}, 'utc': {'string'}, 'utcLenient': {'string'},
  'obj': {'object'}, 'objOf': {'object'},
  'listOf': {'array'}, 'strList': {'array'}, 'intList': {'array'},
};

class _Read {
  final String method;
  final String key;
  bool get required => method.endsWith('Req');
  const _Read(this.method, this.key);
}

/// Every `json.<method>('key'` in a reader body.
List<_Read> _reads(String body) => [
      for (final m in RegExp(r"json\.(\w+)(?:<[^>]*>)?\('([a-z_0-9]+)'").allMatches(body)) _Read(m[1]!, m[2]!),
    ];

/// Every `'key':` in a toJson body.
Set<String> _writes(String body) => {for (final m in RegExp(r"'([a-z_0-9]+)'\s*:").allMatches(body)) m[1]!};

String _fromJsonBody(String source, String cls) {
  final start = RegExp('(factory $cls\\.fromJson\\(|static $cls\\?? fromJson\\()').firstMatch(source);
  expect(start, isNotNull, reason: 'no fromJson for $cls');
  return _declaration(source, start!.end);
}

String _toJsonBody(String source, String cls) {
  final classStart = source.indexOf(RegExp('class $cls\\b'));
  final start = RegExp(r'Map<String, dynamic> toJson\(\)').firstMatch(source.substring(classStart));
  expect(start, isNotNull, reason: 'no toJson for $cls');
  return _declaration(source, classStart + start!.end);
}

/// The text from [from] to the end of the declaration: the `;` (or closing
/// brace) at the depth it started.
String _declaration(String s, int from) {
  var depth = 0;
  for (var i = from; i < s.length; i++) {
    final c = s[i];
    if ('({['.contains(c)) depth++;
    if (')}]'.contains(c)) {
      depth--;
      if (depth < 0) return s.substring(from, i);
    }
    if (c == ';' && depth == 0) return s.substring(from, i);
  }
  return s.substring(from);
}

/// The JSON types a property allows, following `$ref`, `anyOf` and `allOf`.
Set<String> _types(Map<String, dynamic> prop, Map<String, dynamic> schemas) {
  final ref = prop[r'$ref'] as String?;
  if (ref != null) {
    final target = schemas[ref.split('/').last] as Map<String, dynamic>;
    return target.containsKey('type') ? {target['type'] as String} : {'object'};
  }
  final type = prop['type'];
  if (type is String) return {type};
  if (type is List) return type.cast<String>().toSet();
  final any = (prop['anyOf'] ?? prop['oneOf'] ?? prop['allOf']) as List<dynamic>?;
  if (any != null) return {for (final p in any) ..._types(p as Map<String, dynamic>, schemas)};
  return const {}; // untyped (Any): nothing to compare
}
