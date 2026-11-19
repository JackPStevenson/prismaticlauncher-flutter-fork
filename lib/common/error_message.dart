// Port note: the C++ code reports failures through optional `QString* errorMessage`
// out-parameters. Dart has no out-parameters, so callers pass this small mutable holder
// instead. Passing `null` keeps the C++ "caller does not care about the reason" behavior.

/// @brief Mutable holder that receives a human-readable failure reason.
class ErrorMessage {
  /// @brief The most recent failure reason, or an empty string when none was recorded.
  String value = '';

  /// @brief Returns true when no failure reason has been recorded.
  bool get isEmpty => value.isEmpty;

  @override
  String toString() => value;
}

/// @brief Stores a failure reason when the caller supplied a holder.
void setError(ErrorMessage? errorMessage, String message) {
  if (errorMessage != null) errorMessage.value = message;
}
