/// Route of the booking flow for a doctor (`BookingScreen` of the appointments feature,
/// mounted in `app/router.dart`). The "Book" button of the doctor detail opens it.
String bookingRoute(int doctorId) => '/patient/doctors/$doctorId/book';
