/// Route of the booking flow for a doctor.
///
/// M3 HOOK: the "Book" button of the doctor detail opens this route. Today it shows
/// `BookingPlaceholderScreen`; M3 replaces the builder in `app/router.dart` with its flow.
String bookingRoute(int doctorId) => '/patient/doctors/$doctorId/book';
