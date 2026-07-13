// test/models/1_domain/shared/flow_classification_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:rivr/models/1_domain/shared/flow_classification.dart';

void main() {
  const rp = {2: 1000.0, 5: 2000.0, 10: 3000.0, 25: 4000.0};

  group('indexFor', () {
    test('classifies each zone by threshold', () {
      expect(FlowClassification.indexFor(500, rp), 0); // < 2yr  Normal
      expect(FlowClassification.indexFor(1500, rp), 1); // 2-5yr  Action
      expect(FlowClassification.indexFor(2500, rp), 2); // 5-10yr Moderate
      expect(FlowClassification.indexFor(3500, rp), 3); // 10-25yr Major
      expect(FlowClassification.indexFor(5000, rp), 4); // > 25yr Extreme
    });

    test('boundaries are lower-inclusive (>= threshold moves up)', () {
      expect(FlowClassification.indexFor(1000, rp), 1); // exactly 2yr -> Action
      expect(FlowClassification.indexFor(999.99, rp), 0);
      expect(FlowClassification.indexFor(4000, rp), 4); // exactly 25yr -> Extreme
    });

    test('returns -1 for null flow, null map, or incomplete thresholds', () {
      expect(FlowClassification.indexFor(null, rp), -1);
      expect(FlowClassification.indexFor(500, null), -1);
      expect(FlowClassification.indexFor(500, const {2: 1000.0, 5: 2000.0}), -1);
    });
  });

  group('category', () {
    test('names match the index', () {
      expect(FlowClassification.category(500, rp), 'Normal');
      expect(FlowClassification.category(1500, rp), 'Action');
      expect(FlowClassification.category(2500, rp), 'Moderate');
      expect(FlowClassification.category(3500, rp), 'Major');
      expect(FlowClassification.category(5000, rp), 'Extreme');
    });

    test('unknown when unclassifiable', () {
      expect(FlowClassification.category(null, rp), 'Unknown');
      expect(FlowClassification.category(500, null), 'Unknown');
    });

    test('kFloodCategories is the 5-zone ladder in order', () {
      expect(kFloodCategories,
          ['Normal', 'Action', 'Moderate', 'Major', 'Extreme']);
    });
  });
}
