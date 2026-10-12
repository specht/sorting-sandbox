# Vendored Java tools

| Package | Version | Source | Used for |
| --- | --- | --- | --- |
| google-java-format | 1.35.0 | github.com/google/google-java-format/releases (`-all-deps.jar`) | Format button (AOSP style, four spaces) |

1.35.0 is the newest release that runs on Java 17 (later ones need Java 21).
The daemon (`languages/java/src/__sandbox/Daemon.java`) loads it by reflection
with the `--add-exports` flags it needs (see `tool/languages.dart`); everything
else uses only the JDK. The license is in `LICENSES/`.
