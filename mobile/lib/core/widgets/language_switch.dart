import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../config/constants.dart';
import '../l10n/error_text.dart';
import '../l10n/locale_controller.dart';

/// FR | EN segmented control. Logged out it only changes the device setting; logged in
/// it is also saved on the account (and reverted with an error if that fails).
class LanguageSwitch extends ConsumerWidget {
  const LanguageSwitch({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final current = ref.watch(localeControllerProvider).languageCode;
    return SegmentedButton<String>(
      showSelectedIcon: false,
      segments: [
        for (final code in supportedLanguageCodes)
          ButtonSegment(
            value: code,
            label: Text(code == 'fr' ? l10n.languageFr : l10n.languageEn),
          ),
      ],
      selected: {current},
      onSelectionChanged: (selection) async {
        try {
          await ref
              .read(localeControllerProvider.notifier)
              .setLanguage(selection.first);
        } catch (e) {
          if (context.mounted) showApiError(context, e);
        }
      },
    );
  }
}
