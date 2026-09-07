// lib/ui/2_presentation/shared/widgets/app_version_label.dart

import 'package:flutter/cupertino.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// Formats a marketing version and build number the way Apple writes them.
///
/// `pubspec.yaml` carries `<year>.<major>.<minor>+<commit count>`, and
/// `package_info_plus` hands those back already split — `version` is the part
/// before the `+`, `buildNumber` the part after. This only joins them.
///
/// Kept separate from the widget so the formatting is unit-testable without a
/// platform channel: the plugin reads the real bundle, which a widget test has
/// to fake.
String formatAppVersion(String version, String buildNumber) {
  final v = version.trim();
  final b = buildNumber.trim();
  if (v.isEmpty) return '';
  if (b.isEmpty) return 'RIVR $v';
  return 'RIVR $v ($b)';
}

/// A dimmed one-line version stamp, e.g. `RIVR 2026.2.1 (786)`.
///
/// Reads the compiled bundle rather than any constant in the source, so it
/// tracks whatever `make version` stamped and cannot be forgotten in a release.
/// The value is what a tester or App Review reads back when reporting a bug,
/// which is why it names the build number and not just the version.
///
/// Renders nothing at all — no placeholder, no reserved space — until the
/// platform answers, and nothing if it fails. A version stamp is not worth a
/// layout jump or an error state on the Account page.
class AppVersionLabel extends StatefulWidget {
  const AppVersionLabel({super.key});

  @override
  State<AppVersionLabel> createState() => _AppVersionLabelState();
}

class _AppVersionLabelState extends State<AppVersionLabel> {
  String _label = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _label = formatAppVersion(info.version, info.buildNumber);
      });
    } catch (e) {
      // Nothing to recover: the label simply stays hidden.
      AppLogger.warning('AppVersionLabel', 'Could not read package info: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_label.isEmpty) return const SizedBox.shrink();
    return Semantics(
      label: 'App version $_label',
      child: Text(
        _label,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 13,
          color: CupertinoColors.tertiaryLabel,
        ),
      ),
    );
  }
}
