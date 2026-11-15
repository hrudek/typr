# Whisper-Hintergrundvorbereitung – Implementierungsbericht

## Stand

Implementierung und Dokumentation vorhanden; lokale Linux-Prüfungen erfolgreich.
Simulator-/Device-/Signaturprüfung auf diesem Linux-Rechner nicht ausgeführt.
PR: https://github.com/hrudek/typr/pull/161 (feature/whisper-background), Labels
`feature`, `infra`, `no-auto-merge`, `needs-human`. Linux-CI für 0618bf9e grün.
Typr review **PASS** und Linux-CI grün auf `2fc39678`; beide vorherigen
nummerierten Befunde behoben. Feature bleibt bis Owner-Capability-/Profilklärung
bewusst ungemergt. Dieser abschließende Tracking-Commit ändert keinen App-Code
und startet die Gates erneut; vor Worker-Abschluss wird auch dessen Ergebnis geprüft.

## Vereinbartes Verhalten

- Installiertes, explizit gewähltes Whisper beim Öffnen automatisch vorbereiten.
- iOS 26: foreground-origin `BGContinuedProcessingTask`, `.fail` statt Warteschlange;
  Ablehnung/ältere iOS-Versionen: begrenzte UIKit-Hintergrundfrist.
- Opportunistische `BGProcessingTask`-Wartung am Strom, ohne Netzanforderung;
  kein automatischer Download, kein Mikrofon, kein Audio-Keepalive.
- Keine Engine-Umschaltung, kein zweites Modell. Foreground und Wartung verwenden
  denselben Controller-Task; neuer Versuch wartet auf nicht unterbrechbare alte
  Core-ML-Aufrufe. Generationen verhindern späte Ready-/Fortschrittsmeldungen.
- Ablauf/System-Abbruch invalidiert Vorbereitung, beendet Laufzeit-Claims und
  erlaubt erneuten Versuch. Force-quit kann keinen finalen Zustand liefern.
- Unbekannter Core-ML-Fortschritt bleibt indeterminiert; echte Stufen im Subtitle,
  nur vollständiger Abschluss meldet 100 %. Kein Zeit-/Post-Update-Versprechen.

## Relevante Änderungen

- `ios/Typr/WhisperBackgroundPreparation.swift`: App-Delegate-Registrierung vor
  Launch-Ende, konkrete eindeutige Continued-IDs unter erlaubtem Wildcard-Präfix,
  `.main`-Handler, Generation/Lease-gebundener Ablauf, genau einmalige Completion,
  UIKit-Fallback und stromgebundene Wartungsplanung. Veraltete Wartungsrequests
  prüfen Präferenz/Installation **vor** Zugriff auf den Shared-Controller.
- `DictationController.swift`, `TyprApp.swift`: Produktions-Launch-Vorbereitung bis
  aktive Szene verschoben (auch andere Engines dürfen auf veraltetem Maintenance-
  Wake nicht implizit laden); gemeinsamer Single-flight-Pfad und Lifecycle-Hooks.
- `WhisperTranscriber.swift`: Ressourcenfehler nicht als beschädigter Download
  ausgeben; tatsächliche Integritätsfehler bleiben getrennt.
- `Info.plist` und `project.yml`: erlaubte Task-IDs und `processing`-Modus nur App.
- `SpeechEngineCard.swift`, README, `ios/WhisperBackgroundPreparation.md`: ehrliche
  Hinweise zu automatischer Vorbereitung, Grenzen, Abbruch und erneutem Versuch.

## Apple-API-/Ressourcenprüfung und notwendige Infra-Ausnahme

Apples DocC-JSON für `BGContinuedProcessingTask`, Request, Initializer, Ressourcen,
Registrierung, Strategien und Background Inference wurde direkt von
`developer.apple.com/tutorials/data/documentation/...json` gelesen. Zusätzlich
öffentliche iOS-26-SDK-Header `BGTaskRequest.h`, `BGTaskScheduler.h`, `BGTask.h`
über den SDK-Mirror geprüft. Details/Links im Benutzerdokument.

- Continued Processing ist iOS 26+. Request muss aus aktiver App/Benutzeraktion
  stammen. Öffnen bei bereits gewähltem Modell ist der automatische Vordergrund-
  Auslöser; Wartungsstarts reichen keinen Continued-Request ein.
- `BGTaskScheduler.h` bestätigt ausdrücklich die Ausnahme vom Launch-Deadline
  für Continued-Registrierung. Konkrete UUID-IDs vermeiden doppelte Registrierung
  und verspätete Callbacks können nie einen neuen Lauf übernehmen.
- GPU ist **nicht** vorausgesetzt: Typr verwendet CPU bzw. CPU/Neural Engine,
  keine GPU-Compute-Units, keine `.gpu`-Ressource, kein GPU-Entitlement.
- Aktuelle Apple-Dokumentation nennt ab **iOS 27** das boolesche Entitlement
  `com.apple.developer.background-tasks.continued-processing.inference` für
  **jeden** Neural-Engine-Hintergrundzugriff, unabhängig von Continued Tasks.
  Deshalb App-Entitlement ergänzt. Das ist eine feature-notwendige, nicht
  beiläufige Capability-Änderung; keine Identitätsänderung.
- `.github/typr/signing-entitlements.py` musste entsprechend erweitert werden:
  der vorhandene Signierpfad erzeugt Entitlements aus einer Whitelist, sonst würde
  die neue Berechtigung still verschwinden. Nur App, nie Keyboard/Widgets.
  `provision.py` prüft die Profile fail-closed vor dem Secret-Upload. Diese wenigen
  Infra-Änderungen sind für korrekte Auslieferung wesentlich (PR braucht `infra`).
- Vorhandene Profile wurden nicht gelesen/verändert, Portal und Secrets nicht
  angefasst. Das reale Profil-/Capability-Angebot des Accounts ist unbestätigt.

## Exakter Integrationsblocker / Owner-Aktion

**Nicht ungeprüft ausliefern:** Für iOS 27 braucht das App-Profil Background
Inference. Falls die bestehenden Profile das Entitlement nicht enthalten, wird
Signing nun absichtlich fehlschlagen. Owner muss Capability-Verfügbarkeit im
Developer-Account bestätigen, Background Inference für `dev.rudek.typr` aktivieren
und erforderlichenfalls App-Profile bewusst ersetzen/regenerieren; bestehende
aktive Profile werden sonst vom Provisioning-Helper wiederverwendet. Anschließend
übliche Owner-Provisionierungsbefehle aus `.github/typr/README.md` ausführen und
signierte ANE-Hintergrundvorbereitung prüfen. Falls Apple die Capability für das
Team/Deployment nicht anbietet, ist vor Integration eine Owner-Entscheidung nötig
(z. B. abweichender CPU-only-Pfad statt stiller Performance-/Modelländerung).

PR erhält deshalb `no-auto-merge`/`needs-human`. Dies ist **kein** Warten auf
Simulator-Tests, sondern ein eigenständiger neuer Signatur-/Capability-Blocker.
Nach Klärung kleine PR unmittelbar integrieren; Simulator bleibt Post-Merge-Lane.

## Tests und Prüfungen

Geschrieben, hier **nicht ausgeführt**: acht Simulatorfälle als Erweiterung von
`SpeechEngineSelectionTests` mit Fake-Engines/Fake-Runtime: deferred launch und
Single-flight, fehlende Installation/andere Auswahl, Ablauf plus langsamer alter
Core-ML-Aufruf und verspäteter Callback, Backgrounding ohne Audio, Wartung mit
gewählter Sprache, Ressourcenfehler ohne Fallback/Redownload, Enginewechsel mit
staler Expiration, außerdem kein anderer Engine-Load auf Background-only-Launch.
Simulator beweist keine echte Scheduler-/ANE-Funktion.

Lokal ausgeführt:
- `python3 -m unittest discover -s .github/typr/tests -v`: final 88 Tests grün,
  einschließlich App-only-Entitlement und fehlender/gestrippter Capability.
- `python3 -m unittest discover -s ios/tools/dictation_log/tests -v`: 25 grün.
- `bash -n` für alle `.github/typr/*.sh`: grün.
- `shellcheck -x -P .github/typr .github/typr/*.sh`: grün.
- `go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.11 -color -ignore SC2016
  -ignore SC2129 .github/workflows/typr-*.yml`: grün mit installiertem Go 1.27.3
  explizit im PATH. Erster Versuch über nicht konfigurierten mise-Shim fehlte
  (`No version is set for shim: go`), danach unverändert erfolgreich wiederholt.
- `git diff --check`: grün vor erstem Commit; finale Scope-Prüfung folgt.

Offen: Swift/iOS-Build (kein Apple-SDK/Xcode hier), Simulatorlauf, signierter
Gerätetest iOS 26/27+, UIKit-Fallback auf iOS 18–25, System-Live-Activity,
Background App Refresh/Lock/Force-quit, echte Ressourcenablehnung und Profile.

## Review-Verlauf

- Commit `0618bf9e`: Typr review **FIX**, Befund 1: neue Enum-Case
  `preparationFailed` fehlte im exhaustiven Switch von `DictationLogASRFailure`.
  Behoben als `.modelNotReady`, neue Klassifikationsassertion in
  `WhisperTranscriberTests`. Andere Enum-Nutzungen gezielt nachgeprüft.
- Scope lokal mit `LABELS=infra bash .github/typr/scope.sh origin/main HEAD` grün
  (17 Dateien beim ersten Commit). Linux-CI des PR ebenfalls grün.
- Commit `0bab8e3b`: Typr review **FIX**, Befund 1: UIKit-Expiration durfte
  `endBackgroundTask` nicht erst in einem asynchronen MainActor-Task ausführen.
  Apples `beginBackgroundTask(withName:expirationHandler:)`-DocC direkt geprüft:
  Handler wird synchron auf dem Main Thread aufgerufen, Task muss vor Rückkehr
  explizit beendet werden. Korrigiert zu synchronem `MainActor.assumeIsolated`;
  `expire` → `finish` → `endGrace` läuft jetzt vollständig vor Handler-Rückkehr.
  Reale UIKit-Expiration wurde hier nicht ausgeführt (Linux).
- Commit `2fc39678`: Typr review **PASS — nothing to fix**, Linux-CI grün.
  Review bestätigt beide Fixes und die eigenständige Owner-Provisionierungssperre.
  Run: https://github.com/hrudek/typr/actions/runs/43714605529 .
- Finale Tracking-Aktualisierung wird gepusht und deren Linux-/Review-Gates vor
  Rückmeldung erneut abgewartet, ohne auf Simulator zu warten. Worktree wird sauber
  übergeben. Keine Profile, Secrets oder Portalzustände wurden verändert.
