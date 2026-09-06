# Plan: UI- und Sync-Performance verbessern

Stand: 5. September 2026<br>
Status: Implementiert und automatisiert geprüft; manuelle UI-/LAN-Gesamtabnahme offen

## Umsetzungsstand vom 5. September 2026

- Phasen 1–4 sind im Code umgesetzt. Die Bildaufbereitung ist jetzt bereits
  Teil des einzigen ausgehenden Bildvorgangs pro Peer; währenddessen gibt es
  keine weitere Vorbereitung/Warteschlange für diesen Peer. Höchstens zwei
  Konvertierungen laufen gleichzeitig. Deaktivierung verwirft auch vorbereitete
  Arbeit; Reaktivierung belebt alte Aufträge nicht wieder.
- Die Netzwerk-Queue verwaltet Zustände und eine begrenzte Inbox pro Verbindung.
  Clipboard-Imports laufen geordnet, Dateiarbeit auf einer separaten seriellen
  Queue, UI-Übernahmen asynchron auf dem Main Thread. Kontrolle/Abbruch kann
  laufende Arbeit ungültig machen. Bereits am Main Thread zugelassene Imports
  werden nicht rückgängig gemacht.
- Codec-, Lebenszyklus-, Thumbnail-, Engine-, TLS- und Identitätstests bestehen.
  Der unveränderte SRC hat im Offline-Cross-Codec-Test Text und mehrteilige
  PNG-/JPEG-Bilder bytegenau geprüft und für Floatcut neu kodiert.
- Phase 5 ist untersucht: Bei 50 MiB synthetischer Bildhistorie liegt die
  Gesamtdauer der gemessenen Saves bei 13–24 ms. Die dominante Arbeit ist
  `setObject`, nicht der Snapshot-Aufbau oder `synchronize`. Die Persistenz
  bleibt aus Gründen der unveränderten Speicherzusagen vorerst unverändert.
  Eine asynchrone Persistenz ist als Folgearbeit dokumentiert, nicht als erledigt.
- `dist/Floatcut.app` wird als Universal-Bundle mit Version 4.0 und bestehender
  lokaler Signieridentität erstellt. Keine Installation, kein App-Neustart,
  kein Commit und kein Push im Rahmen dieser Umsetzung.
- Offen bleiben Live-Messungen zwischen zwei Geräten, visuelle UI-/Handoff-
  Prüfungen und umfassende Integrationstests der Netzwerk-Zustandswechsel.
  Der Offline-SRC-Test ersetzt diese nicht. Nicht angekreuzte Abnahmepunkte
  bleiben offen; der gesamte Plan wird deshalb nicht als vollständig abgenommen
  bezeichnet.

Ergebnisse und Reproduktionsbefehle:
[UI-/Sync-Performance-Messungen](../docs/ui-sync-performance-messungen.md).

## 1. Ziel und Abgrenzung

Floatcut soll bei großen Bild-Clips, mehreren verbundenen Geräten und beim
Durchblättern der Zwischenablage flüssiger reagieren. Unnötige Verarbeitung
soll entfallen, ohne Produktfunktionen, Datenschutz, Datenhaltbarkeit oder
Kompatibilität mit dem Sync Reference Client (SRC) zu verändern.

Die Ansatzpunkte stammen aus einer Codeprüfung. Ihr tatsächlicher Anteil an
Latenz, CPU-Last und Speicherverbrauch ist noch nicht gemessen. Es werden
deshalb keine prozentualen Beschleunigungen zugesagt.

Dieser Plan ergänzt den
[V2-Implementierungsplan](clipboard-p2p-sync-v2-implementierungsplan.md).
Normativ bleiben die [V2-Spezifikation](../docs/Protocol/floatcut-sync-v2.md)
und die zugehörigen Schemas, Fixtures und Konformitätstests. Der Plan umfasst
keine neue Protokollversion und keine Änderungen am eigenständigen SRC-Repo.

## 2. Verbindliche Leitplanken

- Clipboard-Polling einschließlich der Erkennung externer Änderungen/Handoff
  erhalten. Keine Umstellung auf ausschließlich Hotkeys oder Copy-Ereignisse.
- Text, Bilder, Favoriten, Suche, Sortierung und Sync-Markierungen unverändert
  behandeln. Bestehende Lazy-Listen, Caches und gebündelte Updates erhalten.
- Identität, Zertifikate, Pins, Pairings, Widerrufe und lokale Peer-Einstellungen
  weder zurücksetzen noch migrieren.
- Der Bildschalter pro Peer beeinflusst nur das Senden. Ausschalten muss
  weiterhin laufenden Versand abbrechen, nicht den Empfang.
- Keine Offline-Warteschlange und kein späteres Nachliefern ausgelassener Clips.
- TLS, Hashprüfungen, Größenlimits, Zustandsprüfungen und Replay-Schutz bleiben
  wirksam. Keine eingehende Prüfung für mehr Geschwindigkeit entfernen.
- `applied` erst nach erfolgreicher Clipboard-/Verlaufsübernahme bestätigen;
  eine eingeplante Hintergrundaufgabe ist noch keine erfolgreiche Übernahme.
- Reihenfolge und Fehlerverhalten auf einer Verbindung erhalten. Parallelität
  zwischen Peers darf keine doppelten oder verspätet angewendeten Clips erzeugen.
- Keine Versionsänderung, kein Commit und kein Push als Teil der Planung.

## 3. Priorisierung und Reihenfolge

| Phase | Arbeit | Priorität | Erwarteter Nutzen |
| --- | --- | --- | --- |
| 0 | Reproduzierbare Ausgangsmessung | Voraussetzung | Engpässe und Regressionen nachweisen |
| 1 | Netzwerk, Bild-I/O und UI entkoppeln | Hoch | Weniger gegenseitige Blockierung |
| 2 | Doppelte Codec-/Hash-Arbeit vermeiden | Hoch | Weniger CPU-Arbeit, besonders bei mehreren Peers |
| 3 | Bildaufbereitung nur für mögliche Empfänger | Hoch, begrenzter Aufwand | Unnötige Konvertierungen vermeiden |
| 4 | Bezel-Vorschauen asynchron erzeugen | Mittel | Flüssigeres Durchblättern großer Bilder |
| 5 | Speicherung großer Bildhistorien untersuchen | Messungsabhängig | Mögliche UI-Pausen beim Speichern reduzieren |
| 6 | Gesamtabnahme und dokumentierter Vergleich | Abschluss | Funktion und Kompatibilität absichern |

Nach jeder Phase isoliert testen und messen. Phase 5 ist zunächst eine
Untersuchung, keine pauschale Freigabe für ein neues Speicherformat.

## 4. Phase 0: Ausgangsmessung

- [x] Den tatsächlich vorliegenden Arbeitsstand dokumentieren: Commit,
  relevante uncommittete Änderungen, Build-Konfiguration, Signierung, macOS,
  Hardware, Netzwerk und SRC-Revision. `HEAD` allein genügt im aktuellen
  Arbeitsbaum nicht als Referenz.
- [x] Bestehende Engine-, Protokoll-, TLS- und Identitätstests ausführen.
- [x] Nur synthetische Test-Clips und separate Testzustände verwenden.
  Produktive Zwischenablage, Historie und Pairings nicht für Benchmarks leeren.
- [ ] Vergleichbare Release-Builds messen; bestehende Signieridentität erhalten.
  Verbose-Logging im Hauptvergleich ausschalten und dessen Zusatzkosten separat
  erfassen. Logs enthalten keine Clip-Inhalte, Bilddaten oder Geheimnisse.
- [ ] Messpunkte für Konvertierung, Hashing, Codec, Netzwerk-Wartezeit,
  Bildvalidierung, UI-Übernahme und abschließendes ACK ergänzen, soweit noch
  nicht vorhanden. Monotone Zeitmessung verwenden.
- [ ] UI-Reaktion, Main-Thread-Auslastung, CPU und Spitzenspeicher erfassen.
  End-to-End-Latenz lokal vom Versandstart bis zum abschließenden ACK messen;
  keine ungesicherten Differenzen zwischen Uhren verschiedener Geräte bilden.

Testszenarien: kurze und große Texte einschließlich JSON-Escaping; kleine,
mehrere MiB große und grenznahe gültige PNG/JPEG-Bilder; TIFF-Konvertierung;
kein Empfänger; ausschließlich für Bilder gesperrte Peers; ein und mehrere
aktive Peers; gleichzeitiger Empfang/Versand; kalter und warmer Vorschau-Cache;
umfangreiche Historie innerhalb unterstützter Grenzen. Bilddimensionen und
Dateigröße separat variieren.

Wiederholungen und Rohwerte festhalten, mindestens Median und Spannweite,
bei ausreichend vielen Wiederholungen auch p95. LAN-Tests auf zwei Geräten
von lokalen SRC-Tests auf demselben Mac unterscheiden. Signifikante Gewinne
müssen größer als die beobachtete Messstreuung sein.

## 5. Phase 1: Gemeinsame Netzwerk-Verarbeitung entlasten

### Befund

In `Sync/FloatcutSyncCoordinator.swift` verwenden `applyRemoteText` und
`applyRemoteImage` eine synchrone Übergabe an den Main Thread. Der gemeinsame
Netzwerkpfad wartet dadurch auf die UI. `handleImageChunk` und
`handleImageCommit` führen zudem Dateiarbeit auf diesem Verarbeitungspfad aus.

### Umsetzung

- [x] Thread-Zuständigkeiten und den Lebenszyklus eines Transfers ausdrücklich
  festlegen. Verbindungszustände bleiben auf ihrer zuständigen seriellen Queue.
- [x] Dateiarbeit und Bildvalidierung auf begrenzte Worker-Verarbeitung
  auslagern. Chunk-Reihenfolge pro Transfer erhalten; Dateihandles und Hasher
  niemals gleichzeitig aus mehreren Queues verändern.
- [x] UI-Übernahme über eine asynchrone Completion abbilden. Clipboard- und
  UI-Zugriffe bleiben auf dem Main Thread; das Ergebnis geht zurück an die
  Verbindungs-Queue. Kein synchrones gegenseitiges Warten einführen.
- [x] Ausstehende Verarbeitung pro Verbindung explizit modellieren. Spätere
  Frames dürfen ausstehende Imports nicht unkontrolliert überholen. Abbruch,
  Widerruf und Deaktivierung müssen dennoch rechtzeitig verarbeitet werden.
- [x] Transfer-/Sitzungstoken verwenden: Nach Stop, Reconnect, Widerruf oder
  Abbruch dürfen alte Worker-Completions weder importieren noch ACKs senden.
- [x] Temporäre und validierte Dateien bis zum Abschluss ihrer Verbraucher
  erhalten und danach auf allen Erfolgs-/Fehlerpfaden bereinigen. Bestehende
  `defer`-Lebensdauern nicht ungeprüft in asynchrone Abläufe übernehmen.
- [x] Ausstehende Aufgaben und Datenmengen begrenzen; Backpressure vorsehen.
  Unbegrenztes Einstellen aller Bildblöcke in eine Worker-Queue ist keine Lösung.

### Abnahme

- [ ] Ein Peer mit großem Bild blockiert Text, Keepalive und UI anderer Peers
  nicht während seiner Dateiarbeit oder beim Warten auf UI-Übernahme.
- [ ] ACK-Status, Reihenfolge, Duplikaterkennung, Timeouts und Importhäufigkeit
  stimmen mit dem bisherigen Vertrag überein.
- [ ] Abbruch während Schreiben, Validieren und UI-Übergabe testen, ebenso
  Schreibfehler und Verbindungswechsel. Keine Dateilecks oder Deadlocks.

## 6. Phase 2: Codec und Bild-Fan-out effizienter machen

### Befund

`FloatcutSyncCodec.encode` serialisiert eine Nachricht und ruft anschließend
erneut `decodePayload` auf. Bildblöcke werden dabei nochmals dekodiert und
geprüft. `beginImageSend` berechnet den Gesamtbild-Hash für jeden Empfänger;
`handleImageChunk` dekodiert bereits im Codec geprüftes Base64 erneut.

### Umsetzung

- [x] Gemeinsame fachliche Validierung von der Prüfung empfangener JSON-Bytes
  trennen. Lokal erzeugte Nachrichten vor dem Serialisieren validieren,
  anschließend das tatsächliche Frame-Limit einschließlich Escaping prüfen.
- [x] Den vollständigen strikten Empfangspfad erhalten: unter anderem UTF-8,
  JSON-Struktur, doppelte Schlüssel, Feldtypen, Base64-Kanonizität, Hashes und
  Größenlimits. Keine frei erreichbare ungeprüfte Encoder-Abkürzung einführen.
- [x] Validierte dekodierte Chunk-Daten intern weiterreichen, statt im Handler
  erneut Base64 zu dekodieren. Metadaten und Bytes müssen zusammengehören.
- [x] Unveränderliche Bild-Metadaten einschließlich Gesamt-Hash einmal pro
  lokalem Clip vorberechnen und unter den tatsächlich berechtigten Peers teilen.
- [x] Wiederverwendung von Chunk-Hash/Base64 nur bei nachgewiesenem Zusatznutzen
  und begrenztem Speicher vorsehen; nicht vorsorglich alle JSON-Frames vorhalten.
- [x] Pro-Peer-Abbruch und unabhängigen Fortschritt beibehalten. Bestehendes
  `.contentProcessed` ist keine Remote-Bestätigung pro Chunk und darf in der
  Analyse nicht als ein Netzwerk-Roundtrip pro Bildblock behandelt werden.

### Abnahme

- [x] Bisherige ungültige Nachrichten bleiben abgelehnt; gültige Nachrichten
  erfüllen dieselben Schemas und Größenlimits wie zuvor.
- [x] Encode/Decode-Roundtrips und Negativtests für Bildblöcke, Hashfehler,
  Escape-bedingte Frame-Übergröße und Zustandsfehler ergänzen.
- [ ] SRC bestätigt PNG/JPEG-Transfers mit identischen Inhalts-Hashes.
  Ein langsamer oder abbrechender Peer beeinträchtigt andere Empfänger nicht.
- [ ] Weniger Hash-/Decode-Aufrufe nachweisen und CPU-/Speicherwerte vergleichen.

## 7. Phase 3: Unnötige Bildaufbereitung überspringen

### Befund

`sendLocalImage` ruft `normalizedImage` auf, bevor verbundenen Peers und ihrer
Bildfreigabe nachgegangen wird. Dadurch kann insbesondere TIFF→PNG ohne
einen einzigen berechtigten Empfänger ausgeführt werden.

### Umsetzung und Abnahme

- [x] Vor der Hintergrundaufbereitung auf der Netzwerk-Queue prüfen, ob es
  überhaupt vertrauenswürdige, aktive, online verfügbare Bildempfänger gibt.
  Andernfalls ohne Konvertierung oder Hashberechnung zurückkehren.
- [x] Nach der Aufbereitung Verbindung, Vertrauen, Sync-/Peer-Aktivierung und
  Bildfreigabe erneut prüfen. Ausschalten während der Konvertierung darf keinen
  anschließenden Versand ermöglichen.
- [x] Für den laufenden Versuch Empfänger/Sitzungen erfassen; keine Aufgabe
  über einen Reconnect hinweg nachliefern oder in eine Offline-Queue umwandeln.
- [ ] Für jeden Fall prüfen: keine Empfänger, nur gesperrte Empfänger,
  gemischte Freigaben sowie Disconnect/Deaktivierung während Konvertierung.
- [ ] Lokale Speicherung und Vorschau des Bildes funktionieren auch ohne
  Versand. Empfang und Text-Sync bleiben unangetastet.

## 8. Phase 4: Bezel-Vorschauen ohne synchrone Bilddekodierung

### Befund

`AppController.m`, Methode `previewImageForClipping:size:`, lädt und zeichnet
bei einem Cache-Miss synchron aus dem Originalbild. Die Statusliste nutzt
bereits ImageIO-Thumbnails im Hintergrund und einen gemeinsamen Cache in
`FloatcutStatusPopoverController.swift`.

### Umsetzung und Abnahme

- [x] Eine wiederverwendbare, aus Objective-C erreichbare Thumbnail-Erzeugung
  nutzen. Nur die benötigte Auflösung unter Berücksichtigung des Displays laden.
- [x] Gleichzeitig laufende Dekodierungen begrenzen und identische noch
  laufende Anfragen zusammenfassen. Veraltete Ergebnisse nicht anzeigen.
- [x] Cache-Schlüssel aus stabiler Clip-ID, Zielauflösung und relevanten
  Darstellungsparametern bilden. Speicher-Kosten aus tatsächlichen Pixelmaßen
  beziehungsweise Bytes pro Zeile berechnen, nicht nur aus logischen Punkten.
- [x] UI-Zuweisung auf dem Main Thread; beim Schließen, schnellen Wechseln
  oder Löschen darf kein fremdes/veraltetes Vorschaubild aufblitzen.
- [ ] Bestehende Skalierung, Orientierung, Transparenz, Layout und Auswahl
  erhalten. Kalten/warmen Cache und schnelle Navigation mit großen Bildern
  messen; Liste und Suche ebenfalls auf Regressionen prüfen.

## 9. Phase 5: Persistenz zunächst gezielt messen

### Befund

`FloatcutOperator.m` bündelt Speicheranforderungen bereits zeitlich und nutzt
unveränderte Teilbestände wieder. Für geänderte Listen werden dennoch alle
Clips einschließlich `ImageData` ins Preferences-Dictionary übernommen;
`saveEngine` ruft anschließend `synchronize` auf.

### Untersuchung und Entscheidungspunkt

- [x] Snapshot-Aufbau, Preferences-Übergabe und Synchronisierung getrennt
  messen. Kleine Text- und große Bildhistorien vergleichen.
- [ ] Nur bei belegter relevanter UI-Blockierung eine konkrete Änderung
  ausarbeiten. Vorzugsweise serielle Verarbeitung unveränderlicher Snapshots
  untersuchen, ohne das bestehende Speicherformat zu verändern.
- [ ] Vor Umsetzung Eigentümerschaft, Snapshot-Versionierung, Fehlerbehandlung
  und abschließendes Speichern beim Beenden/Migrationsneustart festlegen.
  Ältere asynchrone Saves dürfen niemals jüngere Daten überschreiben.
- [x] `synchronize` nicht pauschal entfernen und das bisherige Verlustfenster
  nicht vergrößern. Shutdown-, Neustart- und Wiederherstellungstests vorsehen.
- [x] Falls separate Bilddateien oder eine Datenbank nötig erscheinen:
  Untersuchung dokumentieren und gesonderte Freigabe für Speicherformat,
  Migration, Wiederherstellung und Aufbewahrung einholen. Nicht stillschweigend
  als Performance-Detail einführen.

## 10. Phase 6: Gesamtabnahme und Übergabe

- [x] `bash Scripts/test-engine.sh`
- [x] `bash Scripts/test-sync-protocol.sh`
- [x] `bash Scripts/test-sync-tls.sh`
- [x] `bash Scripts/test-sync-identity.sh`
- [x] `bash Scripts/test-sync-work.sh`
- [x] `bash Scripts/test-sync-src-codec.sh` (offline, kein Netzwerk-Praxistest)
- [x] `bash Scripts/test-sync-performance.sh`
- [x] `bash Scripts/test-storage-performance.sh`
- [x] Gezielte neue Nebenläufigkeits-/Lebenszyklustests ergänzen; bestehende
  Skripte allein decken asynchrone Transfer-Rennen nicht ausreichend ab.
- [ ] SRC-Interoperabilität in beide Richtungen mit Text, PNG und JPEG prüfen,
  soweit der SRC den jeweiligen Pfad unterstützt. Nicht unterstützte SRC-Pfade
  mit zweiter Floatcut-Instanz oder Test-Harness prüfen und kenntlich machen.
- [ ] Bildfreigabe aus/ein, Unpair, Widerruf, ausgeschalteten Sync, pausierte
  Zwischenablage, Reconnect sowie fehlerhafte/abgebrochene Transfers prüfen.
- [ ] UI-Prüfung: Menü, Suche, Favoriten, Bezel, Sync-Rahmen und Einstellungen;
  externe Clipboard-Änderungen einschließlich Handoff weiterhin erkennen.
- [x] Nach Freigabe der Implementierung Release-Bundle mit dem bestehenden
  `bash Scripts/package-app.sh` nach `dist/Floatcut.app` erstellen. Version und
  Signieridentität erhalten; Signatur prüfen. Installation/Start einer laufenden
  Benutzer-App und Tests mit externen Berechtigungen vorher abstimmen.
- [x] Vorher-/Nachher-Werte, Testbedingungen, nicht reproduzierte Probleme und
  verbleibende Grenzen in `docs/ui-sync-performance-messungen.md` dokumentieren.
  Fehlende Messungen ausdrücklich als offen markieren.

Abgeschlossen ist die Umsetzung, wenn die priorisierten Änderungen getestet
sind, der Performance-Vergleich vorliegt und Funktion, Protokollkompatibilität
und Datenhaltbarkeit keine festgestellten Regressionen zeigen. Phase 5 darf
mit einem begründeten Ergebnis „keine Änderung erforderlich“ enden.

## 11. Hinweise für die Umsetzung

- Vor Beginn diesen Plan, den aktuellen Code und die geltenden lokalen
  Arbeitsanweisungen lesen. Methodenbezeichnungen sind Orientierung; bestehende
  Pläne können historische Bestandsbeschreibungen enthalten.
- Der Arbeitsbaum enthält bereits umfangreiche Änderungen. Diese erhalten;
  keine Rücksetzungen oder Vermischung mit fremden Änderungen vornehmen.
- Kleine, getrennt prüfbare Arbeitspakete umsetzen. Bei jeder Optimierung
  zuerst den unveränderten Verhaltensvertrag mit Tests absichern.
- Bei notwendiger Produkt-/Protokolländerung stoppen und Entscheidung einholen.
  Kein Re-Pairing oder Identitätsreset als Abkürzung zur Testbereinigung.
- Fortschritt und Messergebnisse im Plan nachführen. Nicht ausgeführte Tests
  nicht als bestanden markieren; Commit und Push nur nach ausdrücklichem Auftrag.
