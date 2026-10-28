/// Which dates a sale may carry. Today by default; the shopkeeper may pick
/// another. The user's rule for now (2026-10-28): "any date for now", but
/// never after today (a date in the next financial year would use up its bill
/// 0001 early), so no back-dating limit ([kSaleDateLimits] off). The 30-day window it replaced
/// (back to 30 days ago, never before 1 April of today's financial year, never
/// in the future) is kept behind the switch, since "for now" may end. The
/// server checks the same rule and is the one that decides.
library;

/// Whether the back-dating limits apply. Off at the user's word.
const kSaleDateLimits = false;

/// How far back a sale may be dated when the limits apply.
const kSaleBackdateDays = 30;

/// With no back-dating limit the picker still needs a first day: GST began on
/// 1 July 2017.
final kGstStart = DateTime(2017, 7, 1);

/// 1 April of the financial year [day] falls in.
DateTime financialYearStart(DateTime day) => DateTime(day.month >= 4 ? day.year : day.year - 1, 4, 1);

/// The first and last dates a sale made on [today] may carry.
({DateTime first, DateTime last}) saleDateWindow(DateTime today, {bool limits = kSaleDateLimits}) {
  final day = DateTime(today.year, today.month, today.day);
  if (!limits) return (first: kGstStart, last: day);
  final back = day.subtract(const Duration(days: kSaleBackdateDays));
  final fyStart = financialYearStart(day);
  return (first: back.isBefore(fyStart) ? fyStart : back, last: day);
}

bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
