import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/error_text.dart';
import '../../../../core/widgets/async_value_view.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../data/models/appointment.dart';
import '../appointments_providers.dart';
import '../widgets/appointment_tile.dart';

/// One tab of [AppointmentsTabsScreen].
class AppointmentsTab {
  const AppointmentsTab({
    required this.label,
    required this.query,
    required this.emptyText,
  });

  final String label;
  final AppointmentsQuery query;
  final String emptyText;
}

/// Tabs of appointment lists: the patient's "my appointments" (upcoming / past) and the
/// doctor's agenda (today / upcoming / past). Every list reloads on pull-to-refresh and
/// shows loading, error with retry and empty states.
class AppointmentsTabsScreen extends StatelessWidget {
  const AppointmentsTabsScreen({
    super.key,
    required this.title,
    required this.tabs,
    required this.showPatient,
    required this.detailPath,
  });

  final String title;
  final List<AppointmentsTab> tabs;

  /// Doctor agenda: rows show the patient instead of the doctor.
  final bool showPatient;
  final String Function(int appointmentId) detailPath;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          bottom: TabBar(tabs: [for (final tab in tabs) Tab(text: tab.label)]),
        ),
        // Not a TabBarView: its PageView viewport asserted ("relayout boundary") when the
        // language changed while this screen sat hidden under a detail page or in another
        // tab. The tab bar drives a plain switch instead (tapping a tab; no swipe).
        body: Builder(
          builder: (context) {
            final controller = DefaultTabController.of(context);
            return ListenableBuilder(
              listenable: controller,
              builder:
                  (context, _) => AppointmentsList(
                    key: ValueKey(controller.index),
                    tab: tabs[controller.index],
                    showPatient: showPatient,
                    detailPath: detailPath,
                  ),
            );
          },
        ),
      ),
    );
  }
}

class AppointmentsList extends ConsumerWidget {
  const AppointmentsList({
    super.key,
    required this.tab,
    required this.showPatient,
    required this.detailPath,
  });

  final AppointmentsTab tab;
  final bool showPatient;
  final String Function(int appointmentId) detailPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final provider = appointmentsListProvider(tab.query);
    return AsyncValueView(
      value: ref.watch(provider),
      onRetry: () => ref.invalidate(provider),
      isEmpty: (state) => state.items.isEmpty,
      emptyText: tab.emptyText,
      onRefresh: () => ref.refresh(provider.future),
      data:
          (state) => RefreshIndicator(
            onRefresh: () => ref.refresh(provider.future),
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: state.items.length + (state.hasNext ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == state.items.length) {
                  return TextButton(
                    onPressed: () async {
                      try {
                        await ref.read(provider.notifier).loadMore();
                      } catch (e) {
                        if (context.mounted) showApiError(context, e);
                      }
                    },
                    child: Text(l10n.commonLoadMore),
                  );
                }
                final appointment = state.items[index];
                return AppointmentTile(
                  appointment: appointment,
                  showPatient: showPatient,
                  onTap: () => context.push(detailPath(appointment.id)),
                );
              },
            ),
          ),
    );
  }
}

/// Patient tab: upcoming / past.
class MyAppointmentsScreen extends StatelessWidget {
  const MyAppointmentsScreen({super.key, required this.detailPath});

  final String Function(int appointmentId) detailPath;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppointmentsTabsScreen(
      title: l10n.apptMyTitle,
      showPatient: false,
      detailPath: detailPath,
      tabs: [
        AppointmentsTab(
          label: l10n.apptTabUpcoming,
          query: (scope: AppointmentScope.upcoming, day: null),
          emptyText: l10n.apptEmptyUpcoming,
        ),
        AppointmentsTab(
          label: l10n.apptTabPast,
          query: (scope: AppointmentScope.past, day: null),
          emptyText: l10n.apptEmptyPast,
        ),
      ],
    );
  }
}

/// Doctor home tab: today / upcoming / past.
class DoctorAgendaScreen extends StatelessWidget {
  const DoctorAgendaScreen({super.key, required this.detailPath});

  final String Function(int appointmentId) detailPath;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppointmentsTabsScreen(
      title: l10n.apptAgendaTitle,
      showPatient: true,
      detailPath: detailPath,
      tabs: [
        AppointmentsTab(
          label: l10n.apptTabToday,
          query: (scope: null, day: dayOf(DateTime.now())),
          emptyText: l10n.apptEmptyToday,
        ),
        AppointmentsTab(
          label: l10n.apptTabUpcoming,
          query: (scope: AppointmentScope.upcoming, day: null),
          emptyText: l10n.apptEmptyUpcoming,
        ),
        AppointmentsTab(
          label: l10n.apptTabPast,
          query: (scope: AppointmentScope.past, day: null),
          emptyText: l10n.apptEmptyPast,
        ),
      ],
    );
  }
}
