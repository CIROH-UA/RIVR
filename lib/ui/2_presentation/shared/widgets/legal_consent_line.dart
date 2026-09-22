// lib/ui/2_presentation/shared/widgets/legal_consent_line.dart

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:url_launcher/url_launcher.dart';

/// "By continuing, you agree to our Terms of Service and Privacy Policy."
///
/// One widget, two places: the last onboarding screen (every person passes
/// it — ADR 0014 UX-5, since a guest never sees the login page) and the
/// login/register pages. The links go to the RIVR sections of HydroMap's
/// documents; the login page used to send both to the homepage.
class LegalConsentLine extends StatelessWidget {
  const LegalConsentLine({super.key});

  static final Uri termsUrl =
      Uri.parse('https://hydromap.com/terms-of-service/?product=rivr');
  static final Uri privacyUrl =
      Uri.parse('https://hydromap.com/privacy-policy/?product=rivr');

  @override
  Widget build(BuildContext context) {
    final primaryColor = CupertinoTheme.of(context).primaryColor;
    return Text.rich(
      TextSpan(
        style: const TextStyle(
          fontSize: 12,
          color: CupertinoColors.systemGrey,
        ),
        children: [
          const TextSpan(text: 'By continuing, you agree to our '),
          TextSpan(
            text: 'Terms of Service',
            style: TextStyle(color: primaryColor),
            recognizer: TapGestureRecognizer()
              ..onTap = () =>
                  launchUrl(termsUrl, mode: LaunchMode.externalApplication),
          ),
          const TextSpan(text: ' and '),
          TextSpan(
            text: 'Privacy Policy',
            style: TextStyle(color: primaryColor),
            recognizer: TapGestureRecognizer()
              ..onTap = () =>
                  launchUrl(privacyUrl, mode: LaunchMode.externalApplication),
          ),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
