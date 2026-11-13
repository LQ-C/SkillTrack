String? youtubeVideoId(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      RegExp(r'\s').hasMatch(value)) {
    return null;
  }
  final host = uri.host.toLowerCase();
  final parts = uri.pathSegments;
  String? id;
  if (host == 'youtu.be' || host == 'www.youtu.be') {
    if (parts.length == 1) id = parts.first;
  } else if ([
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'youtube-nocookie.com',
    'www.youtube-nocookie.com',
  ].contains(host)) {
    if (uri.path == '/watch') {
      id = uri.queryParameters['v'];
    } else if (parts.length == 2 &&
        ['embed', 'shorts', 'live'].contains(parts.first)) {
      id = parts[1];
    }
  }
  return id != null && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id) ? id : null;
}
