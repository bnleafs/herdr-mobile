import 'package:flutter/foundation.dart';

/// Represents a model entry returned from cc-gateway's `GET /v1/models/ready`.
@immutable
class ReadyModel {
  const ReadyModel({
    required this.id,
    this.alias,
    this.provider,
    this.upstream,
    this.tier,
    this.configuredInUpstream = false,
    this.inCooldown = false,
    this.ready = true,
  });

  final String id;
  final String? alias;
  final String? provider;
  final String? upstream;
  final String? tier;
  final bool configuredInUpstream;
  final bool inCooldown;
  final bool ready;

  bool get hasDistinctAlias => alias != null && alias!.isNotEmpty && alias != id;

  factory ReadyModel.fromJson(Map<String, dynamic> json) => ReadyModel(
    id: json['id'] as String? ?? '',
    alias: json['alias'] as String?,
    provider: json['provider'] as String?,
    upstream: json['upstream'] as String?,
    tier: json['tier'] as String?,
    configuredInUpstream: json['configuredInUpstream'] == true,
    inCooldown: json['inCooldown'] == true,
    ready: json['ready'] != false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (alias != null) 'alias': alias,
    if (provider != null) 'provider': provider,
    if (upstream != null) 'upstream': upstream,
    if (tier != null) 'tier': tier,
    'configuredInUpstream': configuredInUpstream,
    'inCooldown': inCooldown,
    'ready': ready,
  };
}

/// Represents the shared quick-access model bar configuration (`~/.config/effortless/model-bar.json`).
@immutable
class ModelBarConfig {
  const ModelBarConfig({this.pinned = const [], this.more = const []});

  final List<String> pinned;
  final List<String> more;

  bool isPinned(String modelId) => pinned.contains(modelId);

  /// Optimistically toggles a model:
  /// - If pinned, unpins it (moving to [more]).
  /// - If unpinned, pins it (moving to [pinned] and removing from [more]).
  ModelBarConfig withToggled(String modelId) {
    if (isPinned(modelId)) {
      final nextPinned = pinned.where((id) => id != modelId).toList();
      final nextMore = [...more.where((id) => id != modelId), modelId];
      return ModelBarConfig(pinned: nextPinned, more: nextMore);
    } else {
      final nextPinned = [...pinned, modelId];
      final nextMore = more.where((id) => id != modelId).toList();
      return ModelBarConfig(pinned: nextPinned, more: nextMore);
    }
  }

  factory ModelBarConfig.fromJson(Map<String, dynamic> json) {
    validateModelBarJson(json);
    return ModelBarConfig(pinned: (json['pinned'] as List).cast<String>(), more: (json['more'] as List).cast<String>());
  }

  Map<String, dynamic> toJson() => {'pinned': pinned, 'more': more};
}

/// Validates that [json] adheres to the server contract:
/// - Only 'pinned' and 'more' keys allowed.
/// - Both must be lists of non-empty, trimmed strings.
void validateModelBarJson(Map<String, dynamic> json) {
  const allowedKeys = {'pinned', 'more'};
  for (final key in json.keys) {
    if (!allowedKeys.contains(key)) {
      throw FormatException("unknown field '$key' is not permitted");
    }
  }

  for (final key in allowedKeys) {
    final val = json[key];
    if (val == null || val is! List) {
      throw FormatException("field '$key' must be an array of strings");
    }
    for (final item in val) {
      if (item is! String || item.trim().isEmpty) {
        throw FormatException("all items in '$key' must be non-empty trimmed strings");
      }
    }
  }
}

/// Parses and validates JSON into a [ModelBarConfig].
ModelBarConfig parseAndValidateModelBarJson(Map<String, dynamic> json) {
  validateModelBarJson(json);
  return ModelBarConfig(
    pinned: (json['pinned'] as List).map((e) => (e as String).trim()).toList(),
    more: (json['more'] as List).map((e) => (e as String).trim()).toList(),
  );
}
