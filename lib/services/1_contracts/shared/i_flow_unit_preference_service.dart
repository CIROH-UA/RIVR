// lib/services/1_contracts/shared/i_flow_unit_preference_service.dart

/// Interface for flow unit preference management and conversions
abstract class IFlowUnitPreferenceService {
  String get currentFlowUnit;
  void setFlowUnit(String unit);
  String normalizeUnit(String unit);
  double convertFlow(double value, String fromUnit, String toUnit);
  double convertToPreferredUnit(double value, String fromUnit);
  double convertFromPreferredUnit(double value, String toUnit);
  String getDisplayUnit();
  bool get isCFS;
  bool get isCMS;
  void resetToDefault();
}
