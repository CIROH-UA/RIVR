import 'package:flutter/cupertino.dart';

/// The soft ask, shown after a user adds their first favourite.
///
/// This is **our** UI, not the system prompt, and that distinction is the whole
/// point. iOS grants exactly one notification prompt per install and RIVR has
/// no provisional fallback (ADR 0009), so the real prompt must only ever be
/// spent on someone who has already said yes here. "Not now" costs nothing and
/// leaves the prompt available; only "Enable" spends it.
///
/// The copy names the river the user just saved. "Get alerts for White River?"
/// is a concrete promise about something they just chose; "Enable
/// Notifications" is a request for a permission. The first is answerable.
///
/// One grant covers both notification types, so the card says so — offering
/// only flood alerts and then also sending a weekly digest would be a
/// bait-and-switch.
class NotificationPromptBanner extends StatelessWidget {
  const NotificationPromptBanner({
    super.key,
    required this.riverName,
    required this.onEnable,
    required this.onDismiss,
  });

  /// The favourite that prompted this, named in the copy.
  final String riverName;

  /// Spends the OS prompt. Only reached from an explicit tap on Enable.
  final VoidCallback onEnable;

  /// "Not now" — must not touch the OS.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final blue = CupertinoColors.systemBlue.resolveFrom(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: blue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: blue.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(CupertinoIcons.bell_fill,
                  color: blue, size: 20, semanticLabel: 'Notifications'),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Get alerts for $riverName?',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.label.resolveFrom(context),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "We'll tell you when it's forecast to flood, and send a "
                      'calm weekly summary each Friday.',
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        color:
                            CupertinoColors.secondaryLabel.resolveFrom(context),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              CupertinoButton(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                minimumSize: Size.zero,
                onPressed: onDismiss,
                child: Text(
                  'Not now',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              CupertinoButton(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                color: blue,
                borderRadius: BorderRadius.circular(8),
                minimumSize: Size.zero,
                onPressed: onEnable,
                child: const Text(
                  'Enable',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: CupertinoColors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
