// lib/ui/2_presentation/features/settings/pages/about_page.dart
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:rivr/services/4_infrastructure/logging/app_logger.dart';

/// Static "About RIVR" page — version, technology stack, data sources, credits.
///
/// Styled to match [SponsorsPage] so the two pages read as siblings.
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static const _riverBlue = Color(0xFF1976D2);

  /// Populated from the platform bundle so the version never drifts from
  /// pubspec.yaml. Null until the async read completes.
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() => _packageInfo = info);
      }
    } catch (e) {
      AppLogger.error('AboutPage', 'Could not read package info', e);
    }
  }

  String get _versionText {
    final info = _packageInfo;
    if (info == null) return ' ';
    return 'Version ${info.version} (build ${info.buildNumber})';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'About RIVR',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: _riverBlue,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_riverBlue, Color(0xFF42A5F5), Colors.white],
            stops: [0.0, 0.3, 1.0],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 20),

                // Logo + version header
                _buildHeader(),

                const SizedBox(height: 30),

                _buildBuiltUsingCard(),

                const SizedBox(height: 20),

                _buildDataSourcesCard(),

                const SizedBox(height: 20),

                _buildCreditsCard(),

                const SizedBox(height: 20),

                _buildFooter(),

                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Sections
  // ---------------------------------------------------------------------------

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          width: 110,
          height: 110,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            // White tile: the logo is itself blue, so it needs separating from
            // the blue gradient behind it.
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 15,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Image.asset(
              'assets/images/rivr_logo.png',
              fit: BoxFit.contain,
              semanticLabel: 'RIVR logo',
              errorBuilder: (context, error, stackTrace) => Container(
                color: Colors.white,
                child: const Icon(Icons.water, size: 50, color: _riverBlue),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'RIVR',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            letterSpacing: 4,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _versionText,
          style: TextStyle(
            fontSize: 14,
            color: Colors.white.withValues(alpha: 0.9),
          ),
        ),
      ],
    );
  }

  Widget _buildBuiltUsingCard() {
    return _buildCard(
      icon: Icons.layers,
      title: 'Built using',
      child: Column(
        children: const [
          _StackRow(label: 'Framework', value: 'Flutter and Dart'),
          _StackRow(label: 'Maps', value: 'Mapbox'),
          _StackRow(label: 'Charts', value: 'Syncfusion Flutter Charts'),
          _StackRow(
            label: 'Accounts and sync',
            value: 'Firebase Auth, Firestore, Cloud Messaging',
          ),
          _StackRow(
            label: 'Backend services',
            value: 'Firebase Cloud Functions on Google Cloud',
          ),
          _StackRow(label: 'Design', value: 'Apple Cupertino interface', last: true),
        ],
      ),
    );
  }

  Widget _buildDataSourcesCard() {
    return _buildCard(
      icon: Icons.storage,
      title: 'Data sources',
      child: Column(
        children: [
          _buildLinkRow(
            'NOAA National Water Model',
            'Flow forecasts for the continental United States',
            'https://water.noaa.gov/',
          ),
          _buildLinkRow(
            'NWM return periods (CIROH)',
            'Flood thresholds used for risk categories',
            'https://ciroh.ua.edu/',
          ),
          _buildLinkRow(
            'GEOGLOWS',
            'Global streamflow forecasts outside the United States',
            'https://geoglows.ecmwf.int/',
          ),
          _buildLinkRow(
            'Mapbox',
            'Basemaps, vector tiles, and geocoding',
            'https://www.mapbox.com/',
            last: true,
          ),
        ],
      ),
    );
  }

  Widget _buildCreditsCard() {
    return _buildCard(
      icon: Icons.people,
      title: 'Credits',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          _CreditRow(
            initials: 'DA',
            name: 'Dr. Dan Ames',
            role:
                'Project lead — concept, design, and funding; ongoing development. '
                'Brigham Young University Hydroinformatics Laboratory and HydroMap LLC.',
          ),
          _CreditRow(
            initials: 'JG',
            name: 'Jerson Garcia',
            role:
                'Lead developer — architecture, forecasting and mapping systems, '
                'and the current interface.',
          ),
          _CreditRow(
            initials: 'TT',
            name: 'Travis Tyler',
            role: 'Original proof of concept for the mobile app.',
            last: true,
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          const Icon(Icons.water, size: 30, color: _riverBlue),
          const SizedBox(height: 10),
          Text(
            'RIVR provides informational data to support your decisions. '
            'It is not an official flood warning. Always consult local '
            'authorities before acting on river conditions.',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[600],
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            'Released under the MIT License',
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[500],
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Shared building blocks
  // ---------------------------------------------------------------------------

  /// White rounded card with an icon + title header, matching SponsorsPage.
  Widget _buildCard({
    required IconData icon,
    required String title,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 15,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: _riverBlue),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _riverBlue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _buildLinkRow(
    String title,
    String subtitle,
    String url, {
    bool last = false,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _launchURL(url),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: last
            ? null
            : BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: Colors.grey[200]!, width: 1),
                ),
              ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: _riverBlue,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey[600],
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.open_in_new, size: 16, color: _riverBlue),
          ],
        ),
      ),
    );
  }

  Future<void> _launchURL(String url) async {
    try {
      final Uri uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        AppLogger.warning('AboutPage', 'Could not launch $url');
      }
    } catch (e) {
      AppLogger.error('AboutPage', 'Error launching URL: $url', e);
    }
  }
}

/// One "Label — value" row in the Built using card.
class _StackRow extends StatelessWidget {
  const _StackRow({
    required this.label,
    required this.value,
    this.last = false,
  });

  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: last
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Colors.grey[200]!, width: 1),
              ),
            ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey[600],
                height: 1.3,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFF424242),
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One person in the Credits card.
class _CreditRow extends StatelessWidget {
  const _CreditRow({
    required this.initials,
    required this.name,
    required this.role,
    this.last = false,
  });

  final String initials;
  final String name;
  final String role;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: last
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Colors.grey[200]!, width: 1),
              ),
            ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: Color(0xFFE3F2FD),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              initials,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF0D47A1),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF212121),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  role,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
