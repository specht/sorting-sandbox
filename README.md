# Sorting Sandbox

Mit der Sorting Sandbox könnt ihr Sortieralgorithmen in Dart schreiben,
beobachten, vergleichen und untersuchen.

## Was liegt wo?

Ihr arbeitet mit zwei Git-Repositories:

- `~/sorting-sandbox/` enthält die App. Dieses Repository wird von der
  Lehrkraft gepflegt.
- `~/sorting-sandbox/algorithms/` enthält die Algorithmen der Klasse. In diesem
  Repository arbeitet und veröffentlicht ihr.

Ändert nur Dateien im Verzeichnis `algorithms/`.

## 1. Bei GitLab anmelden

Öffne [git.nhcham.org](https://git.nhcham.org/) im Browser und melde dich an.

## 2. SSH-Schlüssel erstellen

Mit einem SSH-Schlüssel kann sich dein Workspace beim GitLab-Server anmelden.
Prüfe zuerst im Terminal, ob bereits ein Schlüssel vorhanden ist:

```bash
ls ~/.ssh/id_ed25519.pub
```

Wird die Datei angezeigt, verwendest du diesen Schlüssel und machst unten mit
dem `cat`-Befehl weiter. Falls `No such file or directory` erscheint, erstellst
du einen neuen Schlüssel:

```bash
ssh-keygen -t ed25519 -C "Vorname Nachname"
```

Bestätige den vorgeschlagenen Speicherort mit Enter. Im Schul-Workspace kannst
du auch die Passphrase leer lassen und noch zweimal Enter drücken.

Zeige nun den **öffentlichen** Schlüssel an:

```bash
cat ~/.ssh/id_ed25519.pub
```

Kopiere die gesamte ausgegebene Zeile. Sie beginnt mit `ssh-ed25519`. Kopiere
niemals die private Datei `~/.ssh/id_ed25519` und lade sie nirgendwo hoch.

Gehe in GitLab oben rechts auf dein Profilbild und dann auf **Edit profile →
Access → SSH keys → Add new key**. Füge die kopierte Zeile bei **Key** ein,
vergib als Titel zum Beispiel `Workspace` und speichere den Schlüssel.

Teste anschließend die Verbindung:

```bash
ssh -T git@git.nhcham.org
```

Bestätige beim ersten Verbindungsaufbau die Rückfrage mit `yes`. Danach sollte
GitLab dich mit deinem Benutzernamen begrüßen.

## 3. Git einmalig einrichten

Trage deinen echten Namen und die E-Mail-Adresse deines GitLab-Kontos ein:

```bash
git config --global user.name "Vorname Nachname"
git config --global user.email "deine.mail@example.org"
```

Diese beiden Befehle sind in jedem Workspace nur einmal nötig.

## 4. Das Klassen-Repository klonen

Wechsle in das Verzeichnis der App und klone das gemeinsame Repository genau
in den Unterordner `algorithms`:

```bash
cd ~/sorting-sandbox
git clone git@git.nhcham.org:specht/sorting-sandbox-algorithms-2026.git algorithms
```

Falls das Verzeichnis bereits vorhanden und fertig eingerichtet ist, klonst du
es nicht erneut. Wechsle stattdessen hinein und hole den aktuellen Stand:

```bash
cd ~/sorting-sandbox/algorithms
git pull
```

## 5. Die App starten

Für die App wird nur das Dart SDK benötigt (kein Flutter). Starte sie in
einem Terminal:

```bash
cd ~/sorting-sandbox
./run
```

Der Browser öffnet sich automatisch (sonst öffne `http://127.0.0.1:8080/`).
Lasse dieses Terminal geöffnet, solange du mit der App arbeitest. Für die
Git-Befehle öffnest du ein zweites Terminal.

Der Knopf mit Sonne bzw. Mond oben rechts wechselt zwischen dunklem und hellem
Design. Die App merkt sich die Wahl in der Datei `.settings.yaml` im
App-Ordner; Git ignoriert sie, sie landet also in keinem Repository.

## 6. Deinen Algorithmus hinzufügen

Hole im zweiten Terminal zuerst die neuesten Änderungen der Klasse:

```bash
cd ~/sorting-sandbox/algorithms
git pull
```

Lege dann im **App-Verzeichnis** deinen eigenen Algorithmus an. Ersetze
`DEIN_NAME` durch deinen vereinbarten Namen oder Benutzernamen:

```bash
cd ~/sorting-sandbox
./new-algorithm DEIN_NAME
```

Der Befehl legt `algorithms/DEIN_NAME/bubble_sort.dart` mit einem Bubble Sort
als Ausgangspunkt an. Für einen weiteren, leeren Algorithmus gibst du einen
Dateinamen an, zum Beispiel:

```bash
./new-algorithm DEIN_NAME quick_sort
```

Vorhandene Dateien werden nie überschrieben. Mehrere Versionen desselben
Algorithmus, zum Beispiel eine rekursive und eine iterative, sind einfach
weitere Dateien in deinem Ordner (etwa `merge_sort.dart` und
`merge_sort_recursive.dart`). Tragen zwei davon denselben Namen, zeigt die App
den Dateinamen dahinter an.

Die Datei erscheint nach wenigen Sekunden von selbst in der App. Wähle sie im
Reiter **Explore** oben in der Algorithmen-Auswahl aus. Links siehst du den
Quelltext und kannst ihn **direkt im Browser bearbeiten**:

```dart
import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

class BubbleSort extends SortingAlgorithm {
  get name => 'Bubble Sort';
  get color => Colors.green;

  void sort(Elements list, Elements scratch) {
    int length = list.length;
    for (int i = 0; i < length; i++) {
      for (int j = 0; j < length - 1; j++) {
        if (list[j] > list[j + 1]) list.swap(j, j + 1);
      }
    }
  }
}
```

Du kannst `name`, `color` und natürlich den Sortieralgorithmus ändern. Der
Autor ist automatisch dein Ordnername. Der Bubble Sort ist absichtlich noch
nicht optimiert: Untersuche zum Beispiel, ob beide Schleifen wirklich immer so
weit laufen müssen.

Im Editor gelten diese Tastenkürzel:

- **Strg+S** speichert die Datei (oder der Knopf **Save**),
- **Strg+Shift+K** löscht eine Zeile, **Strg+#** kommentiert Zeilen aus,
- **Format** (bzw. **Shift+Alt+F**) formatiert den Entwurf wie `dart format`,
- **Revert** verwirft ungespeicherte Änderungen.

Nach dem Speichern prüft und übersetzt die App deinen Code automatisch. Ein
Fehler wird mit Zeilennummer **unter dem Editor** angezeigt und im Quelltext
rot unterstrichen; ein Klick auf die Meldung springt zur Zeile. Die
Visualisierung verwendet immer die zuletzt **gespeicherte** Version. Du kannst
die Datei auch mit jedem anderen Editor bearbeiten; die App bemerkt das
Speichern ebenfalls.

### Ausprobieren

- **Run** startet die Animation, **Space** pausiert und setzt fort.
- **←** und **→** gehen einen Schritt zurück bzw. vor. Mit dem Schieberegler
  über den Knöpfen springst du zu einem beliebigen früheren Schritt.
- Die aktuelle Zeile wird im Quelltext hervorgehoben. Unter den Balken stehen
  deine lokalen Variablen; Variablen wie `i` und `j`, die auf eine Position
  zeigen, erscheinen zusätzlich als Zeiger unter der Liste.
- **Highlight reads/writes** markiert, welche Elemente im letzten Schritt
  gelesen (orange) und geschrieben (rot) wurden.
- `print(...)` in deinem Algorithmus erscheint in der **Console**. Dort stehen
  auch Laufzeitfehler (zum Beispiel ein Index außerhalb der Liste) mit der
  Zeilennummer. Eine Endlosschleife wird nach wenigen Sekunden gestoppt.
- **Check** testet deinen Algorithmus auf vielen Eingaben und zeigt dir bei
  einem Fehler die Eingabe, an der er scheitert. Außerdem wird geprüft, ob er
  stabil ist (gleiche Werte behalten ihre Reihenfolge).

In **Race** treten zwei bis vier Algorithmen mit genau derselben Eingabe
gegeneinander an. In **Analyze** werden alle Algorithmen der Klasse geprüft
und ihre Lese-, Schreib- und Vergleichsoperationen für wachsende Eingaben
verglichen.

## 7. Deinen Algorithmus veröffentlichen

Wechsle im zweiten Terminal in das Klassen-Repository und prüfe deine
Änderungen:

```bash
cd ~/sorting-sandbox/algorithms
git status
```

Füge nur deine eigene Datei hinzu. Ersetze wieder `DEIN_NAME`:

```bash
git add DEIN_NAME/bubble_sort.dart
git commit -m "Add bubble sort by DEIN_NAME"
git push
```

Nach dem erfolgreichen `push` können alle anderen deinen Algorithmus mit
`git pull` erhalten. Er erscheint dann ohne Neustart in ihrer App.

Falls der Push mit `rejected` abgelehnt wird, hat wahrscheinlich jemand anderes
kurz vor dir etwas veröffentlicht. Lösche oder überschreibe dann keine fremden
Dateien, sondern frage nach Hilfe beim Zusammenführen der Änderungen.

## 8. Beim nächsten Mal weiterarbeiten

Aktualisiere zuerst die App, dann die Algorithmen und starte anschließend:

```bash
cd ~/sorting-sandbox
git pull
cd algorithms
git pull
cd ..
./run
```

Bevor du deinen eigenen Algorithmus bearbeitest, solltest du im Verzeichnis
`algorithms` immer zuerst `git pull` ausführen.

## Häufige Probleme

- `Permission denied (publickey)`: Prüfe, ob du wirklich den Inhalt von
  `id_ed25519.pub` bei GitLab hinterlegt hast. Teste danach erneut mit
  `ssh -T git@git.nhcham.org`.
- Dein Algorithmus erscheint nicht: Die Datei muss in einem eigenen Ordner
  liegen (`algorithms/DEIN_NAME/datei.dart`) und der Dateiname darf nur
  Buchstaben, Ziffern und `_` enthalten.
- Oben rechts steht **files with errors**: Ein Klick zeigt alle Dateien der
  Klasse, die gerade nicht übersetzt werden können. Fremde Dateien mit
  Fehlern stören deinen eigenen Algorithmus nicht.
- `Could not listen on 127.0.0.1:8080`: Die App läuft bereits in einem anderen
  Terminal. Beende sie dort mit Strg+C oder starte mit `./run --port 8081`.
- `git push` wird abgelehnt: Überschreibe nichts und frage nach Hilfe beim
  Zusammenführen.

Die technische Projektdokumentation steht in [DEVELOPMENT.md](DEVELOPMENT.md),
Einzelheiten zur Architektur in [DESIGN.md](DESIGN.md).
