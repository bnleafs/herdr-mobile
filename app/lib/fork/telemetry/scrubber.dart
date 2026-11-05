import 'package:sentry_flutter/sentry_flutter.dart';

/// Deny-list scrubber enforcing security exclusions:
/// (a) Credentials: SSH keys, passwords, passphrases, account phrase/key, tokens, DSNs.
/// (b) Sensitive output: terminal output, chat transcript, prompt text, file contents.
///
/// Keeps rich context: machine labels, agent kinds, screen/route names, real error strings,
/// and full Dart stack traces.
class MegawattScrubber {
  const MegawattScrubber();

  // PEM block: -----BEGIN ... ----- ... -----END ... -----
  static final _pemPattern = RegExp(r'-----BEGIN [A-Z0-9 _-]+-----[\s\S]*?-----END [A-Z0-9 _-]+-----', multiLine: true);

  // Sentry DSN pattern: https://<key>@<host>/<id> or https://<key>:<secret>@<host>/<id>
  static final _dsnPattern = RegExp(
    r'https?:\/\/[a-zA-Z0-9_-]+(?::[a-zA-Z0-9_-]+)?@[a-zA-Z0-9_.-]+(?::[0-9]+)?\/[0-9]+',
  );

  // URL user:password authentication: scheme://user:password@host
  static final _urlAuthPattern = RegExp(r'([a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\s/@:]+):([^\s/@:]+)@');

  // Authorization: Bearer <token>
  static final _bearerPattern = RegExp(r'''\bBearer\s+("[^"]*"|'[^']*'|[^\s,;&"'>]+)''', caseSensitive: false);

  // Key-value credentials in text/query-strings/json: password=..., token=..., "password": "...", etc.
  static final _credentialPattern = RegExp(
    r'''(?:\b|"|')(password|passwd|passphrase|token|secret|api[_-]?key|ssh[_-]?key|authorization|auth|account[_-]?phrase|account[_-]?key|private[_-]?key)(?:\b|"|')\s*(?:[:=]|\bis\b)\s*(?:Bearer\s+)?("[^"]*"|'[^']*'|[^\s,;&"'>]+)''',
    caseSensitive: false,
  );

  // Terminal/chat/prompt/file_content patterns in text/json: prompt=..., "stdout": "...", etc.
  static final _sensitiveContentPattern = RegExp(
    r'''(?:\b|"|')(prompt|transcript|terminal[_-]?output|terminal|stdout|stderr|file[_-]?content|chat[_-]?text)(?:\b|"|')\s*(?:[:=]|\bis\b)\s*("[^"]*"|'[^']*'|[^\n,;&]+)''',
    caseSensitive: false,
  );

  // ANSI escape sequences
  static final _ansiPattern = RegExp(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])');

  // Sensitive key names in maps / dictionaries
  static final _sensitiveKeyPattern = RegExp(
    r'^(.*[_\-])?(password|passwd|token|secret|passphrase|authorization|auth|dsn|credential|account[_\-]?phrase|account[_\-]?key|private[_\-]?key|api[_\-]?key|ssh[_\-]?key|prompt|transcript|terminal([_\-]?output)?|stdout|stderr|file[_\-]?content|chat[_\-]?text)([_\-].*)?$',
    caseSensitive: false,
  );

  /// Scrubs free-text strings: redacts PEM blocks, DSNs, credential patterns,
  /// prompt/terminal output patterns, and removes ANSI escape codes.
  String? scrubText(String? input) {
    if (input == null || input.isEmpty) return input;
    var result = input;
    result = result.replaceAll(_pemPattern, '[REDACTED_PEM]');
    result = result.replaceAll(_dsnPattern, '[REDACTED_DSN]');
    result = result.replaceAllMapped(_urlAuthPattern, (match) => '${match.group(1)}:[REDACTED]@');
    result = result.replaceAllMapped(_bearerPattern, (match) => 'Bearer [REDACTED]');
    result = result.replaceAllMapped(_credentialPattern, (match) {
      final key = match.group(1);
      return '$key=[REDACTED]';
    });
    result = result.replaceAllMapped(_sensitiveContentPattern, (match) {
      final key = match.group(1);
      return '$key=[REDACTED]';
    });
    result = result.replaceAll(_ansiPattern, '');
    return result;
  }

  /// Recursively scrubs a Map, redacting sensitive keys or scrubbing string values.
  Map<String, dynamic>? scrubMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final result = <String, dynamic>{};
    for (final entry in map.entries) {
      final key = entry.key;
      final val = entry.value;
      if (_sensitiveKeyPattern.hasMatch(key)) {
        result[key] = '[REDACTED]';
      } else if (val is String) {
        result[key] = scrubText(val);
      } else if (val is Map<String, dynamic>) {
        result[key] = scrubMap(val);
      } else if (val is Map) {
        result[key] = scrubMap(Map<String, dynamic>.from(val));
      } else if (val is List) {
        result[key] = scrubList(val);
      } else {
        result[key] = val;
      }
    }
    return result;
  }

  /// Recursively scrubs a List of items.
  List<dynamic>? scrubList(List<dynamic>? list) {
    if (list == null) return null;
    return list.map((item) {
      if (item is String) return scrubText(item);
      if (item is Map<String, dynamic>) return scrubMap(item);
      if (item is Map) return scrubMap(Map<String, dynamic>.from(item));
      if (item is List) return scrubList(item);
      return item;
    }).toList();
  }

  /// Scrubs structured Sentry logs.
  SentryLog scrubLog(SentryLog log) {
    log.body = scrubText(log.body) ?? '';
    final newAttributes = <String, SentryAttribute>{};
    for (final entry in log.attributes.entries) {
      final key = entry.key;
      final attr = entry.value;
      if (_sensitiveKeyPattern.hasMatch(key)) {
        newAttributes[key] = SentryAttribute.string('[REDACTED]');
      } else if (attr.value is String) {
        newAttributes[key] = SentryAttribute.string(scrubText(attr.value as String) ?? '');
      } else {
        newAttributes[key] = attr;
      }
    }
    log.attributes = newAttributes;
    return log;
  }

  /// Scrubs breadcrumb messages and payload data.
  Breadcrumb scrubBreadcrumb(Breadcrumb breadcrumb) {
    if (breadcrumb.message != null) {
      breadcrumb.message = scrubText(breadcrumb.message!);
    }
    if (breadcrumb.data != null) {
      breadcrumb.data = scrubMap(breadcrumb.data!);
    }
    return breadcrumb;
  }

  /// Scrubs an entire SentryEvent before dispatch.
  SentryEvent scrubEvent(SentryEvent event) {
    if (event.message != null) {
      event.message!.formatted = scrubText(event.message!.formatted) ?? '';
      if (event.message!.template != null) {
        event.message!.template = scrubText(event.message!.template);
      }
      if (event.message!.params != null) {
        event.message!.params = scrubList(event.message!.params);
      }
    }
    if (event.exceptions != null) {
      for (final exc in event.exceptions!) {
        if (exc.value != null) {
          exc.value = scrubText(exc.value!);
        }
        if (exc.mechanism != null) {
          if (exc.mechanism!.description != null) {
            exc.mechanism!.description = scrubText(exc.mechanism!.description);
          }
          if (exc.mechanism!.data.isNotEmpty) {
            exc.mechanism!.data = scrubMap(exc.mechanism!.data);
          }
        }
      }
    }
    if (event.tags != null) {
      final scrubbedTags = <String, String>{};
      for (final entry in event.tags!.entries) {
        if (_sensitiveKeyPattern.hasMatch(entry.key)) {
          scrubbedTags[entry.key] = '[REDACTED]';
        } else {
          scrubbedTags[entry.key] = scrubText(entry.value) ?? '';
        }
      }
      event.tags = scrubbedTags;
    }
    // ignore: deprecated_member_use
    if (event.extra != null) {
      // ignore: deprecated_member_use
      event.extra = scrubMap(event.extra!);
    }
    for (final key in event.contexts.keys) {
      final value = event.contexts[key];
      if (value is Map<String, dynamic>) {
        event.contexts[key] = scrubMap(value);
      } else if (value is Map) {
        event.contexts[key] = scrubMap(Map<String, dynamic>.from(value));
      }
    }
    if (event.breadcrumbs != null) {
      for (final b in event.breadcrumbs!) {
        scrubBreadcrumb(b);
      }
    }
    // Defense-in-depth: strip any accidental screenshots or view hierarchies
    event.contexts.remove('view_hierarchy');
    event.contexts.remove('screenshot');
    return event;
  }
}

const megawattScrubber = MegawattScrubber();
