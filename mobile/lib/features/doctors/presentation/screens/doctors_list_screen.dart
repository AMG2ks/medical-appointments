import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/l10n/error_text.dart';
import '../../../../core/widgets/async_value_view.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../doctors_providers.dart';
import 'doctor_texts.dart';

/// Doctors with a specialty filter and a name search. Used by the patient (Home tab) and
/// the admin (Doctors tab, with a button to create one).
class DoctorsListScreen extends ConsumerStatefulWidget {
  const DoctorsListScreen({
    super.key,
    required this.detailPath,
    this.createPath,
  });

  /// Detail route of a doctor: `detailPath(doctorId)`.
  final String Function(int doctorId) detailPath;

  /// When set, an "add doctor" button opens this route (admin).
  final String? createPath;

  @override
  ConsumerState<DoctorsListScreen> createState() => _DoctorsListScreenState();
}

class _DoctorsListScreenState extends ConsumerState<DoctorsListScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(doctorsListProvider);
    final controller = ref.read(doctorsListProvider.notifier);
    // The filter chips are optional: while the specialties load or fail, the list still works.
    final specialties = ref.watch(specialtiesProvider).value ?? const [];
    final selected = state.value?.specialtyId;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.doctorsListTitle)),
      floatingActionButton:
          widget.createPath == null
              ? null
              : FloatingActionButton.extended(
                onPressed: () => context.push(widget.createPath!),
                icon: const Icon(Icons.add),
                label: Text(l10n.doctorsAddButton),
              ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: l10n.doctorsSearchHint,
                prefixIcon: const Icon(Icons.search),
              ),
              onSubmitted: controller.setSearch,
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text(l10n.doctorsFilterAll),
                  selected: selected == null,
                  onSelected: (_) => controller.setSpecialty(null),
                ),
                for (final s in specialties)
                  ChoiceChip(
                    label: Text(specialtyName(context, s)),
                    selected: selected == s.id,
                    onSelected: (_) => controller.setSpecialty(s.id),
                  ),
              ],
            ),
          ),
          Expanded(
            child: AsyncValueView(
              value: state,
              onRetry: () => ref.invalidate(doctorsListProvider),
              isEmpty: (s) => s.doctors.isEmpty,
              emptyText: l10n.doctorsEmpty,
              data:
                  (s) => ListView.builder(
                    itemCount: s.doctors.length + (s.hasNext ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == s.doctors.length) {
                        return TextButton(
                          onPressed: () async {
                            try {
                              await controller.loadMore();
                            } catch (e) {
                              if (context.mounted) showApiError(context, e);
                            }
                          },
                          child: Text(l10n.commonLoadMore),
                        );
                      }
                      final doctor = s.doctors[index];
                      return ListTile(
                        leading: CircleAvatar(
                          child: Text(
                            doctor.lastName.isEmpty
                                ? '?'
                                : doctor.lastName[0].toUpperCase(),
                          ),
                        ),
                        title: Text(doctor.fullName),
                        subtitle: Text(
                          specialtyName(context, doctor.specialty),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push(widget.detailPath(doctor.id)),
                      );
                    },
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
