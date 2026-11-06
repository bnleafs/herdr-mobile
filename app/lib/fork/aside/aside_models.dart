import 'package:flutter/foundation.dart';

/// One question and answer turn in an aside thread.
@immutable
class AsideTurn {
  const AsideTurn({
    required this.id,
    required this.question,
    required this.answer,
    required this.timestamp,
    this.incomplete = false,
  });

  final String id;

  /// User-visible question text (without any prompt prefixes or context).
  final String question;

  /// Answer text extracted from Claude Code's native /btw panel.
  final String answer;

  final DateTime timestamp;

  /// True if reading timed out or was cut off.
  final bool incomplete;

  AsideTurn copyWith({String? id, String? question, String? answer, DateTime? timestamp, bool? incomplete}) =>
      AsideTurn(
        id: id ?? this.id,
        question: question ?? this.question,
        answer: answer ?? this.answer,
        timestamp: timestamp ?? this.timestamp,
        incomplete: incomplete ?? this.incomplete,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'question': question,
    'answer': answer,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'incomplete': incomplete,
  };

  factory AsideTurn.fromJson(Map<String, dynamic> json) => AsideTurn(
    id: json['id'] as String? ?? '',
    question: json['question'] as String? ?? '',
    answer: json['answer'] as String? ?? '',
    timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int? ?? 0),
    incomplete: json['incomplete'] == true,
  );
}

/// A conversation thread consisting of an initial aside question and follow-ups.
@immutable
class AsideThread {
  const AsideThread({required this.id, required this.turns, required this.createdAt, required this.updatedAt});

  final String id;
  final List<AsideTurn> turns;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// First question as title, or default label if empty.
  String get title => turns.isNotEmpty ? turns.first.question : 'New aside';

  AsideThread copyWith({String? id, List<AsideTurn>? turns, DateTime? createdAt, DateTime? updatedAt}) => AsideThread(
    id: id ?? this.id,
    turns: turns ?? this.turns,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'turns': turns.map((t) => t.toJson()).toList(),
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };

  factory AsideThread.fromJson(Map<String, dynamic> json) => AsideThread(
    id: json['id'] as String? ?? '',
    turns: (json['turns'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().map(AsideTurn.fromJson).toList(),
    createdAt: DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int? ?? 0),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int? ?? 0),
  );
}
