# Vendored Java tools

| Package | Version | Source | Used for |
| --- | --- | --- | --- |
| google-java-format | 1.35.0 | github.com/google/google-java-format/releases (`-all-deps.jar`) | Format button on JDK 21 and newer |
| google-java-format | 1.28.0 | github.com/google/google-java-format/releases (`-all-deps.jar`) | Format button on JDK 17 to 20 |

google-java-format uses the internals of the JDK's compiler, so its releases
follow the JDK: 1.28.0 is the newest that formats on JDK 17 (later releases
need JDK 21), and newer JDKs need recent releases. The daemon loads the newest
jar that the running JDK meets (`JavaFormatter.java` next to `Daemon.java`)
and falls back to the older one if it cannot start; both are tested on JDK 17,
21 and 25. It uses AOSP style (four spaces) and needs the `--add-exports`
flags in `tool/languages.dart`. Everything else uses only the JDK. The license
is in `LICENSES/`.
