/// Barrel file — the models used to all live directly in here; they're now
/// split by domain under models/ for navigability, re-exported from this one
/// path so every existing `import 'models.dart'` across the app keeps
/// working unchanged.
library;

export 'models/account.dart';
export 'models/invoice.dart';
export 'models/product.dart';
export 'models/sale.dart';
export 'models/voice.dart';
