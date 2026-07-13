// test/utils/flow_format_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/utils/flow_format.dart';

void main() {
  group('FlowFormat.grouped', () {
    test('inserts thousands separators on the rounded integer', () {
      expect(FlowFormat.grouped(30508.4), '30,508');
      expect(FlowFormat.grouped(1234567), '1,234,567');
      expect(FlowFormat.grouped(999), '999');
      expect(FlowFormat.grouped(1000), '1,000');
    });

    test('rounds to nearest integer', () {
      expect(FlowFormat.grouped(430.5), '431');
      expect(FlowFormat.grouped(430.4), '430');
    });

    test('handles zero', () {
      expect(FlowFormat.grouped(0), '0');
    });
  });

  group('FlowFormat.compact', () {
    test('abbreviates millions and thousands to one decimal', () {
      expect(FlowFormat.compact(1200000), '1.2M');
      expect(FlowFormat.compact(30500), '30.5K');
      expect(FlowFormat.compact(1000), '1.0K');
      expect(FlowFormat.compact(1000000), '1.0M');
    });

    test('100..999 shows a whole number', () {
      expect(FlowFormat.compact(430), '430');
      expect(FlowFormat.compact(100), '100');
      expect(FlowFormat.compact(999.6), '1000'); // rounds to 1000 at 0 decimals
    });

    test('below 100 shows one decimal', () {
      expect(FlowFormat.compact(4.2), '4.2');
      expect(FlowFormat.compact(99.9), '99.9');
      expect(FlowFormat.compact(0), '0.0');
    });
  });
}
