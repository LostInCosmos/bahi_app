import 'package:gst_bill_app/core/utils/offset_2d.dart';
import 'package:gst_bill_app/features/capture/models/batch_item.dart';
import 'package:gst_bill_app/features/invoice/models/invoice.dart';

// A realistic read bill for measurements, built through the real models.
// 12 line items: the vault's measured typical bill (DAS-63 export, 428 bills
// of 12 lines). Shared by grid_memory_test (DAS-86) and batch_state_test
// (DAS-92).

Map<String, dynamic> _line(int i) => {
      'product_name': 'Paracetamol 650mg Tab $i',
      'pack': '15x10',
      'batch_no': 'B2603$i',
      'expiry': '03/28',
      'hsn_code': '30049099',
      'qty': 10,
      'free_qty': 1,
      'free_scheme': '10+1',
      'mrp': 32.5,
      'rate': 21.4,
      'discount_pct': 5,
      'discount_amount': 10.7,
      'gst_pct': 12,
      'cgst_pct': 6,
      'sgst_pct': 6,
      'cgst_amount': 12.2,
      'sgst_amount': 12.2,
      'gross_amount': 227.7,
    };

ExtractionResult realisticRead(int id) => ExtractionResult.fromJson({
      'invoice': {
        'seller_name': 'Sharma Medical Agency',
        'seller_gstin': '09AAACS1234F1Z5',
        'seller_address': '12, Aminabad Market, Lucknow, Uttar Pradesh 226018',
        'seller_phone': '+91 98390 12345',
        'seller_dl_no': 'UP-LKO-20B-123456',
        'invoice_no': 'SMA/26-27/$id',
        'invoice_date': '2026-10-17',
        'buyer_name': 'Test Medical Store',
        'buyer_dl_no': 'UP-LKO-21B-654321',
        'place_of_supply': 'Uttar Pradesh',
        'line_items': [for (var i = 0; i < 12; i++) _line(i)],
        'totals': {'subtotal': 2440, 'total_cgst': 146.4, 'total_sgst': 146.4, 'grand_total': 2733},
      },
      'extraction_meta': {'source_image': '8/$id.jpg', 'method': 'llm', 'confidence': 0.94},
      'issues': [],
    });

BatchItem realisticBill(int id) => BatchItem(label: 'Photo $id', pages: [
      BatchItemPage(
        photoId: '8_$id',
        memoryBytes: null,
        filename: 'bill_$id.jpg',
        corners: const [Offset2D(0, 0), Offset2D(1, 0), Offset2D(1, 1), Offset2D(0, 1)],
        rotationDegrees: 0,
      ),
    ])
      ..sourceImages = ['8/$id.jpg']
      ..status = BatchItemStatus.pendingConfirm
      ..jobId = id
      ..result = realisticRead(id)
      ..folderId = 3;
