# UI-/Sync-Performance: Umsetzung und Messungen

Datum: 5. September 2026<br>
Bezug: [Optimierungsplan](../plans/ui-sync-performance-optimierungsplan.md)

## Ergebnis und Grenzen

Die priorisierten Codeänderungen sind umgesetzt; die automatisierten Tests
und der Release-Build bestehen. Die Encoder-Messung zeigt weniger CPU-Zeit
für Bildblöcke und große Texte. Das ist **kein Nachweis einer entsprechend
höheren LAN-Übertragungsrate**. UI-Reaktionszeit, Energieverbrauch, Peak-RAM
und Live-End-to-End-Latenz zwischen zwei Geräten sind noch nicht gemessen.

Die Persistenz wurde untersucht, aber nicht auf ein neues Format oder einen
asynchronen Schreibvertrag umgestellt. Benutzer-Clips, Identität, Peer-Dateien,
Pairings und deren Freigaben wurden nicht für diese Tests zurückgesetzt.

## Referenzstand und Umgebung

- Mac: Apple M1 Pro, 16 GiB RAM, arm64.
- macOS 26.6.2, Build 25G83; Xcode unter `/Applications/Xcode.app`.
- Floatcut-HEAD: `0832ada0d97e561214495d3d603a9efe1c591472`.
- Der Ausgangsarbeitsbaum war bereits verändert, unter anderem durch V2 und
  vorherige UI-/Identitätsarbeiten. Es wurde **nicht** nur gegen HEAD gemessen.
- SRC: `c9439b19a23398edf6062e639af4dce8fd0303cf`; sein Arbeitsbaum blieb sauber.
- CPU-Benchmark: `swiftc -O`, synthetische Daten, ohne Netzwerk und Diagnose-Logs.
- App: Release, arm64 + x86_64, Version/Build unverändert 4.0;
  Signieridentität `Floatcut Local Development`.

Der ursprüngliche Codec und ein binärer Diff des damaligen getrackten
Arbeitsbaums wurden für den lokalen Vergleich unter
`/private/tmp/floatcut-performance-baseline.3LLFlM` gesichert. Dieser temporäre
Pfad ist kein dauerhaftes, mit dem Repository ausgeliefertes Archiv.
Ungetrackte V2-Artefakte sind durch diesen Diff allein nicht archiviert.

SHA-256 der wichtigsten Quelldateien **vor** dieser Umsetzung:

| Datei | SHA-256 |
| --- | --- |
| Sync/FloatcutSyncProtocol.swift | `58813bb2cccddd82384b89a01377ce76c573284e1571f31e20a01fda070f9671` |
| Sync/FloatcutSyncCoordinator.swift | `7d82e6bb1b89fb004114679e15d46c1bebe39f6195e9f2c18e96e9c432bef629` |
| AppController.m | `b3fb20d00e8a70143f7154766abea626aeb1e15c588aeba2f3ed2d2e07220f1a` |
| FloatcutOperator.m | `a66d7135b29c3ace4439bad3d93818e548734242132dbe96a29aa2676763c6dc` |
| FloatcutStatusPopoverController.swift | `d3da8f7b4222071ea3709dd29b134b5c6d5d7c3fe27c7402297e32916115aaf9` |
| FloatcutSearchWindowController.swift | `c3c859025316bc6fc996234e5f975e7d86eb84e9143e23345e11ec6c6ab4961d` |

## Codec-Messung

Je Szenario drei Aufwärmdurchläufe und 30 Messungen mit monotoner Uhr.
Die 44 Bildblöcke enthalten jeweils 49.152 synthetische Bytes; gemessen wird
derselbe Block wiederholt, nicht ein kompletter Transfer mit BEGIN/ACK/COMMIT.
Der Text umfasst 192.000 UTF-8-Bytes mit Umlauten und zu escapenden Zeilenumbrüchen.
Die Testnachrichten und ihre ursprünglichen Hashes entstehen vor der Messung.

Zweiter Vergleichsdurchlauf, Werte in Millisekunden:

| Szenario | Vorher Median | Nachher Median | Vorher min–max | Nachher min–max | Vorher/Nachher p95 |
| --- | ---: | ---: | --- | --- | --- |
| 44 Bildblöcke encodieren | 206,006 | 116,705 | 204,866–211,686 | 116,026–118,032 | 207,948 / 117,884 |
| 44 Bildblöcke decodieren | 199,609 | 201,883 | 198,748–201,148 | 200,701–205,547 | 200,708 / 204,660 |
| Großen Text encodieren | 4,311 | 1,005 | 4,201–4,555 | 0,936–1,103 | 4,467 / 1,076 |

Der erste Vergleich ergab für die Encoder-Mediane 209,147 → 119,044 ms
beziehungsweise 4,453 → 0,964 ms. Damit ist die Entlastung des Encoders in
beiden Durchläufen sichtbar. Der reine Decoder wird nicht schneller; im zweiten
Durchlauf beträgt der Unterschied etwa +1,1 %. Er behält nun die geprüften
Chunk-Bytes für den Empfänger. Das damit entfallende zweite Base64-Decodieren
im Coordinator ist in dieser reinen Decoder-Messung nicht enthalten.

Wesentliche Änderungen:

- Der Encoder validiert lokale Werte und Nachrichten vor der Serialisierung,
  ohne große selbst erzeugte JSON-Strings wieder einzulesen. Die tatsächliche
  Frame-Größe wird danach weiterhin geprüft.
- Der strenge JSON-Empfangspfad bleibt bestehen. Auch unbekannte lokale
  Erweiterungsfelder dürfen keine Bruch-/Exponentialzahlen oder zu tiefe
  Verschachtelung einschleusen.
- Der Gesamtbild-Hash wird einmal pro vorbereiteter Bildnachricht erzeugt, nicht
  pro Empfänger. Chunk-Hash/Base64 werden bewusst nicht vollständig vorgepuffert.

Reproduktion:

```sh
bash Scripts/test-sync-performance.sh
# Optional, solange das lokale Ausgangsarchiv existiert:
FLOATCUT_BENCHMARK_PROTOCOL_SOURCE=/private/tmp/floatcut-performance-baseline.3LLFlM/FloatcutSyncProtocol.swift bash Scripts/test-sync-performance.sh
```

Das Skript gibt inzwischen zusätzlich einzelne Messwerte aus. Die oben
festgehaltenen Vergleichsläufe wurden vor dieser Ausgabeergänzung durchgeführt;
für diese Läufe liegen nur die hier angegebenen Zusammenfassungen vor.
Ein abschließender Nachher-Lauf mit Einzelwerten ist in
[ui-sync-performance-rohwerte.txt](ui-sync-performance-rohwerte.txt) abgelegt:
Encoder-Mediane 118,356 ms für 44 Bildblöcke und 0,963 ms für den Text;
Decoder-Median 203,601 ms.

## Asynchrone Verarbeitung und Ressourcen

- `FloatcutSyncOrderedInbox` hält Clipboard-Arbeit pro Verbindung geordnet.
  Ab 2 MiB angerechneter Payload oder 128 wartenden Einträgen wird kein weiterer
  Netzwerk-Read angefordert. Eine bereits eingelesene/decodierte Batch kann
  diese Schwelle überschreiten; sie ist kein exaktes RSS-Limit.
- Ein Clipboard-Job pro Verbindung ist aktiv. Dateioperationen teilen sich eine
  separate serielle I/O-Queue. Diese wartet nie synchron auf den Main Thread.
- Kontrollnachrichten passieren die Clipboard-Inbox unabhängig; sie können
  ausstehende Imports abbrechen. Ein bereits am Main Thread zugelassener Import
  wird nicht nachträglich rückgängig gemacht.
- Ausgehende Vorbereitung reserviert einen Vorgang pro berechtigtem Peer.
  Höchstens zwei Konvertierungen laufen gleichzeitig. Beschäftigte Peers
  erhalten keine weitere Vorbereitung oder Offline-Nachlieferung.
- Verbindungswechsel, Ausschalten und Wiederanschalten beleben alte
  Vorbereitungstickets nicht wieder. Ein neuer Versuch braucht eine neue
  Clipboard-Änderung. Andere berechtigte Peers bleiben unabhängig.
- Ein wiederverwendeter Empfangstimer ersetzt die zuvor pro Chunk zusätzlich
  geplanten Timeout-Callbacks.
- Menü, Suche und Bezel verwenden denselben Thumbnail-Service mit maximal
  zwei parallelen Dekodierungen. Identische ausstehende Anfragen teilen sich
  ihr Ergebnis. Der Cache berücksichtigt echte Pixelkosten und Zielauflösung.
- Das Bezel reserviert während der Dekodierung den bisherigen Bildplatz.
  Auswahlgeneration, aktuelle Clip-ID und Fenstersichtbarkeit verhindern,
  dass ein verspätetes Ergebnis einen anderen Eintrag überschreibt.

## Speicherung: Untersuchung ohne Änderung des Schreibvertrags

`test-storage-performance.sh` kompiliert den tatsächlichen Operator mit einem
reinen Test-Messschalter. Nur im Testprozess wird `standardUserDefaults` auf
eine zufällig benannte Suite umgeleitet, die anschließend entfernt wird.
Im normalen App-Build gibt es diese Messung/Umleitung nicht.

Die Bildbytes sind synthetische 1-MiB-Datenblöcke, keine decodierbaren Bilder;
der Speicherpfad interpretiert diese Bytes nicht. Pro Szenario erfolgen sieben
geänderte Saves. Alle Komponenten werden aufrufseitig gemessen, nicht die
anschließende interne Arbeit des Preferences-Dienstes oder physische SSD-Writes.

| Historie | Gesamtmedian | Gesamtbereich | Dominanter Anteil |
| --- | ---: | --- | --- |
| Nur kurze Texte | 0,399 ms | 0,376–0,450 ms | `setObject` |
| 10 Bilder / 10 MiB | 3,715 ms | 3,313–6,706 ms | `setObject` |
| 50 Bilder / 50 MiB | 14,289 ms | 13,274–24,140 ms | `setObject` |

Gesamtdauern aller sieben Saves, in Reihenfolge (ms):

- Text: 0,411; 0,376; 0,387; 0,399; 0,429; 0,450; 0,399.
- 10 MiB: 6,706; 4,944; 3,920; 3,715; 3,347; 3,590; 3,313.
- 50 MiB: 24,140; 16,479; 14,289; 14,448; 13,917; 13,364; 13,274.

Beim 50-MiB-Szenario benötigt der Snapshot-Aufbau 0,036–0,047 ms,
`setObject` 13,236–24,090 ms und `synchronize` 0,002–0,005 ms. Das pauschale
Entfernen von `synchronize` würde diesen beobachteten Engpass nicht beseitigen.

Entscheidung: Speicherformat, explizite Save-Aufrufe, bestehende Bündelung
und Shutdown-Verhalten bleiben unverändert. Der Spitzenwert kann bei großen
Historien eine UI-Pause erklären; es wird nicht behauptet, dass kein Potenzial
mehr besteht. Eine mögliche Folgearbeit ist die serielle Übergabe unveränderlicher
Snapshots an Preferences im Hintergrund, mit separaten Tests für unmittelbare
Lesbarkeit, Abschluss beim Beenden, Fehler und konkurrierende Saves. Sie ist
hier weder implementiert noch als erfolgreich optimiert verbucht.

## Prüfungen

Erfolgreich vor/nach der Änderung:

- Engine-Regressionen; Suchbenchmark mit 2.000 Einträgen zuletzt 0,361 ms
  gegenüber 0,364 ms zuvor (Einzelwerte, kein Beschleunigungsnachweis).
- Protokolltests einschließlich V2-Fixtures, manipuliertem Hash,
  Escaping-Übergröße, Zahlen-/Tiefenregeln und wiederverwendeten Chunk-Bytes.
- TLS-1.3-Tests und Identitätstests einschließlich erneutem Laden einer
  ausschließlich für den Test erzeugten Identität.

Neu hinzugekommen und erfolgreich:

- `bash Scripts/test-sync-work.sh`: FIFO, anderer Peer während ausstehendem
  Import, Byte-Backpressure, doppelte/veraltete Completions, Abbruchtoken,
  einmalige Vorbereitung, Aus-/Einschalten ohne Wiederbelebung alter Tickets.
- Datei-Lebenszyklus: vollständiger Import, unvollständige Übertragung,
  falsche Reihenfolge, doppelte Chunks, falscher Gesamthash, abgebrochene und
  geschlossene Datei; Bereinigung und Lesbarkeit bereits gemappter Daten.
- Thumbnail-Tests: Main-Thread-Callback, ungültiges Bild, gemeinsames Ergebnis
  paralleler Anfragen, Cache-Treffer und unterschiedliche Größe/Skalierung.
- `bash Scripts/test-sync-src-codec.sh`: unveränderten Python-SRC-Codec direkt
  importiert; Floatcut → SRC → Floatcut mit fragmentierten Frames, einem Text,
  PNG (2.433.560 Bytes, 50 Chunks) und JPEG (937.726 Bytes, 20 Chunks).
  Bilder nach beiden Richtungen bytegleich. Keine Discovery, kein Pairing und
  kein Live-Netzwerk bei diesem Test; kein gestarteter Referenzclient.
- `bash Scripts/test-storage-performance.sh` und die obigen Codec-Messungen.
- Release-Build nach `dist/Floatcut.app`; lokale Signaturprüfung außerhalb der
  Sandbox: `valid on disk`, `satisfies its Designated Requirement`.
  Innerhalb der Sandbox konnte die lokale Vertrauenskette nicht geprüft werden.

Bekannte Build-Warnungen (unter anderem bestehendes `SecKeyGeneratePair` und
ältere Objective-C-Zahlkonvertierungen) wurden nicht als Teil dieser Arbeit
umgebaut. Kein Identitätsreset, App-Austausch unter `/Applications`, Start der
Benutzer-App, Commit oder Push wurde vorgenommen.

## Noch offene Gesamtabnahme

- LAN-Test mit mindestens zwei Geräten: End-to-End-ACK-Zeit, mehrere Peers,
  ein langsamer Peer, Bildfreigabe während Vorbereitung/Versand, Unpair,
  Widerruf, Reconnect und Netzwerkunterbrechungen.
- Reale Eingangsfehler wie volle Platte/Berechtigungswechsel und Abbruch
  während eines laufenden System-I/O-Aufrufs; die vorhandenen Tests simulieren
  geschlossene/ungültige Dateizustände, nicht diese Betriebssystemereignisse.
- Visuelle Prüfung bei schneller Bezel-/Listen-Navigation, mehreren Displays,
  unterschiedlichen Skalierungen, Orientierung/Transparenz großer Bilder,
  Menü/Suche/Favoriten und Handoff.
- Main-Thread-Auslastung, RSS und Energieverbrauch unter UI-Last; Vergleich
  mit/ohne ausführliches Logging.

Hierfür liefern die bestehenden aktivierbaren Sync-Diagnoselogs nun monotone
`elapsed_ms`-Messungen für `wire_encode`, `wire_decode`,
`v2_image_prepare_and_hash`, `v2_image_file_commit_validation`,
`remote_text_ui_wait_and_apply`, `remote_image_ui_wait_and_apply` und
`v2_image_begin_to_final_ack`. Der letzte Wert gilt pro Verbindung und umfasst
BEGIN bis terminales ACK, nicht die davor liegende Konvertierung.
Die Einträge enthalten keine Clipboard-Inhalte. Verbose-Logging selbst erzeugt
Zusatzarbeit und muss für den eigentlichen Performancevergleich ausgeschaltet
beziehungsweise als eigener Testfall behandelt werden.
