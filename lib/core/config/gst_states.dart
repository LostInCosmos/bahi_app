/// The state a GSTIN belongs to: its first two digits are the GST state code.
/// What a bill prints as "State: Uttar Pradesh (09)" (DAS-121).
const Map<String, String> kGstStates = {
  '01': 'Jammu and Kashmir', '02': 'Himachal Pradesh', '03': 'Punjab', '04': 'Chandigarh',
  '05': 'Uttarakhand', '06': 'Haryana', '07': 'Delhi', '08': 'Rajasthan', '09': 'Uttar Pradesh',
  '10': 'Bihar', '11': 'Sikkim', '12': 'Arunachal Pradesh', '13': 'Nagaland', '14': 'Manipur',
  '15': 'Mizoram', '16': 'Tripura', '17': 'Meghalaya', '18': 'Assam', '19': 'West Bengal',
  '20': 'Jharkhand', '21': 'Odisha', '22': 'Chhattisgarh', '23': 'Madhya Pradesh', '24': 'Gujarat',
  '26': 'Dadra and Nagar Haveli and Daman and Diu', '27': 'Maharashtra', '29': 'Karnataka',
  '30': 'Goa', '31': 'Lakshadweep', '32': 'Kerala', '33': 'Tamil Nadu', '34': 'Puducherry',
  '35': 'Andaman and Nicobar Islands', '36': 'Telangana', '37': 'Andhra Pradesh', '38': 'Ladakh',
};

/// "Uttar Pradesh (09)" for a GSTIN, or null when there is none or its code
/// is not one of the states.
String? stateOfGstin(String? gstin) {
  if (gstin == null || gstin.length < 2) return null;
  final code = gstin.substring(0, 2);
  final name = kGstStates[code];
  return name == null ? null : '$name ($code)';
}
