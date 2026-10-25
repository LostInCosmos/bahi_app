/// A rupee amount in words, the Indian way (lakh, crore), as a bill prints it:
/// `1234.50` → "Rupees One Thousand Two Hundred Thirty-Four and Fifty Paise Only".
String rupeesInWords(double amount) {
  final paise = (amount.abs() * 100).round();
  final rupees = paise ~/ 100;
  final rest = paise % 100;
  final words = rupees == 0 ? 'Zero' : _indian(rupees);
  return rest == 0 ? 'Rupees $words Only' : 'Rupees $words and ${_belowHundred(rest)} Paise Only';
}

const _ones = [
  '', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten',
  'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen',
];
const _tens = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];

String _belowHundred(int n) =>
    n < 20 ? _ones[n] : (n % 10 == 0 ? _tens[n ~/ 10] : '${_tens[n ~/ 10]}-${_ones[n % 10]}');

String _belowThousand(int n) {
  final h = n ~/ 100, r = n % 100;
  return [if (h > 0) '${_ones[h]} Hundred', if (r > 0) _belowHundred(r)].join(' ');
}

String _indian(int n) {
  final parts = <String>[];
  final crore = n ~/ 10000000;
  n %= 10000000;
  final lakh = n ~/ 100000;
  n %= 100000;
  final thousand = n ~/ 1000;
  n %= 1000;
  if (crore > 0) parts.add('${_indian(crore)} Crore');
  if (lakh > 0) parts.add('${_belowHundred(lakh)} Lakh');
  if (thousand > 0) parts.add('${_belowHundred(thousand)} Thousand');
  if (n > 0) parts.add(_belowThousand(n));
  return parts.join(' ');
}
