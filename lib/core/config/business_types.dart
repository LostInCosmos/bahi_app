import 'package:flutter/material.dart';

/// The kinds of shop Dastavez knows. The server keys bill reading and
/// validation on the `key` (a kirana bill's columns differ from a pharmacy's),
/// and the app's colour scheme follows it (`app/theme`). Login and Account
/// both offer this list; a new kind of shop is one more entry here.
class BusinessType {
  final String key;
  final String label;
  const BusinessType(this.key, this.label);
}

const kBusinessTypes = [
  BusinessType('medical', 'Medical / Pharmacy'),
  BusinessType('kirana', 'Kirana / General store'),
  BusinessType('other', 'Other'),
];

/// What a shop is until it says otherwise — and what the theme falls back to.
const kDefaultBusinessType = 'medical';

/// The dropdown entries for [kBusinessTypes].
List<DropdownMenuItem<String>> businessTypeItems() =>
    [for (final t in kBusinessTypes) DropdownMenuItem(value: t.key, child: Text(t.label))];
