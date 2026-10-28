import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/widgets/async_value_view.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../doctors_providers.dart';
import '../doctors_routes.dart';
import 'doctor_texts.dart';

class DoctorDetailScreen extends ConsumerWidget {
  const DoctorDetailScreen({
    super.key,
    required this.doctorId,
    this.canBook = false,
  });

  final int doctorId;

  /// Patients get the "Book" button.
  final bool canBook;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final doctor = ref.watch(doctorProvider(doctorId));
    return Scaffold(
      appBar: AppBar(title: Text(l10n.doctorsDetailTitle)),
      body: AsyncValueView(
        value: doctor,
        onRetry: () => ref.invalidate(doctorProvider(doctorId)),
        data:
            (d) => ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  d.fullName,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  specialtyName(context, d.specialty),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(l10n.doctorsConsultationMinutes(d.consultationMinutes)),
                const SizedBox(height: 24),
                Text(d.bio.isEmpty ? l10n.doctorsBioEmpty : d.bio),
                if (canBook) ...[
                  const SizedBox(height: 32),
                  // Opens the booking flow of the appointments feature.
                  FilledButton(
                    onPressed: () => context.push(bookingRoute(d.id)),
                    child: Text(l10n.doctorsBookButton),
                  ),
                ],
              ],
            ),
      ),
    );
  }
}
