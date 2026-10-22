/// A page of a paginated list: `{count, next, previous, results}`.
class Paginated<T> {
  const Paginated({
    required this.count,
    required this.hasNext,
    required this.results,
  });

  final int count;
  final bool hasNext;
  final List<T> results;

  factory Paginated.fromJson(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    return Paginated(
      count: json['count'] as int,
      hasNext: json['next'] != null,
      results: [
        for (final item in json['results'] as List<dynamic>)
          fromJson(item as Map<String, dynamic>),
      ],
    );
  }
}
