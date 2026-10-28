/// A medical specialty. Names are data, stored in both languages by the backend.
class Specialty {
  const Specialty({
    required this.id,
    required this.nameFr,
    required this.nameEn,
  });

  final int id;
  final String nameFr;
  final String nameEn;

  /// The name for [languageCode] (`fr` or `en`); French is the app's fallback language.
  String nameFor(String languageCode) => languageCode == 'en' ? nameEn : nameFr;

  factory Specialty.fromJson(Map<String, dynamic> json) => Specialty(
    id: json['id'] as int,
    nameFr: json['name_fr'] as String,
    nameEn: json['name_en'] as String,
  );

  Map<String, dynamic> toJson() => {'name_fr': nameFr, 'name_en': nameEn};
}
