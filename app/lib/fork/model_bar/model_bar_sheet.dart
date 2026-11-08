import 'dart:async';

import 'package:flutter/material.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/settings/settings_group.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'model_bar_client.dart';
import 'model_bar_models.dart';

/// One row in Settings to open the native Model Bar sheet.
class ModelBarGroup extends StatelessWidget {
  const ModelBarGroup({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Hairline(indent: ListRow.textIndent()),
        SettingsGroup(
          icon: LucideIcons.star,
          title: 'Model Bar',
          summary: 'Quick-access models',
          open: false,
          onToggle: () {
            final fleet = Provider.of<FleetRepository?>(context, listen: false);
            final machine = _findMachine(fleet);
            if (machine != null) {
              unawaited(showModelBarSheet(context, machine: machine));
            }
          },
          divider: false,
          rows: const [],
        ),
      ],
    );
  }

  static MachineConnection? _findMachine(FleetRepository? fleet) {
    if (fleet == null) return null;
    for (final c in fleet.connections) {
      if (c.isLive) return c;
    }
    return fleet.connections.isNotEmpty ? fleet.connections.first : null;
  }
}

/// Opens the native Model Bar sheet for [machine].
Future<void> showModelBarSheet(
  BuildContext context, {
  required MachineConnection machine,
  ModelBarClient? client,
}) async {
  await showAppSheet<void>(
    context,
    builder: (ctx) => ModelBarSheet(
      machine: machine,
      client: client ?? const ModelBarClient(),
    ),
  );
}

class ModelBarSheet extends StatefulWidget {
  const ModelBarSheet({
    super.key,
    required this.machine,
    this.client = const ModelBarClient(),
  });

  final MachineConnection machine;
  final ModelBarClient client;

  @override
  State<ModelBarSheet> createState() => _ModelBarSheetState();
}

class _ModelBarSheetState extends State<ModelBarSheet> {
  final _searchController = TextEditingController();
  List<ReadyModel> _models = [];
  ModelBarConfig _config = const ModelBarConfig();
  ModelBarConfig? _optimisticConfig;

  bool _loading = true;
  String? _loadError;
  String? _actionError;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _load();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    if (query != _filter) {
      setState(() => _filter = query);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
      _actionError = null;
    });

    try {
      final futures = await Future.wait([
        widget.client.fetchReadyModels(widget.machine),
        widget.client.fetchConfig(widget.machine),
      ]);
      if (!mounted) return;
      setState(() {
        _models = futures[0] as List<ReadyModel>;
        _config = futures[1] as ModelBarConfig;
        _optimisticConfig = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Unable to load models: $e';
      });
    }
  }

  Future<void> _toggleStar(String modelId) async {
    final current = _optimisticConfig ?? _config;
    final next = current.withToggled(modelId);

    // Optimistic toggle
    setState(() {
      _optimisticConfig = next;
      _actionError = null;
    });

    try {
      final saved = await widget.client.saveConfig(widget.machine, next);
      if (!mounted) return;
      setState(() {
        _config = saved;
        _optimisticConfig = null;
      });
    } catch (e) {
      if (!mounted) return;
      // Adversarial rollback: revert optimistic state and display inline error
      setState(() {
        _optimisticConfig = null;
        _actionError = 'Failed to update Model Bar: $e';
      });
    }
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final activeConfig = _optimisticConfig ?? _config;

    final filtered = _models.where((m) {
      if (_filter.isEmpty) return true;
      if (m.id.toLowerCase().contains(_filter)) return true;
      if (m.alias?.toLowerCase().contains(_filter) ?? false) return true;
      return false;
    }).toList();

    return Container(
      color: ds.bg,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: Gap.sm),
          const Center(child: SheetGrabber()),
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.xs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Model Bar',
                    style: Type.title.copyWith(color: ds.text),
                  ),
                ),
                if (_loading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.xs),
            child: SearchField(
              controller: _searchController,
              hint: 'Search models...',
            ),
          ),
          if (_actionError != null)
            Container(
              margin: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.xs),
              padding: const EdgeInsets.all(Gap.sm),
              decoration: BoxDecoration(
                color: ds.blocked.withOpacity(0.12),
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(color: ds.blocked.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.alertCircle, size: 16, color: ds.blocked),
                  const SizedBox(width: Gap.sm),
                  Expanded(
                    child: Text(
                      _actionError!,
                      style: Type.body.copyWith(color: ds.blocked, fontSize: 13),
                    ),
                  ),
                  IconButton(
                    icon: Icon(LucideIcons.x, size: 14, color: ds.blocked),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => setState(() => _actionError = null),
                  ),
                ],
              ),
            ),
          const Divider(height: 1),
          Flexible(
            child: _buildBody(ds, activeConfig, filtered),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(Ds ds, ModelBarConfig activeConfig, List<ReadyModel> filtered) {
    if (_loading && _models.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(Gap.xl),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_loadError != null && _models.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _loadError!,
                style: Type.body.copyWith(color: ds.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Gap.md),
              OutlinedButton(
                onPressed: _load,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xl),
          child: Text(
            'No models match',
            style: Type.body.copyWith(color: ds.textSecondary),
          ),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      itemCount: filtered.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final model = filtered[index];
        final isPinned = activeConfig.isPinned(model.id);

        return ListTile(
          dense: true,
          leading: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: model.ready ? ds.done : ds.faint,
            ),
          ),
          title: Text(
            model.id,
            style: Type.bodyStrong.copyWith(color: ds.text),
          ),
          subtitle: model.hasDistinctAlias
              ? Text(
                  model.alias!,
                  style: Type.body.copyWith(color: ds.textSecondary, fontSize: 12),
                )
              : null,
          trailing: IconButton(
            icon: Icon(
              LucideIcons.star,
              color: isPinned ? ds.accent : ds.textSecondary,
              fill: isPinned ? 1.0 : 0.0,
            ),
            tooltip: isPinned ? 'Unstar model' : 'Star model',
            onPressed: () => _toggleStar(model.id),
          ),
        );
      },
    );
  }
}
