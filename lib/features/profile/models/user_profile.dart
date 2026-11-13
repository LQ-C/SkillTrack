class UserProfile {
  const UserProfile({
    required this.name,
    required this.birthDate,
    required this.role,
    required this.bio,
  });
  final String name, birthDate, role, bio;
  factory UserProfile.fromJson(Map<String, dynamic> row) => UserProfile(
    name: row['full_name'] as String,
    birthDate: row['date_of_birth'] as String,
    role: row['role'] as String,
    bio: row['bio'] as String? ?? '',
  );
}
