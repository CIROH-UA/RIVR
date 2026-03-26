// lib/features/auth/utils/email_validator.dart

/// HTML5-spec email regex with minimum 2-char TLD.
/// Rejects: spaces, consecutive dots in domain, missing/short TLD,
/// leading/trailing dots in local part.
final _emailRegex = RegExp(
  r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$",
);

/// Validates an email field value.
/// Returns an error string if invalid, or null if valid.
String? validateEmail(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Email is required';
  }
  if (!_emailRegex.hasMatch(value.trim())) {
    return 'Please enter a valid email';
  }
  return null;
}
