# Floatcut 4.0: Identitätswechsel, lokale Datenmigration und Entfernung von iCloud

## Ziel

Floatcut wird mit Version 4.0 vollständig als eigenständige, ausschließlich
lokal arbeitende Anwendung geführt. Die aktive Produktidentität wechselt von
der bisherigen Flycut-Bundle-ID auf Floatcut:

```text
Alt:  com.generalarcade.flycut
Neu: de.meierkarsten.floatcut
```

Bestehende Einstellungen, Zwischenablageeinträge, Favoriten und Hotkeys werden
über eine manuell gestartete Migration übernommen. Der alte Flycut-Speicher
bleibt als lokale Rückfallkopie unverändert erhalten. Sämtliche aktive
iCloud-/CloudKit-Infrastruktur wird aus Floatcut entfernt.

## Verbindliche Entscheidungen

- Marketing- und Bundle-Version werden auf `4.0` gesetzt.
- Das neue Preferences-Ziel ist
  `~/Library/Preferences/de.meierkarsten.floatcut.plist`.
- Quellen der Migration sind die alte Preferences-Domain und gegebenenfalls
  der ehemalige Sandbox-Speicher:

  ```text
  ~/Library/Preferences/com.generalarcade.flycut.plist
  ~/Library/Containers/com.generalarcade.flycut/Data/Library/Preferences/com.generalarcade.flycut.plist
  ```

- Die Migration wird ausschließlich vom Benutzer in den Einstellungen
  gestartet; es gibt keinen automatischen Import beim ersten Start.
- Floatcut beendet, verändert oder entfernt eine alte Flycut-/Floatcut-App
  nicht selbstständig.
- Floatcut verändert oder entfernt das alte Anmeldeobjekt nicht. Die App führt
  den Benutzer zu den Anmeldeobjekten in den Systemeinstellungen.
- Ein Button zum Anzeigen der alten App im Finder ist nicht vorgesehen.
- Die alten Preferences werden weder verändert noch gelöscht.
- Floatcut wird lokal beziehungsweise ad hoc signiert, nicht mit einer
  Developer-ID signiert und nicht notarisiert.
- Frühere Flycut-/Jumpcut-Nennungen in Lizenz, Danksagungen und
  Herkunftshinweisen bleiben aus historischen und rechtlichen Gründen erhalten.

## 1. Ausgangszustand absichern

- Aktuellen Regressionstest und Release-Build als Vergleichsbasis ausführen.
- Eine Testkopie der alten Preferences mit folgenden Inhalten anlegen:
  - Texte und Bilder,
  - Standardverlauf und Favoriten,
  - Einträge mit und ohne stabile Kennung,
  - Hotkeys,
  - Anzeige-, Speicher-, Sicherheits- und Autostarteinstellungen.
- Bestehendes Verhalten für Polling, Bezel, Suche, Favoriten und Persistenz
  dokumentieren.
- Vor Beginn der funktionalen Änderungen den Git-Arbeitsstand prüfen und
  unabhängige lokale Dateien unangetastet lassen.

## 2. Aktive Produktidentität vollständig auf Floatcut umstellen

### Bundle- und Build-Identität

- Haupt-Bundle-ID auf `de.meierkarsten.floatcut` ändern.
- Xcode-Projekt, Scheme, Target und Swift-Modul auf `Floatcut` umstellen.
- Projektdatei von `Flycut.xcodeproj` nach `Floatcut.xcodeproj` umbenennen.
- `PRODUCT_MODULE_NAME`, Produktreferenzen und generierten Swift-Header
  aktualisieren.
- `FLYCUT_MAC` durch `FLOATCUT_MAC` ersetzen.
- Bridging Header, Prefix Header, Entitlements und zugehörige Projektverweise
  auf Floatcut umbenennen.
- Aktive Ressourcen mit `com.generalarcade.flycut` im Dateinamen auf den neuen
  Namensraum umstellen.
- Build-, Test- und Packaging-Skripte sowie den Release-Workflow an das neue
  Projekt und Scheme anpassen.

### Quellcode-Identität

- Aktive `Flycut...`-Klassen, Protokolle, Dateinamen und Tests konsistent auf
  `Floatcut...` umbenennen.
- Objective-C-Imports, Swift-/Objective-C-Brücke, NIB-Verweise und Runtime-Namen
  gemeinsam aktualisieren.
- Benutzeroberfläche, Diagnosemeldungen, Queue-/Notification-Namen und aktive
  Hilfetexte auf Floatcut umstellen.
- Die mechanische Umbenennung in einem getrennten Commit von Migration und
  iCloud-Entfernung halten, damit Fehler und Git-Historie nachvollziehbar
  bleiben.

### Ausnahmen

`com.generalarcade.flycut` beziehungsweise `Flycut` dürfen anschließend nur
noch an diesen Stellen vorkommen:

- als explizite Migrationsquelle,
- bei der Erkennung einer früheren Anwendung,
- in Lizenz-, Copyright- und Herkunftstexten,
- in Links zum ursprünglichen Flycut-Projekt.

## 3. Frühere Installation und laufende Prozesse erkennen

Die bisherige Floatcut-Version 3.2.1 verwendet ebenfalls noch die Bundle-ID
`com.generalarcade.flycut`. Eine Anwendung mit dieser ID darf deshalb in der UI
nicht pauschal als Flycut bezeichnet werden.

- Über `NSWorkspace` nach Anwendungen und laufenden Prozessen mit
  `com.generalarcade.flycut` suchen.
- Relevante Installationsorte umfassen insbesondere `/Applications` und
  `~/Applications`; LaunchServices bleibt die primäre Erkennungsquelle.
- Zusätzlich unabhängig von einer installierten App nach der alten
  Preferences-Domain und dem Sandbox-Speicher suchen.
- Neutrale Formulierung verwenden:

  > Daten einer früheren Flycut-/Floatcut-Version gefunden.

- Bei jedem Start prüfen, ob ein Prozess mit der alten Bundle-ID läuft.
- Bei einem parallelen Prozess eine Warnung anzeigen, da sonst doppelte
  Zwischenablageeinträge, globale Hotkey-Konflikte und konkurrierende
  Einfügevorgänge möglich sind.
- Nur warnen und eine reguläre Benutzeraktion zum Beenden verlangen; Floatcut
  beendet oder erzwingt nichts selbst.
- Eine Migration darf nicht beginnen, solange ein Prozess mit der alten
  Bundle-ID läuft.

## 4. Bedingte Migrationsseite in den Einstellungen

Die SwiftUI-Sidebar erhält den Eintrag `Flycut-/Floatcut-Migration` mit einem
Transfersymbol.

### Sichtbarkeit

Die Seite wird angezeigt, wenn:

- eine frühere Anwendung mit alter Bundle-ID gefunden wurde oder
- die alte Preferences-Domain beziehungsweise der Sandbox-Speicher vorhanden
  ist,
- und die relevante Migration noch nicht erfolgreich abgeschlossen oder
  bewusst ausgeblendet wurde.

Da die alten Preferences erhalten bleiben, darf deren bloße Existenz die Seite
nach erfolgreicher Migration nicht dauerhaft sichtbar halten. Ein Marker in der
neuen Domain steuert den Zustand, beispielsweise:

```text
floatcutPreferencesMigrationVersion = 1
```

Bei einem Fehler oder Abbruch bleibt die Seite sichtbar. Optional kann der
Benutzer den Hinweis mit `Nicht mehr anzeigen` ausblenden, ohne alte Daten zu
verändern.

### Inhalt

Die Seite zeigt ausschließlich Metadaten und Zusammenfassungen, bevor der
Benutzer die Migration startet:

- gefundene Quelle,
- Status einer früheren laufenden Anwendung,
- Anzahl Standard- und Favoriteneinträge,
- vorhandene Einstellungen und Hotkeys,
- Migrations- und Validierungsstatus,
- Hinweis zum alten Anmeldeobjekt.

Vorgesehene Aktionen:

- `Migration prüfen`,
- `Daten nach Floatcut übernehmen`,
- `Anmeldeobjekte öffnen`,
- gegebenenfalls `Nicht mehr anzeigen`.

Ein Button `Im Finder anzeigen` wird nicht implementiert.

## 5. Migrationsquelle sicher lesen

- Migration vor dem Schreiben vollständig validieren.
- Die alte persistente Domain bevorzugt über `NSUserDefaults` beziehungsweise
  `CFPreferences` lesen, damit der aktuelle Stand von `cfprefsd` berücksichtigt
  wird.
- Nicht ausschließlich die Plist-Datei direkt kopieren.
- Den ehemaligen Sandbox-Pfad als zweite Quelle verwenden, wenn die
  unsandboxed Domain fehlt oder keine relevanten Daten enthält.
- Die Registrierung von Standardwerten darf nicht fälschlich als bereits
  vorhandene neue Benutzerdomain gelten. Vorhandensein über
  `persistentDomainForName:` und nicht über `objectForKey:` feststellen.
- Quelle während und nach der Migration niemals schreiben, bereinigen oder
  löschen.
- Beschädigte oder unvollständige Quellen verständlich melden und den Marker
  nicht setzen.

## 6. Zu übernehmende und auszuschließende Daten

### Übernehmen

- Standardverlauf,
- Favoriten,
- Text- und Bilddaten,
- Datentyp, Quellanwendung und Zeitstempel,
- stabile Eintragskennungen,
- Haupt- und Suchhotkey,
- Anzeige-, Menü- und Bezel-Einstellungen,
- Speicher- und Kapazitätseinstellungen,
- Passwort-/Datentypfilter,
- Ordner für manuelles und automatisches Speichern,
- Wunsch, Floatcut beim Anmelden zu starten.

Die Migration arbeitet mit einer Positivliste unterstützter Schlüssel. Dadurch
werden Apple-interne, obsolete und unbekannte Werte nicht blind übernommen.

### Nicht übernehmen

Mindestens folgende Schlüssel bleiben ausgeschlossen:

```text
syncSettingsViaICloud
syncClippingsViaICloud
previousSyncClippingsViaICloud
suppressAccessibilityAlert
sandboxMigrationCompleted
CKPerBootTasks
CKStartupTime
```

`suppressAccessibilityAlert` darf nicht migriert werden, weil Floatcut unter
der neuen Bundle-ID eine neue Bedienungshilfen-Freigabe benötigt.

## 7. Konflikte mit bereits vorhandenen Floatcut-Daten

- Neue Floatcut-Einstellungen nicht stillschweigend überschreiben.
- Fehlende unterstützte Einstellungen aus der alten Domain ergänzen.
- Standardverlauf und Favoriten getrennt zusammenführen.
- Duplikate zuerst anhand stabiler Kennungen erkennen.
- Bei alten Einträgen ohne Kennung ersatzweise Inhalt, Typ, Quelle und
  Zeitstempel vergleichen.
- Kapazitätsgrenzen erst nach der Zusammenführung anwenden.
- Aktuelle Floatcut-Werte bei echten Einstellungskonflikten bevorzugen.
- Vor dem Schreiben eine vollständige neue Zieldomain im Speicher erzeugen und
  validieren.
- Bei zu wenig Speicherplatz oder Schreibfehlern ohne Änderung der Quelle und
  ohne Erfolgsmarker abbrechen.

## 8. Migration aus der laufenden App und sicherer Neustart

Da die Migration aus den geöffneten Einstellungen erfolgt, besitzt Floatcut
bereits einen geladenen In-Memory-Store. Dieser darf beim Beenden die gerade
migrierte Domain nicht wieder überschreiben.

- Vor dem finalen Schreiben Clipboard-Polling und verzögerte Saves anhalten.
- Nach erfolgreichem Schreiben das normale Speichern beim unmittelbar folgenden
  Beenden einmalig unterdrücken.
- Floatcut kontrolliert neu starten.
- Nach dem Neustart `de.meierkarsten.floatcut` laden und Inhalt sowie Marker
  validieren.
- Die Erfolgsmeldung erst nach dieser erfolgreichen Wiederherstellung anzeigen,
  nicht bereits nach dem Schreiben.
- Bei fehlgeschlagener Validierung die neue Domain nicht als abgeschlossen
  markieren und die unveränderte alte Quelle als Rückfalloption benennen.

Beispiel für die Abschlussmeldung:

> Die Daten der früheren Flycut-/Floatcut-Version wurden erfolgreich nach
> Floatcut übernommen. Standardverlauf, Favoriten und unterstützte Einstellungen
> wurden importiert. Die ursprünglichen Preferences bleiben als lokale
> Rückfallkopie erhalten. Die frühere Anwendung kann jetzt manuell entfernt
> werden.

Die Meldung weist zusätzlich darauf hin, dass sensible Clipboard-Inhalte nun in
beiden lokalen Preferences-Domains vorhanden sein können.

## 9. Altes und neues Anmeldeobjekt

- Floatcut greift nicht aktiv in das alte Anmeldeobjekt ein.
- Keine Administratorberechtigung, kein privilegierter Helper, keine direkte
  Bearbeitung der Background-Task-Datenbank und kein `sfltool resetbtm`.
- Die Migrationsseite erklärt das manuelle Deaktivieren unter
  `Systemeinstellungen > Allgemein > Anmeldeobjekte`.
- `SMAppService.openSystemSettingsLoginItems()` für den Button
  `Anmeldeobjekte öffnen` verwenden.
- Der übernommene `loadOnStartup`-Wunsch darf nicht durch eine frühe Statusabfrage
  des noch unregistrierten neuen Floatcut-Service überschrieben werden.
- Nach Migration und Benutzerbestätigung den neuen Main-App-Service unter
  `de.meierkarsten.floatcut` registrieren, sofern Autostart gewünscht ist.
- Autostart erst aktivieren, wenn Floatcut dauerhaft in `/Applications` liegt;
  bei einem späteren Verschieben kann die Registrierung ungültig werden.
- Den alten `FlycutHelper` prüfen. Da der aktuelle Code
  `SMAppService.mainAppService` verwendet, den Legacy-Helper entfernen, wenn er
  keine aktive Funktion mehr besitzt. Falls er wider Erwarten erforderlich ist,
  vollständig als Floatcut-Helper mit neuem Identifier führen.

## 10. iCloud und CloudKit vollständig entfernen

### UI und Preferences

- iCloud-Bereich aus den SwiftUI-Einstellungen entfernen.
- `@AppStorage`-Properties für Einstellungen- und Clipboard-Sync entfernen.
- Delegate-Methoden und Actions für iCloud-Schalter entfernen.
- Englische und deutsche iCloud-Lokalisierungen entfernen.
- Hilfe und aktuelle Projektdokumentation auf ausschließlich lokale Speicherung
  umstellen.

### Controller und Operator

- iCloud-Registrierungsreste und auskommentierte CloudKit-Aufrufe entfernen.
- Remote-Notification-Callbacks und zugehörige Kommentare entfernen.
- `kiCloudId` entfernen.
- `settingsSyncList`, Sync-Zustände und Konfliktbehandlung entfernen.
- Integration-, Merge- und Korrekturlogik löschen, die ausschließlich für
  iCloud existiert.

### Store-Journale

- Einfüge- und Löschjournale entfernen, sofern eine abschließende Referenzprüfung
  bestätigt, dass sie nur der iCloud-Zusammenführung dienen.
- `modifiedSinceLastSaveStore` und die normale lokale Save-Logik ausdrücklich
  beibehalten.
- Sicherstellen, dass `Nie`, `Beim Beenden` und `Nach jedem Eintrag` unverändert
  funktionieren.

### Abhängigkeiten und Dokumentation

- Verweise auf `MJCloudKitUserDefaultsSync` entfernen, wenn kein Code dieser
  Abhängigkeit mehr enthalten ist.
- `.planning`-Dokumentation auf den neuen lokalen Architekturstand bringen.
- Repositoryweit nach `iCloud`, `CloudKit`, `MJCloud`, `syncClippings`,
  `syncSettings` und dem alten Container-Identifier suchen.
- Zulässige historische Erwähnungen von tatsächlich früher verwendeter
  Software getrennt beurteilen.

Das Entfernen der Funktion löscht keine möglicherweise früher in
`iCloud.com.generalarcade.flycut` gespeicherten serverseitigen Daten. Floatcut
greift künftig weder darauf zu noch schreibt es neue Cloud-Daten. Ein späterer
Start der alten App könnte deren alte Synchronisation erneut verwenden; darauf
wird bei Parallel- beziehungsweise Altprozess-Erkennung hingewiesen.

## 11. Berechtigungen und lokale Signierung

- Die neue Bundle-ID wird von macOS als neue Anwendung behandelt.
- Bedienungshilfenstatus beim ersten Start neu prüfen und eine Freigabe unter
  `de.meierkarsten.floatcut` anfordern.
- `suppressAccessibilityAlert` nicht übernehmen.
- `NSAppleEventsUsageDescription` entfernen, sofern die abschließende Prüfung
  bestätigt, dass Floatcut keine Apple-Events-Automation verwendet.
- Das Bundle lokal beziehungsweise ad hoc signieren und die technische
  Gültigkeit mit `codesign --verify --deep --strict` prüfen.
- Keine Developer-ID-, Provisioning- oder Notarisierungsabhängigkeit in den
  lokalen Release-Prozess aufnehmen.

## 12. Gatekeeper dokumentieren

Die Hilfe und Release-Hinweise erklären, dass ein ad-hoc signiertes und nicht
notarisiertes Bundle von Gatekeeper blockiert werden kann.

Empfohlene Reihenfolge:

1. Apples Benutzerweg über
   `Systemeinstellungen > Datenschutz & Sicherheit > Dennoch öffnen`.
2. Optional Sentinel zum Entfernen des Quarantäne-Attributs; dabei auf den
   pausierten Entwicklungsstatus des Projekts hinweisen:
   `https://github.com/alienator88/Sentinel`.
3. Alternativ ausschließlich für das konkrete Floatcut-Bundle:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Floatcut.app"
   ```

Keine globale Gatekeeper-Deaktivierung und insbesondere keine Empfehlung von
`spctl --master-disable` dokumentieren.

Zusätzlich erläutern:

- App vor Aktivierung des Autostarts nach `/Applications` verschieben.
- Nach neuen lokal signierten Builds kann macOS die erneute Freigabe der
  Bedienungshilfen verlangen.
- Nur ein Bundle aus einer vertrauenswürdigen Quelle von der Quarantäne
  ausnehmen.

## 13. Version und Release-Artefakte

- `CFBundleShortVersionString` auf `4.0` setzen.
- `CFBundleVersion` auf `4.0` setzen.
- Helper-Versionen, sofern noch vorhanden, konsistent aktualisieren.
- Ausschließlich `dist/Floatcut.app` erzeugen.
- Gebautes Bundle auf folgende Werte prüfen:

  ```text
  CFBundleDisplayName = Floatcut
  CFBundleIdentifier = de.meierkarsten.floatcut
  CFBundleShortVersionString = 4.0
  CFBundleVersion = 4.0
  ```

- Release-Dokumentation auf Floatcut 4.0, neue Bundle-ID, Datenmigration,
  erneute Bedienungshilfen-Freigabe und Gatekeeper-Hinweise aktualisieren.

## 14. Testmatrix

### Migration

- Keine alte Installation und keine alten Preferences.
- Alte unsandboxed Preferences ohne installierte Alt-App.
- Nur ehemaliger Sandbox-Speicher.
- Bisherige Floatcut-App 3.2.1 mit alter Bundle-ID.
- Alte Anwendung läuft während der Prüfung.
- Alte Anwendung wird nach abgeschlossener Migration erneut gestartet.
- Text-, Bild- und gemischter Verlauf.
- Favoriten mit und ohne stabile Kennungen.
- Leere und sehr große Stores.
- Hotkeys, Ordner-URLs, Filter und Autostart-Wunsch.
- Neue Floatcut-Domain existiert bereits und enthält eigene Daten.
- Beschädigte, unvollständige oder nicht lesbare Quelle.
- Zu wenig Speicherplatz beziehungsweise simulierter Schreibfehler.
- Abbruch vor und nach dem Schreiben.
- Zweiter Start nach erfolgreicher Migration.
- Wiederholter Migrationsversuch erzeugt keine Duplikate.
- Alte Preferences bleiben byteweise beziehungsweise semantisch unverändert.

### Lokale Funktionalität

- Alle bestehenden Engine-Regressionstests.
- Speichern mit `Nie`, `Beim Beenden` und `Nach jedem Eintrag`.
- Standardliste und Favoriten einschließlich Löschen und Verschieben.
- Clipboard-Polling einschließlich Universal Clipboard/Handoff.
- Suche, Menü, Bezel, Hotkeys und Bildvorschauen.
- Start ohne Netzwerk und ohne angemeldetes iCloud-Konto.
- Keine aktiven CloudKit- oder Remote-Notification-Aufrufe.

### Build und Systemintegration

- Debug- und Release-Build über das umbenannte Projekt/Scheme.
- Universal Binary für `arm64` und `x86_64`.
- Plist-Lint und Kontrolle der neuen Bundle-ID.
- Ad-hoc-Signaturprüfung.
- Start aus `/Applications` und aus einem Entwicklungsverzeichnis.
- Bedienungshilfen-Neufreigabe.
- Neuer Floatcut-Autostart und Führung zum alten Anmeldeobjekt.
- Gatekeeper-Anleitung mit einem quarantänisierten Testbundle nachvollziehen.
- Repositoryweite Identitätssuche mit dokumentierter Whitelist historischer
  Flycut-Nennungen.

## 15. Umsetzung und Veröffentlichung

Die Arbeit in getrennten, überprüfbaren Schritten durchführen:

1. Tests und Migrations-Fixtures ergänzen.
2. Migrationsdienst und Altprozess-Erkennung implementieren.
3. Bedingte Migrationsseite und Abschlussführung einbauen.
4. Bundle-ID und Preferences-Domain umstellen.
5. iCloud-/CloudKit-Code vollständig entfernen.
6. Legacy-Helper entfernen oder abschließend umstellen.
7. Aktive Projekt-, Modul-, Klassen- und Ressourcennamen auf Floatcut ändern.
8. Dokumentation und Gatekeeper-Hinweise aktualisieren.
9. Version auf 4.0 setzen.
10. Regressionstests und vollständige Testmatrix ausführen.
11. Universal-AppBundle nach `dist/Floatcut.app` bauen und validieren.
12. Änderungen in logisch getrennten Commits festschreiben und nach erfolgreicher
    Abschlussprüfung auf `remote main` pushen.

## Abnahmekriterien

- Floatcut verwendet zur Laufzeit ausschließlich
  `de.meierkarsten.floatcut`.
- Alte lokale Daten können manuell, verlustfrei und wiederholbar sicher
  übernommen werden.
- Die alte Preferences-Domain bleibt unverändert erhalten.
- Floatcut warnt vor einer parallel laufenden Altversion, greift aber nicht
  aktiv ein.
- Das alte Anmeldeobjekt wird ausschließlich durch Benutzerführung behandelt.
- Die Erfolgsmeldung erscheint erst nach Neustart und erfolgreichem Laden.
- Es existiert keine aktive iCloud-/CloudKit-Funktion oder zugehörige UI mehr.
- Historische Flycut-/Jumpcut-Attribution bleibt korrekt.
- Das lokal signierte Universal-Bundle trägt Version 4.0 und liegt als
  `dist/Floatcut.app` vor.

## 16. Implementierungsstatus (2026-09-01)

Umgesetzt:

- Manuelle, nicht destruktive Datenmigration von
  `com.generalarcade.flycut` nach `de.meierkarsten.floatcut`, inklusive
  getrennter Zusammenführung von Verlauf und Favoriten sowie Verifikation vor
  dem Neustart.
- Bedingte Migrationsseite, Erkennung einer parallel laufenden Altversion,
  Hinführung zu den Anmeldeobjekten und Erfolgsbestätigung nach Neustart.
- Entfernung der iCloud-/CloudKit-Funktion, ihrer Einstellungen,
  Lokalisierungen, Entitlements und Abhängigkeiten.
- Umbenennung von Projekt, Scheme, Modulen, Ressourcen und aktiven Klassen auf
  Floatcut; Bundle-ID und Version sind `de.meierkarsten.floatcut` und `4.0`.
- Ad-hoc-Build-/Release-Konfiguration und Gatekeeper-Dokumentation.

Automatisch geprüft:

- Engine-Regressionstests erfolgreich.
- Universal-Release-Build nach `dist/Floatcut.app` erfolgreich.
- Bundle-Informationen, Plists und Ad-hoc-Signatur erfolgreich geprüft.
- Kein iCloud-/CloudKit-Code und keine alte Bundle-ID im gebauten Bundle.

Für eine Veröffentlichung bleiben die in Abschnitt 14 aufgeführten manuellen
Migrations- und Systemintegrationstests auf einem Rechner mit einer echten
Vorgängerversion auszuführen.
