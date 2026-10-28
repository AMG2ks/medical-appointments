import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/l10n/error_text.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/widgets/async_value_view.dart';
import 'package:medical_appointments/l10n/gen/app_localizations.dart';
import '../../data/models/doctor.dart';
import '../doctors_providers.dart';
import 'doctor_texts.dart';

const minConsultationMinutes = 5;
const maxConsultationMinutes = 240;

/// Client-side check of the consultation duration (the server validates again).
String? validateMinutes(AppLocalizations l10n, String? value) {
  final minutes = int.tryParse((value ?? '').trim());
  if (minutes == null ||
      minutes < minConsultationMinutes ||
      minutes > maxConsultationMinutes) {
    return l10n.validationMinutes(
      minConsultationMinutes,
      maxConsultationMinutes,
    );
  }
  return null;
}

/// The doctor's professional profile: specialty, biography, consultation duration.
class DoctorProfileScreen extends ConsumerWidget {
  const DoctorProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.doctorsProfileTitle)),
      body: AsyncValueView(
        value: ref.watch(myDoctorProfileProvider),
        onRetry: () => ref.invalidate(myDoctorProfileProvider),
        data: (doctor) => _ProfileForm(doctor: doctor),
      ),
    );
  }
}

class _ProfileForm extends ConsumerStatefulWidget {
  const _ProfileForm({required this.doctor});

  final Doctor doctor;

  @override
  ConsumerState<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends ConsumerState<_ProfileForm> {
  static const _inlineFields = {'specialty_id', 'bio', 'consultation_minutes'};

  final _formKey = GlobalKey<FormState>();
  late final _bio = TextEditingController(text: widget.doctor.bio);
  late final _minutes = TextEditingController(
    text: '${widget.doctor.consultationMinutes}',
  );
  late int _specialtyId = widget.doctor.specialty.id;
  bool _busy = false;
  ApiException? _error;

  @override
  void dispose() {
    _bio.dispose();
    _minutes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(myDoctorProfileProvider.notifier)
          .save(
            specialtyId: _specialtyId,
            bio: _bio.text.trim(),
            consultationMinutes: int.parse(_minutes.text.trim()),
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).doctorsProfileSaved),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      showApiError(context, e, inlineFields: _inlineFields);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final specialties = ref.watch(specialtiesProvider).value ?? const [];
    // The current specialty is always offered, even if the list is still loading.
    final options = [
      if (!specialties.any((s) => s.id == widget.doctor.specialty.id))
        widget.doctor.specialty,
      ...specialties,
    ];
    return SafeArea(
      child: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            DropdownButtonFormField<int>(
              value: _specialtyId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.doctorsSpecialtyLabel,
                errorText: fieldError(context, _error, 'specialty_id'),
              ),
              items: [
                for (final s in options)
                  DropdownMenuItem(
                    value: s.id,
                    child: Text(specialtyName(context, s)),
                  ),
              ],
              onChanged:
                  (id) => setState(() => _specialtyId = id ?? _specialtyId),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _minutes,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: l10n.doctorsMinutesLabel,
                errorText: fieldError(context, _error, 'consultation_minutes'),
              ),
              validator: (v) => validateMinutes(l10n, v),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _bio,
              minLines: 4,
              maxLines: 8,
              decoration: InputDecoration(
                labelText: l10n.doctorsBioLabel,
                alignLabelWithHint: true,
                errorText: fieldError(context, _error, 'bio'),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(l10n.commonSave),
            ),
          ],
        ),
      ),
    );
  }
}
