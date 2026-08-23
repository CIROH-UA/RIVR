// lib/ui/2_presentation/features/forecast/load_view_state.dart

/// Which view a loading surface should render.
///
/// Extracted as a pure decision because the alternative — two independent
/// booleans checked in the right order — is a defect this project has already
/// shipped twice. If `_loading` is checked before `_error`, a load that failed
/// without clearing the flag renders a spinner forever and the failure is
/// invisible; review found that on the forecast page and the Weekly Outlook.
///
/// Ordering it correctly fixes the symptom but leaves the trap: the both-set
/// state is not reachable through the widget's own lifecycle, so no widget test
/// can drive it, and the guard that "protects" it passes either way. Deciding
/// here makes the rule directly testable with both inputs set, and makes the
/// precedence a property of one function rather than of statement order in
/// three separate build methods.
enum LoadViewState {
  /// A failure the user must be told about, with a way out.
  error,

  /// Work in progress.
  loading,

  /// Real content.
  content,
}

/// Error always wins. A failure must never be maskable by a flag that was left
/// set — that is the whole point of this function existing.
LoadViewState loadViewStateFor({
  required bool hasError,
  required bool isLoading,
}) {
  if (hasError) return LoadViewState.error;
  if (isLoading) return LoadViewState.loading;
  return LoadViewState.content;
}
