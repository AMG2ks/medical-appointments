import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/l10n/error_text.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/widgets/async_value_view.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../../auth/presentation/screens/form_validators.dart';
import '../../data/models/specialty.dart';
import '../doctors_providers.dart';
import 'doctor_texts.dart';

/// Admin: list, add, rename and delete specialties.
class SpecialtiesAdminScreen extends ConsumerWidget {
  const SpecialtiesAdminScreen({super.key});

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    Specialty item,
  ) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(l10n.specialtiesDeleteTitle),
            content: Text(specialtyName(context, item)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.commonCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.commonDelete),
              ),
            ],
          ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(specialtiesProvider.notifier).remove(item.id);
    } catch (e) {
      if (context.mounted) showApiError(context, e); // e.g. specialty_in_use
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final controller = ref.read(specialtiesProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.specialtiesTitle)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed:
            () => showDialog<void>(
              context: context,
              builder: (_) => SpecialtyDialog(onSave: controller.create),
            ),
        icon: const Icon(Icons.add),
        label: Text(l10n.specialtiesAdd),
      ),
      body: AsyncValueView(
        value: ref.watch(specialtiesProvider),
        onRetry: () => ref.invalidate(specialtiesProvider),
        isEmpty: (items) => items.isEmpty,
        emptyText: l10n.specialtiesEmpty,
        data:
            (items) => ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return ListTile(
                  title: Text(item.nameFr),
                  subtitle: Text(item.nameEn),
                  onTap:
                      () => showDialog<void>(
                        context: context,
                        builder:
                            (_) => SpecialtyDialog(
                              initial: item,
                              onSave:
                                  (draft) => controller.edit(item.id, draft),
                            ),
                      ),
                  trailing: IconButton(
                    tooltip: l10n.commonDelete,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(context, ref, item),
                  ),
                );
              },
            ),
      ),
    );
  }
}

class SpecialtyDialog extends StatefulWidget {
  const SpecialtyDialog({super.key, this.initial, required this.onSave});

  final Specialty? initial;
  final Future<void> Function(Specialty draft) onSave;

  @override
  State<SpecialtyDialog> createState() => _SpecialtyDialogState();
}

class _SpecialtyDialogState extends State<SpecialtyDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _nameFr = TextEditingController(text: widget.initial?.nameFr);
  late final _nameEn = TextEditingController(text: widget.initial?.nameEn);
  bool _busy = false;
  ApiException? _error;

  @override
  void dispose() {
    _nameFr.dispose();
    _nameEn.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(
        Specialty(
          id: widget.initial?.id ?? 0,
          nameFr: _nameFr.text.trim(),
          nameEn: _nameEn.text.trim(),
        ),
      );
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _busy = false;
      });
      showApiError(context, e, inlineFields: const {'name_fr', 'name_en'});
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(
        widget.initial == null
            ? l10n.specialtiesAdd
            : l10n.specialtiesEditTitle,
      ),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameFr,
                decoration: InputDecoration(
                  labelText: l10n.specialtiesNameFrLabel,
                  errorText: fieldError(context, _error, 'name_fr'),
                ),
                validator: (v) => validateRequired(l10n, v),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameEn,
                decoration: InputDecoration(
                  labelText: l10n.specialtiesNameEnLabel,
                  errorText: fieldError(context, _error, 'name_en'),
                ),
                validator: (v) => validateRequired(l10n, v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(l10n.commonSave),
        ),
      ],
    );
  }
}
