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

Starte die App in einem Terminal:

```bash
cd ~/sorting-sandbox
./run
```

Der Browser öffnet sich automatisch. Lasse dieses Terminal geöffnet, solange
du mit der App arbeitest. Für deinen Quelltext und die Git-Befehle öffnest du
ein zweites Terminal.

## 6. Deinen Algorithmus hinzufügen

Wechsle im zweiten Terminal in das gemeinsame Repository und hole zuerst die
neuesten Änderungen der Klasse:

```bash
cd ~/sorting-sandbox/algorithms
git pull
```

Unter `algorithms/` bekommt jede Person einen eigenen Ordner. Du kannst das
vorhandene Beispiel `nh_cham/bubble_sort.dart` als Ausgangspunkt kopieren.
Ersetze `DEIN_NAME` durch deinen vereinbarten Namen oder Benutzernamen:

```bash
mkdir -p DEIN_NAME
cp nh_cham/bubble_sort.dart DEIN_NAME/bubble_sort.dart
```

Öffne die kopierte Datei im Editor. Das Beispiel sieht so aus:

```dart
import 'package:sorting_sandbox_api/sorting_sandbox_api.dart';

class BubbleSort extends SortingAlgorithm {
  get name => 'Bubble Sort';
  get author => 'nh_cham';
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

Ändere mindestens den Autor zu deinem eigenen Namen:

```dart
get author => 'DEIN_NAME';
```

Du kannst außerdem `name`, `color` und natürlich den Sortieralgorithmus ändern.
Der Bubble Sort ist absichtlich noch nicht vollständig optimiert: Später kannst
du zum Beispiel untersuchen, ob beide Schleifen wirklich immer so weit laufen
müssen.

Sobald du die Datei speicherst, prüft die laufende App sie automatisch. Bei
einem Fehler erscheint im Terminal eine Diagnose. Nach der Korrektur taucht
der Algorithmus ohne Neustart wieder in der App auf.

## 7. Deinen Algorithmus veröffentlichen

Bleibe im zweiten Terminal im Verzeichnis
`~/sorting-sandbox/algorithms`. Prüfe zuerst deine Änderungen:

```bash
git status
```

Füge nur deine eigene Datei hinzu. Ersetze wieder `DEIN_NAME`:

```bash
git add DEIN_NAME/bubble_sort.dart
git commit -m "Add bubble sort by DEIN_NAME"
git push
```

Nach dem erfolgreichen `push` können alle anderen deinen Algorithmus mit
`git pull` erhalten.

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

## 9. Eine Android-APK bauen

Speichere, committe und pushe zuerst deine Arbeit. Beende danach die laufende
App im ersten Terminal mit Strg+C.

Der APK-Bau benötigt deutlich mehr Arbeitsspeicher und Prozesse als die
Web-App. Starte deshalb am besten den Workspace neu, bevor du die APK baust.
Das hilft besonders dann, wenn die App vorher lange gelaufen ist oder ein
früherer Build wegen fehlender Ressourcen abgebrochen wurde.

Öffne nach dem Neustart ein Terminal, aktualisiere beide Repositories und starte
den Build:

```bash
cd ~/sorting-sandbox
git pull
cd algorithms
git pull
cd ..
./build-apk
```

Der Build kann einige Minuten dauern. Die fertige APK enthält den aktuellen
Stand aller Algorithmen und liegt anschließend hier:

```text
build/app/outputs/flutter-apk/app-release.apk
```

Du kannst die Datei im Datei-Explorer des Workspace per Rechtsklick
herunterladen.

## Häufige Probleme

- `Permission denied (publickey)`: Prüfe, ob du wirklich den Inhalt von
  `id_ed25519.pub` bei GitLab hinterlegt hast. Teste danach erneut mit
  `ssh -T git@git.nhcham.org`.
- Dein Algorithmus erscheint nicht: Suche im Terminal mit `./run` nach der
  Fehlermeldung und korrigiere die genannte Dart-Datei.
- `git push` wird abgelehnt: Überschreibe nichts und frage nach Hilfe beim
  Zusammenführen.
- Der APK-Build scheitert wegen Ressourcen: Beende `./run`, starte den
  Workspace neu und führe anschließend nur den APK-Build aus.

Die bisherige technische Projektdokumentation steht in
[DEVELOPMENT.md](DEVELOPMENT.md). Einzelheiten zur Architektur stehen in
[DESIGN.md](DESIGN.md).
