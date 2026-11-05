import '../../data/models/machine_profile.dart';
import '../../data/repositories/machine_connection.dart';
import '../../data/words/plural.dart';
import '../../ui/core/glyphs.dart';

/// Whether [machine] is in a normal/transient reconnect with retained usable
/// data and no recorded actionable error.
bool isTransientReconnect(MachineConnection machine) =>
    machine.state == LinkState.reconnecting && machine.error == null && machine.snapshot.workspaces.isNotEmpty;

/// Subtitle lead for a machine row: shows agent count when online or
/// updating during transient reconnect with retained data, else the link state.
String machineSubtitleLead({required MachineConnection machine, required MachineProfile profile, required int agents}) {
  if (machine.state == LinkState.online) {
    return agents == 0 ? 'No agents' : countOf(agents, 'agent');
  }
  if (isTransientReconnect(machine) && profile.enabled) {
    return '${agents == 0 ? 'No agents' : countOf(agents, 'agent')} · Updating';
  }
  return profile.enabled ? machine.state.label : '${machine.state.label} · not connecting';
}
