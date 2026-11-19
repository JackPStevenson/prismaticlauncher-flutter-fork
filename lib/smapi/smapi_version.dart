// Port of src/smapi/SmapiVersion.h.

/// @brief A SMAPI semantic version read from its managed assemblies.
class SmapiVersion {
  /// @brief Creates a version; omitted parts default to zero like the C++ aggregate.
  const SmapiVersion({this.major = 0, this.minor = 0, this.patch = 0, this.prerelease = ''});

  final int major;
  final int minor;
  final int patch;
  final String prerelease;

  /// @brief Returns true when no version component is negative.
  bool get isValid => major >= 0 && minor >= 0 && patch >= 0;

  /// @brief Formats the version as `major.minor.patch[-prerelease]`.
  @override
  String toString() {
    final base = '$major.$minor.$patch';
    return prerelease.isEmpty ? base : '$base-$prerelease';
  }

  // Replaces the C++ defaulted `operator==`.
  @override
  bool operator ==(Object other) =>
      other is SmapiVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.prerelease == prerelease;

  @override
  int get hashCode => Object.hash(major, minor, patch, prerelease);
}
