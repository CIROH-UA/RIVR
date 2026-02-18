// lib/features/settings/pages/sponsors_page.dart
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:rivr/core/services/app_logger.dart';

class SponsorsPage extends StatelessWidget {
  const SponsorsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Our Sponsors',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: const Color(0xFF1976D2), // River blue theme
        elevation: 0,
        centerTitle: true,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1976D2), Color(0xFF42A5F5), Colors.white],
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

                // Header Section
                Container(
                  padding: const EdgeInsets.all(20),
                  margin: const EdgeInsets.only(bottom: 30),
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
                      Text(
                        'RIVR is made possible through the generous support and collaboration of these outstanding organizations.',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey[700],
                          height: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 15),
                      Icon(
                        Icons.handshake,
                        size: 40,
                        color: const Color(0xFF1976D2),
                      ),
                      const SizedBox(height: 15),
                      const Text(
                        'Proudly Supported By',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1976D2),
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),

                // Sponsors Logos Section
                Column(
                  children: [
                    // CIROH Logo (Top)
                    _buildSponsorCard(
                      'assets/images/sponsors/ciroh_logo.png',
                      'Cooperative Institute for Research to Operations in Hydrology',
                      url: 'https://ciroh.ua.edu/',
                    ),

                    const SizedBox(height: 25),

                    // BYU Logo
                    _buildSponsorCard(
                      'assets/images/sponsors/BYU MonogramWordmark_navy@2x.png',
                      'Brigham Young University\n Hydroinformatics Laboratory',
                      url: 'https://hydroinformatics.byu.edu/',
                    ),

                    const SizedBox(height: 25),

                    // University of Alabama Logo
                    _buildSponsorCard(
                      'assets/images/sponsors/University-of-Alabama-Logo.png',
                      'University of Alabama\nAlabama Water Insitute',
                      url: 'https://awi.ua.edu/',
                    ),

                    const SizedBox(height: 25),

                    // NOAA Logo
                    _buildSponsorCard(
                      'assets/images/sponsors/NOAA-logo.png',
                      'National Oceanic and Atmospheric Administration',
                      url: 'https://www.noaa.gov/',
                    ),

                    const SizedBox(height: 25),

                    // Office of Water Prediction Logo
                    _buildSponsorCard(
                      'assets/images/sponsors/Office_of_Water_Prediction_Logo.png',
                      'National Weather Service\nOffice of Water Prediction',
                      url: 'https://www.weather.gov/owp',
                    ),
                  ],
                ),

                const SizedBox(height: 40),

                // Footer Section
                Container(
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
                      Icon(
                        Icons.water,
                        size: 30,
                        color: const Color(0xFF1976D2),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Thank You',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF1976D2),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Together, we\'re advancing water prediction and management for communities everywhere.',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[600],
                          fontStyle: FontStyle.italic,
                          height: 1.4,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSponsorCard(
    String imagePath,
    String organizationName, {
    String? url, // Optional URL parameter
  }) {
    return GestureDetector(
      onTap: url != null ? () => _launchURL(url) : null,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(25),
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
          // Add subtle border when clickable
          border: url != null
              ? Border.all(color: Colors.blue.withValues(alpha: 0.1), width: 1)
              : null,
        ),
        child: Column(
          children: [
            // Logo Container
            Container(
              height: 100,
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(10),
              ),
              child: Image.asset(
                imagePath,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.image_not_supported,
                          size: 40,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'Logo',
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 15),

            // Organization Name with optional link indicator
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    organizationName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: url != null
                          ? const Color(0xFF1976D2) // Blue color for clickable
                          : const Color(0xFF424242),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                if (url != null) ...[
                  const SizedBox(width: 5),
                  Icon(
                    Icons.open_in_new,
                    size: 16,
                    color: const Color(0xFF1976D2),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Helper function to launch URLs
  Future<void> _launchURL(String url) async {
    try {
      final Uri uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        AppLogger.warning('SponsorsPage', 'Could not launch $url');
      }
    } catch (e) {
      AppLogger.error('SponsorsPage', 'Error launching URL: $url', e);
    }
  }
}
