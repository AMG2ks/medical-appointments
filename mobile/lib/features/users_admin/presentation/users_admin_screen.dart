import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/error_text.dart';
import '../../../core/widgets/async_value_view.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../auth/data/models/user.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../auth/presentation/screens/profile_screen.dart' show roleLabel;
import 'users_admin_controller.dart';

class UsersAdminScreen extends ConsumerStatefulWidget {
  const UsersAdminScreen({super.key});

  @override
  ConsumerState<UsersAdminScreen> createState() => _UsersAdminScreenState();
}

class _UsersAdminScreenState extends ConsumerState<UsersAdminScreen> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _toggle(User user, bool value) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(
              value ? l10n.usersActivateTitle : l10n.usersDeactivateTitle,
            ),
            content: Text(
              value
                  ? l10n.usersActivateMessage(user.email)
                  : [
                    l10n.usersDeactivateMessage(user.email),
                    // Patients and doctors: their future appointments are cancelled.
                    if (user.role != UserRole.admin)
                      l10n.usersDeactivateAppointmentsWarning,
                  ].join('\n\n'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.commonCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.commonConfirm),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(usersAdminControllerProvider.notifier)
          .setActive(user, value);
    } catch (e) {
      if (mounted) showApiError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(usersAdminControllerProvider);
    final controller = ref.read(usersAdminControllerProvider.notifier);
    final me = ref.watch(currentUserProvider);
    final selectedRole = state.value?.role;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.usersTitle)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: l10n.usersSearchHint,
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
                  label: Text(l10n.usersFilterAll),
                  selected: selectedRole == null,
                  onSelected: (_) => controller.setRole(null),
                ),
                for (final role in UserRole.values)
                  ChoiceChip(
                    label: Text(roleLabel(l10n, role)),
                    selected: selectedRole == role,
                    onSelected: (_) => controller.setRole(role),
                  ),
              ],
            ),
          ),
          Expanded(
            child: AsyncValueView(
              value: state,
              onRetry: () => ref.invalidate(usersAdminControllerProvider),
              isEmpty: (s) => s.users.isEmpty,
              emptyText: l10n.usersEmpty,
              data:
                  (s) => ListView.builder(
                    itemCount: s.users.length + (s.hasNext ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == s.users.length) {
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
                      final user = s.users[index];
                      return SwitchListTile(
                        title: Text(
                          user.fullName.isEmpty ? user.email : user.fullName,
                        ),
                        subtitle: Text(
                          '${user.email}\n${roleLabel(l10n, user.role)}',
                        ),
                        isThreeLine: true,
                        value: user.isActive,
                        onChanged:
                            user.id == me?.id ? null : (v) => _toggle(user, v),
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
