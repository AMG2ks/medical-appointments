import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../l10n/error_text.dart';

/// Loading / error with retry / empty / data, for every screen that loads something.
class AsyncValueView<T> extends StatelessWidget {
  const AsyncValueView({
    super.key,
    required this.value,
    required this.data,
    this.onRetry,
    this.isEmpty,
    this.emptyText,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback? onRetry;

  /// When it returns true the empty message is shown instead of [data].
  final bool Function(T data)? isEmpty;
  final String? emptyText;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return value.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error:
          (error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(errorText(context, error), textAlign: TextAlign.center),
                  if (onRetry != null) ...[
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: onRetry,
                      child: Text(l10n.commonRetry),
                    ),
                  ],
                ],
              ),
            ),
          ),
      data: (loaded) {
        if (isEmpty?.call(loaded) ?? false) {
          return Center(child: Text(emptyText ?? l10n.commonEmpty));
        }
        return data(loaded);
      },
    );
  }
}
