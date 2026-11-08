import 'dart:convert';
import 'dart:io';

import '../../data/models/remote_file.dart';
import '../../data/repositories/machine_connection.dart';
import 'model_bar_models.dart';

class ModelBarException implements Exception {
  const ModelBarException(this.message);

  final String message;

  @override
  String toString() => message;
}

const defaultModelBarGatewayUrl = 'http://127.0.0.1:8318';

class ModelBarClient {
  const ModelBarClient({this.baseUrl = defaultModelBarGatewayUrl});

  final String baseUrl;

  /// Fetches all models from `GET /v1/models/ready` on loopback.
  Future<List<ReadyModel>> fetchReadyModels(MachineConnection machine) async {
    final cmd = 'curl -s $baseUrl/v1/models/ready';
    try {
      final exec = await machine.api.transport.openExec(cmd);
      final lines = await exec.lines.toList();
      final code = await exec.exitCode;
      if (code != 0 && code != null) {
        throw ModelBarException('Failed to fetch models (exit code $code)');
      }
      final raw = lines.join('\n').trim();
      if (raw.isEmpty) {
        throw const ModelBarException('Empty response from model service');
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['models'] is! List) {
        throw const ModelBarException('Invalid models response format');
      }
      final modelsList = (decoded['models'] as List).cast<Map<String, dynamic>>();
      return modelsList.map(ReadyModel.fromJson).toList();
    } catch (e) {
      if (e is ModelBarException) rethrow;
      throw ModelBarException('Unable to reach model service: $e');
    }
  }

  /// Fetches the current ModelBarConfig.
  /// Primary route: `GET /v1/model-bar` via curl loopback.
  /// Fallback route: read `~/.config/effortless/model-bar.json` directly via SFTP.
  Future<ModelBarConfig> fetchConfig(MachineConnection machine) async {
    final cmd = 'curl -s $baseUrl/v1/model-bar';
    try {
      final exec = await machine.api.transport.openExec(cmd);
      final lines = await exec.lines.toList();
      final code = await exec.exitCode;
      if (code == 0 || code == null) {
        final raw = lines.join('\n').trim();
        if (raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic> && decoded['error'] == null) {
            return parseAndValidateModelBarJson(decoded);
          }
        }
      }
      // If code non-zero or invalid payload, fall through to fallback
    } catch (_) {
      // Fallback to direct file read
    }

    return _fallbackReadConfig(machine);
  }

  /// Saves the updated ModelBarConfig.
  /// Primary route: `PUT /v1/model-bar` via curl loopback.
  /// Fallback route: writes `~/.config/effortless/model-bar.json` directly via SFTP with client validation.
  Future<ModelBarConfig> saveConfig(MachineConnection machine, ModelBarConfig config) async {
    validateModelBarJson(config.toJson());
    final payload = jsonEncode(config.toJson());

    final cmd = "curl -s -X PUT -H 'Content-Type: application/json' --data-binary @- $baseUrl/v1/model-bar";
    try {
      final exec = await machine.api.transport.openExec(cmd);
      exec.send(payload);
      await exec.closeInput();
      final lines = await exec.lines.toList();
      final code = await exec.exitCode;
      if (code != 0 && code != null) {
        throw ModelBarException('Server rejected model bar update (exit code $code)');
      }
      final raw = lines.join('\n').trim();
      if (raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          if (decoded['error'] != null) {
            final reason = decoded['reason'] as String? ?? decoded['error'] as String;
            throw ModelBarException('Model bar update failed: $reason');
          }
          if (decoded['pinned'] is List && decoded['more'] is List) {
            return ModelBarConfig(
              pinned: (decoded['pinned'] as List).cast<String>(),
              more: (decoded['more'] as List).cast<String>(),
            );
          }
        }
      }
      return config;
    } catch (e) {
      if (e is ModelBarException) rethrow;
      // Try fallback direct file write
      try {
        return await _fallbackWriteConfig(machine, config);
      } catch (fallbackError) {
        throw ModelBarException('Failed to save model bar: $e ($fallbackError)');
      }
    }
  }

  Future<ModelBarConfig> _fallbackReadConfig(MachineConnection machine) async {
    try {
      final home = await machine.files.home();
      final filePath = '$home/.config/effortless/model-bar.json';
      final stat = await machine.files.stat(filePath);
      final size = stat.size ?? 0;
      if (size == 0) return const ModelBarConfig();
      final bytes = await machine.files.readAll(filePath, size: size);
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map<String, dynamic>) {
        return parseAndValidateModelBarJson(decoded);
      }
    } catch (e) {
      if (e is RemoteFileException && e.kind == RemoteFileErrorKind.notFound) {
        return const ModelBarConfig();
      }
    }
    return const ModelBarConfig();
  }

  Future<ModelBarConfig> _fallbackWriteConfig(MachineConnection machine, ModelBarConfig config) async {
    final home = await machine.files.home();
    final dir = '$home/.config/effortless';
    await machine.files.makeDirs(dir);
    final filePath = '$dir/model-bar.json';

    final tempFile = File('${Directory.systemTemp.path}/model-bar-${DateTime.now().microsecondsSinceEpoch}.json');
    try {
      await tempFile.writeAsString(jsonEncode(config.toJson()));
      final uploadJob = machine.files.upload(localPath: tempFile.path, remotePath: filePath);
      await uploadJob.done;
      return config;
    } finally {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }
  }
}
