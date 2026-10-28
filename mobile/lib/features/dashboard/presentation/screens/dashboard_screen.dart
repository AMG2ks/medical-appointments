import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';

import '../../../../core/widgets/async_value_view.dart';
import '../../../appointments/presentation/screens/appointment_texts.dart';
import '../../data/models/dashboard_stats.dart';
import '../dashboard_providers.dart';

/// Admin landing screen: counts of patients, doctors and appointments.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    Future<void> reload() async {
      ref.invalidate(dashboardStatsProvider);
      await ref.read(dashboardStatsProvider.future);
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.dashTitle)),
      body: AsyncValueView(
        value: ref.watch(dashboardStatsProvider),
        onRetry: () => ref.invalidate(dashboardStatsProvider),
        data:
            (stats) => RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  _UsersCard(
                    title: l10n.dashPatients,
                    icon: Icons.people_outline,
                    counts: stats.patients,
                  ),
                  _UsersCard(
                    title: l10n.dashDoctors,
                    icon: Icons.medical_services_outlined,
                    counts: stats.doctors,
                  ),
                  _AppointmentsCard(stats: stats),
                ],
              ),
            ),
      ),
    );
  }
}

class _UsersCard extends StatelessWidget {
  const _UsersCard({
    required this.title,
    required this.icon,
    required this.counts,
  });

  final String title;
  final IconData icon;
  final UserCounts counts;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(l10n.dashActiveOfTotal(counts.active, counts.total)),
        trailing: Text(
          '${counts.total}',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      ),
    );
  }
}

class _AppointmentsCard extends StatelessWidget {
  const _AppointmentsCard({required this.stats});

  final DashboardStats stats;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.dashAppointments, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                _Figure(label: l10n.dashToday, value: stats.appointmentsToday),
                _Figure(
                  label: l10n.dashThisWeek,
                  value: stats.appointmentsThisWeek,
                ),
                _Figure(label: l10n.dashTotal, value: stats.appointmentsTotal),
              ],
            ),
            const Divider(height: 32),
            Text(l10n.dashByStatus, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final entry in stats.byStatus.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(child: Text(statusText(l10n, entry.key))),
                    Text('${entry.value}'),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Text('$value', style: theme.textTheme.headlineMedium),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
