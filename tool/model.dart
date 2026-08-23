class AlgorithmDefinition {
  AlgorithmDefinition({
    required this.id,
    required this.author,
    required this.name,
    required this.color,
    required this.className,
    required this.path,
    required this.source,
  });

  final String id;
  final String author;
  final String name;
  final String color;
  final String className;
  final String path;
  final String source;

  Map<String, Object?> toJson() => {
        'id': id,
        'author': author,
        'name': name,
        'color': color,
        'className': className,
        'path': path,
        'source': source,
      };
}

class AlgorithmDiagnostic {
  AlgorithmDiagnostic({
    required this.path,
    required this.author,
    required this.message,
  });

  final String path;
  final String author;
  final String message;

  Map<String, Object?> toJson() => {
        'path': path,
        'author': author,
        'message': message,
      };
}
