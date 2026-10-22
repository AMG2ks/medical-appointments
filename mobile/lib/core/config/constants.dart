/// Single place for client-side limits and storage keys.
const connectTimeout = Duration(seconds: 10);
const receiveTimeout = Duration(seconds: 15);

/// `shared_preferences` key of the chosen language (not a secret).
const localePrefsKey = 'app_locale';

/// Languages the app and the backend support; the first one is the fallback.
const supportedLanguageCodes = ['fr', 'en'];

/// Path prefix of the backend API.
const apiPrefix = '/api/v1/';
