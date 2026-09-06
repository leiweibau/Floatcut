# Implementierungsplan: Floatcut Sync Protocol V2

## 1. Ziel

Floatcut für macOS wird vom bisherigen Floatcut Sync Protocol V1 auf das in
`Floatcut-SRC/docs/Protocol/floatcut-sync-v2.md` festgelegte Protocol V2
umgestellt. V2 bleibt für Textübertragungen funktional kompatibel im Verhalten,
ist auf dem Wire aber absichtlich nicht mit V1 kompatibel und ergänzt die
begrenzte, bestätigte und in Chunks aufgeteilte Übertragung von PNG- und
JPEG-Bildern.

Für jeden gekoppelten V2-Peer erhält die Liste **„Gekoppelte Geräte“** einen
kleinen Zahnradbutton. Darüber wird ausschließlich lokal festgelegt, ob
Floatcut eigene Bilder an genau diesen Peer senden darf.

- Der Schalter beeinflusst keine Textübertragung.
- Der Schalter beeinflusst keine eingehenden Bilder.
- Ein ausgeschalteter Schalter entkoppelt das Gerät nicht.
- Ein ausgeschalteter Schalter löscht weder lokale noch entfernte Daten.
- Die Einstellung wird nicht an die Gegenstelle übertragen.
- Es gibt keinen automatischen Rückfall auf V1.

Dieser Plan basiert auf dem Stand `c9439b1` des eigenständigen Repositorys
`http://10.1.3.141:3000/CodeVerwalter/Floatcut-SRC`. Normative Quelle sind die
V2-Spezifikation, die V2-Schemas, die V2-Fixtures und
`CONFORMANCE_V2.md` in diesem Repository. Bei einem Widerspruch haben diese
Artefakte Vorrang vor diesem Arbeitsplan.

## 2. Verbindliche Produktentscheidungen

### 2.1 V2 ist das aktive Protokoll

Nach der Umstellung publiziert und akzeptiert Floatcut ausschließlich
`pv=2`. Es wird kein gemischter V1/V2-Nachrichtenstrom auf einer Verbindung und
keine automatische Protokollerkennung anhand des ersten Frames implementiert.
Eine Verbindung ist vom Listener über `HELLO` bis zum Schließen vollständig V2.

Die bisherige V1-Implementierung und ihre Tests bleiben zunächst als lesbare
Migrations- und Regressionsreferenz erhalten. Zur Laufzeit werden jedoch keine
neuen V1-Verbindungen aufgebaut und keine V1-Dienste mehr veröffentlicht.

### 2.2 V1-Vertrauen wird nicht als V2-Vertrauen verwendet

Die lokale TLS-Geräteidentität – Geräte-ID, privater Schlüssel und Zertifikat –
darf weiterverwendet werden. V1-Peer-Pins dürfen V2-Verbindungen dagegen nicht
automatisch autorisieren. Das verlangt die V2-Spezifikation ausdrücklich.

Deshalb werden V2-Daten getrennt gespeichert:

- `peers-v2.json`
- `pending-pairings-v2.json`
- `revocations-v2.json`

Die vorhandenen V1-Dateien bleiben unverändert erhalten und werden weder
umbenannt noch als V2 importiert. Ein bisher nur über V1 gekoppeltes Gerät muss
über einen neuen V2-Vergleichscode gekoppelt werden. Die Oberfläche erklärt
dies einmalig verständlich; ein Identitätsreset ist dafür nicht erforderlich.

### 2.3 Bildversand ist pro Peer explizit freizugeben

Das neue Persistenzfeld heißt im Modell beispielsweise
`allowsOutgoingImages`. Für neu gekoppelte Geräte und beim Dekodieren eines
Datensatzes ohne dieses Feld gilt aus Datenschutz- und Bandbreitengründen der
Standardwert `false`. Text wird bei aktivierter Peer-Freigabe weiterhin wie
bisher gesendet.

Das Ausschalten wirkt sofort:

- noch nicht begonnene Bildübertragungen an diesen Peer werden verworfen;
- eine bereits laufende ausgehende Übertragung wird mit
  `CLIPBOARD_IMAGE_ABORT/reason=sender_cancelled` beendet;
- andere Peers und laufende Textübertragungen bleiben unangetastet;
- eingehende Bildübertragungen desselben Peers laufen weiter.

Es gibt keine Offline-Warteschlange. Ein wegen deaktiviertem Versand,
fehlender Verbindung oder negativem ACK ausgelassenes Bild wird später nicht
nachgeliefert.

## 3. Bestand und betroffene Komponenten

### 3.1 Aktueller macOS-Stand

- `Sync/FloatcutSyncProtocol.swift` ist fest auf V1, den V1-Domain-Separator
  und reine Textnachrichten ausgelegt.
- `Sync/FloatcutSyncCoordinator.swift` verwaltet Discovery, TLS, Pairing,
  Verbindungen, Text-Fan-out, Revocation und die SwiftUI-Zustände.
- `Sync/FloatcutSyncIdentity.swift` enthält Identität, Peer-/Pending-/Revocation-
  Modelle und atomare JSON-Stores.
- `AppController.m` erkennt schon lokale PNG-/TIFF-Pasteboardinhalte und legt
  Bild-Clips im lokalen Verlauf ab, ruft danach aber keinen Sync-Sendepfad auf.
- `FloatcutClipping` und `FloatcutOperator` können Bildbytes bereits speichern,
  anzeigen, favorisieren und persistent wiederherstellen.
- `FloatcutPreferencesWindowController.swift` zeigt gekoppelte Geräte mit
  Onlinezustand, Aktivierung und Entkoppeln an.

### 3.2 Normative V2-Artefakte

Vor der Implementierung werden die folgenden Dateien aus `Floatcut-SRC` als
unveränderte Testsnapshot-Kopie unter `docs/Protocol/` beziehungsweise den
bestehenden Fixture-Verzeichnissen aufgenommen:

- `floatcut-sync-v2.md`
- `CONFORMANCE_V2.md`
- `schemas/v2/*.schema.json`
- `fixtures/v2/pairing-vectors.json`
- `fixtures/v2/clipboard-update.json`
- `fixtures/v2/image-transfer.json`
- alle für V2 weiterhin relevanten ungültigen Frames

Die Kopie dokumentiert Quell-Commit und Datum. Normative Dateien werden nicht
beim Kopieren angepasst. Ein Skript oder Test vergleicht auf Wunsch Hashes mit
dem ausgecheckten SRC, damit beide Implementierungen nicht unbemerkt
auseinanderlaufen.

## 4. Zielarchitektur

```text
Lokales Pasteboard
        │
        ├── Text ───────────────► V2-Text-Fan-out an alle aktivierten Online-Peers
        │
        └── Bild ─► normalisieren/prüfen ─► nur Peers mit allowsOutgoingImages
                                             │
                                             ▼
                                  BEGIN → ready → CHUNKS → COMMIT

V2-Verbindung eines Peers
        │
        ├── eingehender Text ──► Verlauf + Pasteboard + Sync-Herkunftsmarkierung
        │
        └── eingehendes Bild ──► Temp-Datei + Prüfung + atomare Freigabe
                                   └── Verlauf + Pasteboard + Herkunftsmarkierung
```

Die bestehende Regel bleibt erhalten: Ein remote empfangener Clip darf nie
wieder gesendet werden. Pasteboard-Block-Tokens und das persistente
`receivedFromSync`-Merkmal gelten gleichermaßen für Text und Bild.

## 5. Datenmodell, Persistenz und Migration

### 5.1 Peer-Modell

`FloatcutSyncPeer` wird um ein lokal verwendetes Codable-Feld ergänzt:

```swift
var allowsOutgoingImages: Bool
```

Da synthetisch erzeugte oder ältere V2-Testdaten das Feld nicht enthalten
können, erhält das Modell eine kontrollierte `init(from:)`-Implementierung mit
`decodeIfPresent(...) ?? false`. Der Encoder schreibt das Feld immer explizit.
Es ist kein Wire-Feld und darf weder in `HELLO` noch in Pairing-Nachrichten
auftauchen.

Die Änderung wird über eine Coordinator-Methode durchgeführt, nicht durch
direkte UI-Manipulation:

```swift
setOutgoingImagesAllowed(deviceID: String, allowed: Bool)
```

Diese Methode aktualisiert den V2-Peer-Store atomar, publiziert den neuen
SwiftUI-Zustand und informiert die Engine, damit ein laufender ausgehender
Transfer gegebenenfalls abgebrochen wird.

### 5.2 Store-Trennung

Der Coordinator verwendet nach dem Cutover ausschließlich die V2-Dateien. Die
V1-Dateien werden nicht gelöscht. Fehlerhafte V2-Stores müssen weiterhin
fail-closed behandelt und für Diagnosezwecke erhalten werden; sie dürfen nicht
stillschweigend durch leere Stores überschrieben werden.

Beim ersten V2-Start wird geprüft, ob V1-Peers, aber keine V2-Peers vorhanden
sind. In diesem Fall erscheint ein nicht blockierender Hinweis:

> Floatcut Sync verwendet jetzt Protokoll V2. Bereits über V1 gekoppelte Geräte
> müssen einmal erneut bestätigt werden. Die lokale Sync-Identität bleibt
> erhalten.

Der Hinweis darf weder den Keychain ändern noch V1-Peerdateien entfernen.

### 5.3 Pairing, Pending und Widerruf

- Pairing verwendet den Domain-Separator `FLOATCUT-PAIR-V2\0`.
- Der normative V2-Vektor muss 177 Bytes, den Hash
  `ab448a18...c0da9ad5` und den Code `395736` liefern.
- Pending- und Peer-Abfragen dürfen nur V2-Stores betrachten.
- Ein V1-Pin darf im TLS-Verify-Block nicht als bekannter V2-Peer gelten.
- `UNPAIR` und `UNPAIR_ACK` betreffen nach dem Cutover V2.
- V1-Tombstones bleiben archiviert, blockieren aber nicht anhand ihres bloßen
  Vorhandenseins eine neue explizite V2-Kopplung.
- Ein vollständiger Identitätsreset entfernt V1- und V2-Sync-Stores, weil er
  ausdrücklich alle Kopplungen löscht. Vor der Implementierung ist dieser
  destructive Pfad durch einen eigenen Regressionstest abzusichern.

## 6. V2-Codec und Validierung

### 6.1 Gemeinsamer Envelope

`FloatcutSyncProtocol.version` wird auf `2` gesetzt. Encoder, Decoder und
`FloatcutSyncWireMessage` müssen weiterhin strikt prüfen:

- vier Byte Big-Endian-Länge;
- Framegröße `1...1_048_576` Bytes;
- strikt gültiges UTF-8;
- maximal acht JSON-Verschachtelungsebenen;
- keine doppelten Schlüssel;
- keine Floats, Exponenten, `NaN` oder Unendlichkeiten;
- kanonische UUIDv4- und Base64url-Darstellung;
- Integer-Zeitwerte in `0...2^53-1`;
- exakt `v: 2`.

V1-Frames müssen mit `ERROR/incompatible_version` beantwortet und anschließend
geschlossen werden.

### 6.2 V2-Nachrichtentypen

Zu `knownTypes` und zur feldgenauen Validierung kommen hinzu:

- `CLIPBOARD_IMAGE_BEGIN`
- `CLIPBOARD_IMAGE_CHUNK`
- `CLIPBOARD_IMAGE_COMMIT`
- `CLIPBOARD_IMAGE_ABORT`

`CLIPBOARD_ACK` akzeptiert in V2 zusätzlich `ready`. `ready` ist nur die
Freigabe nach einem gültigen `BEGIN`, kein terminales Ergebnis. Alle anderen
ACK-Statuswerte bleiben terminal.

Konstanten werden zentral definiert:

- Bildtypen: `image/png`, `image/jpeg`
- maximale Bildgröße: `16_777_216` Bytes
- Chunkgröße: exakt `49_152` Bytes
- maximale Chunkzahl: `342`
- PNG-Mindestgröße/Signatur: 8 Bytes / `89 50 4e 47 0d 0a 1a 0a`
- JPEG-Mindestgröße/Signatur: 3 Bytes / `ff d8 ff`

Die Validierung darf Base64-Textlänge, dekodierte Bytegröße und Hash niemals
verwechseln. Jeder Chunkhash und der Gesamthash beziehen sich auf dekodierte
Bytes.

### 6.3 Discovery und HELLO

Der DNS-SD-Dienst bleibt `_floatcutsync._tcp`, publiziert aber:

```text
id=<lower-case UUIDv4>
pv=2
platform=macos
caps=clip.image.jpeg,clip.image.png,clip.text.utf8
pair=0|1
```

Die Capabilities müssen exakt byteweise sortiert sein. TXT-Schlüssel werden
ASCII-case-insensitiv gelesen; kollidierende Schlüssel wie `id` und `ID`
machen den gesamten Eintrag ungültig. DNS-Namen werden für Vergleich,
Entfernung und Deduplizierung ASCII-case-insensitiv sowie ohne abschließenden
Root-Punkt normalisiert, für die Anzeige aber in empfangener Schreibweise
beibehalten.

`HELLO.capabilities` ist exakt:

```json
["clip.image.jpeg","clip.image.png","clip.text.utf8"]
```

Fehlt eine dieser Fähigkeiten, wird keine V2-Verbindung aufgebaut. Diese
Pflichtfähigkeiten sind von `allowsOutgoingImages` unabhängig: Der Peer kann
Bilder empfangen, auch wenn der lokale Benutzer den Versand abgeschaltet hat.

## 7. Ausgehender Bildpfad

### 7.1 Anbindung an das Clipboard

Der vorhandene Bildzweig in `AppController.m::pollPB:` wird erweitert. Erst
wenn `FloatcutOperator` das lokale Bild tatsächlich in den Verlauf aufgenommen
hat, wird es dem Coordinator übergeben. Dafür entsteht eine Objective-C-
sichtbare API, beispielsweise:

```swift
sendAcceptedLocalImage(_ data: Data, pasteboardType: String)
```

Die Sendemethode wird niemals aus dem Remote-Importpfad aufgerufen.

### 7.2 Normalisierung

- Liegen valide PNG-Bytes vor, werden sie unverändert verwendet.
- Liegen valide JPEG-Bytes vor, werden sie unverändert verwendet.
- TIFF und andere native Bitmaprepräsentationen werden mit ImageIO in PNG
  konvertiert; PNG ist das verlustfreie Austauschformat.
- Schlägt Dekodierung oder Konvertierung fehl oder überschreitet das Ergebnis
  16 MiB, bleibt der Clip lokal erhalten, wird aber nicht synchronisiert.
- Das komplette Bild und seine Base64-Darstellung werden niemals geloggt.

Die Konvertierung läuft außerhalb des Main Threads. Die lokale
Clipboard-Erfassung und die Menüoberfläche dürfen nicht auf Netzwerk-ACKs
warten.

### 7.3 Fan-out und Transferzustand

Für jeden online und trusted Peer wird separat entschieden:

```text
peer.enabled == true
AND peer.allowsOutgoingImages == true
AND Verbindung ist Trusted
AND Verbindung meldet die verpflichtenden V2-Bildfähigkeiten
```

Nur dann beginnt der Bildtransfer. Alle berechtigten Peers erhalten dieselbe
`clip_id`, aber jede Verbindung besitzt ihren eigenen Transferzustand und ihre
eigenen ACK-/Timeout-Entscheidungen.

Der Sender:

1. erzeugt Metadaten und SHA-256 über die vollständigen Bytes;
2. sendet `CLIPBOARD_IMAGE_BEGIN`;
3. wartet auf `CLIPBOARD_ACK/ready` für dieselbe `clip_id`;
4. sendet Chunks streng ab Index 0, nie verschachtelt mit einem zweiten Bild;
5. sendet `CLIPBOARD_IMAGE_COMMIT`;
6. wartet auf ein terminales ACK;
7. gibt Zustand und Bytes frei.

Pro Verbindung darf maximal ein ausgehender Bildtransfer aktiv sein. Da es
keine Queue und kein Backfill gibt, wird ein weiteres lokales Bild für einen
gerade beschäftigten Peer mit einem redigierten Diagnoseereignis ausgelassen.
Textnachrichten und Keepalives bleiben zulässig, sofern die Wire-Reihenfolge
der seriellen Verbindungsverarbeitung erhalten bleibt.

Timeouts werden explizit und testbar definiert: 15 Sekunden auf `ready` und 30
Sekunden auf das terminale ACK. Bei Timeout oder I/O-Fehler wird, soweit die
Verbindung noch schreibbar ist, `CLIPBOARD_IMAGE_ABORT` mit dem passenden
Grund gesendet und der Transferzustand gelöscht. Ein ACK für eine falsche oder
bereits beendete `clip_id` darf keinen neuen Zustand erzeugen.

## 8. Eingehender Bildpfad

### 8.1 Zustandsautomat

Jede Trusted-Verbindung besitzt höchstens einen eingehenden Bildzustand:

```text
Idle
  └─ gültiges BEGIN ─► Receiving
                         ├─ gültiger nächster CHUNK ─► Receiving
                         ├─ COMMIT + Gesamtprüfung ─► Applied/Idle
                         ├─ ABORT ──────────────────► Idle
                         └─ Fehler/Disconnect ──────► Cleanup/Idle
```

Vor `CLIPBOARD_ACK/ready` werden Typ, Größe, Chunkgröße, Chunkzahl,
`source_device_id`, Replaystatus und verfügbare Ressourcen geprüft. Ein
abgelehnter Beginn erhält ein terminales `duplicate`, `skipped`, `unsupported`
oder `invalid`; danach werden keine Chunks für diesen Transfer akzeptiert.

### 8.2 Temporäre Speicherung und Ressourcengrenzen

- Temporäre Dateien liegen in einem privaten V2-Sync-Unterverzeichnis mit
  restriktiven Rechten und zufälligem Namen, niemals anhand des Gerätenamens.
- Es wird nicht vor erfolgreichem `BEGIN` allokiert.
- Dekodierte Chunks werden strikt nacheinander geschrieben und inkrementell
  gehasht.
- Falsche Indizes, Größen, Chunkhashes oder Base64-Daten brechen ab.
- Bei `COMMIT` werden Anzahl, Gesamtgröße, Gesamthash und Dateisignatur geprüft.
- Vor der Übergabe an AppKit prüft ImageIO Dimensionen und dekodierten
  Speicherbedarf mit overflow-sicherer Arithmetik. Konkrete Pixel-/Speicher-
  Limits werden als benannte Konstanten und Tests dokumentiert.
- Erst eine vollständig validierte Datei wird atomar in einen validierten
  temporären Namen verschoben und anschließend in den Floatcut-Verlauf
  übernommen.
- Teil- und validierte Temporärdateien werden nach Import sowie bei Abort,
  Fehler, Timeout, Disconnect und App-Startbereinigung entfernt.

### 8.3 Import in Verlauf und Pasteboard

Der Clipboard-Delegate wird um einen Bildempfangspfad ergänzt. Dieser:

- nutzt `FloatcutOperator::addImageClippingData`;
- setzt `receivedFromSync=YES` auf dem tatsächlich eingefügten Clip;
- verwendet als lokale Quelle `Sync: <Peername>`;
- schreibt den passenden PNG-/JPEG-Pasteboardtyp;
- setzt unmittelbar danach den vorhandenen Pasteboard-Block-Token;
- ruft niemals `sendAcceptedLocalImage` auf.

Der Schalter `allowsOutgoingImages` wird hier absichtlich nicht gelesen.
Eingehende Bilder werden bei aktivem Sync immer angenommen, sofern der Peer
trusted, der lokale Verlauf nicht pausiert und der Transfer gültig ist.

Das terminale ACK wird erst nach dem lokalen Import bestimmt:

- `applied`: neu in Verlauf und Pasteboard übernommen;
- `duplicate`: identische Bildbytes bereits vorhanden;
- `skipped`: lokaler Verlauf pausiert oder lokale Erfassungsregel greift;
- `unsupported`: lokaler Decoder unterstützt die Darstellung nicht;
- `invalid`: Transfer oder Import war semantisch ungültig.

## 9. Zahnradbutton und Bedienung

### 9.1 Position und Darstellung

In `SynchronizationPreferencesView`, innerhalb jeder Zeile unter
**„Gekoppelte Geräte“**, wird rechts ein kleiner randloser Button mit
`Image(systemName: "gearshape")` eingefügt. Empfohlene Reihenfolge:

```text
[Status + Gerätename]   [Spacer]   [Zahnrad] [Peer aktiv] [Entkoppeln]
```

Der Button öffnet ein SwiftUI-`Menu`. Er darf die Zeilenhöhe nicht verändern
und benötigt eine ausreichend große Klickfläche sowie ein Accessibility-Label
wie „Übertragungseinstellungen für <Gerätename>“.

### 9.2 Menüinhalt

Das Menü enthält einen Toggle beziehungsweise einen Eintrag mit sichtbarem
Häkchen:

- Deutsch: **„Bilder an dieses Gerät senden“**
- Englisch: **“Send images to this device”**

Darunter steht als deaktivierter Hilfetext oder Help-Popover:

- Deutsch: „Der Schalter betrifft nur das Senden. Bilder von diesem Gerät
  werden weiterhin empfangen.“
- Englisch: “This setting only affects sending. Images from this device are
  still received.”

Die UI schreibt ausschließlich über
`setOutgoingImagesAllowed(deviceID:allowed:)`. Das Umschalten zeigt sofort den
persistierten Wert, funktioniert auch bei einem offline befindlichen Peer und
verändert weder `peer.enabled` noch Pairing- oder Revocation-Daten.

### 9.3 Fehler- und Statusführung

- Ein abgeschalteter Bildversand ist kein Fehler und erzeugt keine rote
  Warnung.
- Wird ein Bild wegen des Schalters nicht gesendet, genügt ein redigiertes
  Diagnoseereignis; die allgemeine Statuszeile soll nicht bei jedem Bild
  flackern.
- Ist der Peer offline, bleibt die Einstellung änderbar und gilt nach dem
  nächsten Verbindungsaufbau.
- Ein fehlgeschlagenes Persistieren setzt die sichtbare Auswahl auf den zuvor
  gespeicherten Wert zurück und zeigt eine normale lokale Fehlermeldung.

## 10. Netzwerk-, Sicherheits- und Nebenläufigkeitsregeln

- TLS bleibt gegenseitiges TLS 1.3 mit derselben Zertifikatsprofilprüfung.
- Die V2-Peer-Pin-Prüfung erfolgt vor Trusted-Zustand und vor Clipboarddaten.
- Ein Remote-Clip darf nicht weitergeleitet werden, auch nicht an einen anderen
  Peer mit aktiviertem Bildversand.
- Pro Verbindung existieren höchstens ein eingehender und ein ausgehender
  Bildtransfer; beide Richtungen dürfen gleichzeitig aktiv sein.
- Zustandsänderungen der Verbindung und Transfers laufen seriell auf der
  bestehenden Netzwerkqueue.
- Bildkonvertierung und Dateizugriffe blockieren den Main Thread nicht.
- UI-Updates und AppKit-/Pasteboard-Zugriffe erfolgen auf dem Main Thread.
- Base64 wird chunkweise erzeugt/dekodiert; nie zusätzlich eine vollständige
  Base64-Kopie eines 16-MiB-Bildes halten.
- Alle Größenrechnungen sind overflow-sicher und werden vor Allocation geprüft.
- Ein Disconnect entfernt ausnahmslos partielle Dateien und Timer.
- Replay-Caches behandeln `message_id` und `clip_id` weiterhin zehn Minuten
  lang und mit maximal 2.048 Einträgen.
- Empfangene Bilder, Chunks, Nonces, Transcript-Hashes, Schlüssel und
  Vergleichscodes erscheinen nie in Logs.

## 11. Diagnoseereignisse

Die vorhandene detaillierte Sync-Diagnose wird um redigierte Ereignisse
ergänzt. Zulässige Felder sind kurze Peer-ID, Richtung, Inhaltstyp, deklarierte
Bytegröße, Chunkindex/-zahl, Dauer, ACK-Status und Fehlerklasse.

Empfohlene Ereignisse:

- `v2_image_send_skipped_peer_setting`
- `v2_image_begin_sent`
- `v2_image_ready_received`
- `v2_image_chunk_progress`
- `v2_image_commit_sent`
- `v2_image_send_completed`
- `v2_image_send_aborted`
- `v2_image_begin_received`
- `v2_image_chunk_progress_received`
- `v2_image_commit_validated`
- `v2_image_receive_completed`
- `v2_image_receive_cleanup`

Fortschritt wird gedrosselt, zum Beispiel nur für ersten/letzten Chunk und
25-%-Grenzen, damit ein Maximalbild nicht hunderte Logzeilen erzeugt. Dateipfade
und Bildbytes werden nicht geloggt.

## 12. Testplan

### 12.1 Codec- und Fixture-Tests

`Tests/SyncProtocolTests/main.swift` und `Scripts/test-sync-protocol.sh` werden
auf V2-Fixtures erweitert beziehungsweise umgestellt:

- normativer V2-Pairing-Vektor;
- V1-Envelope wird als inkompatibel verworfen;
- V2-Textfixture bleibt gültig;
- vollständiges PNG-Fixture aus `image-transfer.json`;
- fragmentierte und zusammengefasste Netzwerkframes;
- minimale und maximale PNG-/JPEG-Größen;
- exakte 49.152-Byte-Chunks und korrekter letzter Restchunk;
- falscher Index, fehlender/duplizierter Chunk;
- falsches Base64, Chunkhash, Gesamthash und Signatur;
- `ready` nur in passendem ausgehenden Transferzustand;
- Cleanup nach Abort, Fehler, EOF und Disconnect.

### 12.2 Store- und UI-Tests

- neuer V2-Peer startet mit `allowsOutgoingImages=false`;
- fehlendes Feld dekodiert auf `false`;
- Umschalten wird über App-Neustart erhalten;
- Umschalten verändert `enabled`, Pin und Pairingzeit nicht;
- Zahnrad erscheint in jeder Peerzeile, auch offline;
- deutsche und englische Texte sind vollständig lokalisiert;
- Accessibility-Label enthält den Gerätenamen;
- Ausschalten während Transfer sendet Abort und bereinigt Zustand;
- bei Store-Schreibfehler kehrt die UI zum gespeicherten Wert zurück.

### 12.3 Engine- und Loop-Schutztests

| Fall | Erwartung |
|---|---|
| lokales Bild, Schalter aus | kein `CLIPBOARD_IMAGE_BEGIN` an diesen Peer |
| lokales Bild, Schalter an | vollständiger V2-Transfer nach `ready` |
| zwei Peers mit unterschiedlicher Einstellung | nur freigegebener Peer erhält das Bild |
| eingehendes Bild, Schalter aus | Bild wird dennoch angenommen und bestätigt |
| eingehendes Bild wird ins Pasteboard geschrieben | kein ausgehender Bild- oder Textframe |
| Peer offline | keine Queue und keine spätere Nachlieferung |
| zweites Bild während aktivem Transfer | definiertes Skip, kein Interleaving |
| Pause/Store deaktiviert | terminales `skipped`, keine Veröffentlichung |
| Duplikat | terminales `duplicate`, kein zweiter Verlaufseintrag |
| Toggle aus während Transfer | `ABORT/sender_cancelled`, Verbindung bleibt nutzbar |
| Disconnect während Empfang | Teilfile und Timer werden entfernt |

Der Dreieckstest A→B mit zusätzlichem Peer C wird anhand der Netzwerkausgabe
geprüft: B darf das empfangene Bild selbst dann nicht an C senden, wenn C in B
für Bildversand freigegeben ist.

### 12.4 Interoperabilität gegen den SRC

Der Python-SRC wird mit frischem V2-State-Verzeichnis außerhalb einer Sandbox
gestartet. Zu prüfen sind jeweils beide Pairing-Initiatorrichtungen sowie:

1. V2-Discovery mit exakt übereinstimmenden TXT-Daten;
2. gegenseitiges TLS 1.3, V2-HELLO und Pinning;
3. V2-Pairing mit identischem Vergleichscode;
4. Text Floatcut → SRC und SRC → Floatcut;
5. PNG Floatcut → SRC mit aktiviertem Peer-Schalter;
6. kein PNG Floatcut → SRC mit deaktiviertem Peer-Schalter;
7. PNG und JPEG SRC → Floatcut bei deaktiviertem Peer-Schalter;
8. `ready`, terminale ACKs und Sender-Abort;
9. Online-/Offline-Widerruf und Neustart;
10. Identitäts- und Store-Persistenz über einen gleich signierten App-Update-
    Build ohne Reset.

Die Ergebnisse werden in der macOS-Conformance-Datei und in
`Floatcut-SRC/TEST_STATUS.md` mit Datum dokumentiert. Änderungen im separaten
SRC-Repository werden separat committed und nicht als verschachtelter Commit
des Floatcut-Repositories behandelt.

## 13. Umsetzungsphasen und Gates

### Phase 0 – Snapshot und rote Tests

- V2-Spezifikation, Schemas und Fixtures übernehmen.
- V2-Konstanten und erwartete Testwerte festlegen.
- zunächst fehlschlagende Codec-, Store- und Bildzustandstests anlegen.

**Gate:** Testquellen bauen; Fehler zeigen ausschließlich die noch fehlende
V2-Funktionalität.

### Phase 1 – V2-Codec und Discovery

- Envelope, Nachrichtentypen, Feldvalidatoren und Pairing-Transcript auf V2;
- V2-TXT-Publikation und robuste TXT-/DNS-Normalisierung;
- V1-Inkompatibilität explizit testen.

**Gate:** alle gemeinsamen V2-Fixtures und der normative Pairing-Vektor passen
bytegenau.

### Phase 2 – V2-Trust und Pairing

- getrennte V2-Stores aktivieren;
- V1-Hinweis und V2-Neukopplung umsetzen;
- TLS-Pinning, Pending-Resume und Revocation auf V2 prüfen.

**Gate:** Pairing/Resume/Revocation gegen SRC ohne Nutzung eines V1-Pins.

### Phase 3 – Eingehender Bildtransfer

- Receiver-Zustandsautomat, Temp-Datei, inkrementelle Hashes und Cleanup;
- ImageIO-Sicherheitsprüfung;
- Import in Verlauf/Pasteboard mit Loop-Schutz.

**Gate:** gültige PNG/JPEG vom SRC werden angewendet; sämtliche Negativfälle
hinterlassen keine sichtbaren oder temporären Daten.

### Phase 4 – Ausgehender Bildtransfer

- lokale Bildnormalisierung;
- BEGIN/ready/chunks/commit/ACK-Zustandsautomat;
- Timeouts, Abort und Fan-out ohne Queue.

**Gate:** PNG/JPEG an SRC funktionieren an Chunk- und Maximalgrenzen; Textpfad
bleibt unverändert.

### Phase 5 – Zahnrad und Peer-Einstellung

- persistentes `allowsOutgoingImages`;
- Zahnrad-Menü, Hilfetext, Lokalisierung und Accessibility;
- sofortiger Abort beim Ausschalten;
- Empfang vollständig unabhängig vom Schalter testen.

**Gate:** gemischter Zwei-Peer-Test beweist die per Peer getrennte
Senderentscheidung und unveränderten Empfang.

### Phase 6 – Stabilisierung und Release-Build

- vollständige automatisierte Suite;
- reale LAN-, Sleep/Wake-, WLAN-Wechsel- und Mehrgeräte-Tests;
- CPU-, Speicher- und Dateileak-Prüfung mit Maximalbildern;
- Dokumentation und beide Conformance-Listen aktualisieren;
- Universal-AppBundle bauen und Signatur prüfen.

**Gate:** `CONFORMANCE_V2.md` ist für macOS vollständig belegt, der SRC-
Interoperabilitätstest ist dokumentiert und ein gleich signiertes Update behält
die Sync-Identität ohne Reset.

## 14. Konkrete Dateizuordnung für den umsetzenden Agenten

| Datei/Bereich | Geplante Änderung |
|---|---|
| `Sync/FloatcutSyncProtocol.swift` | V2-Konstanten, Transcript, Bildtypen und strikte Validatoren |
| `Sync/FloatcutSyncCoordinator.swift` | V2-Stores, Peer-Schalter, Bild-Sende-/Empfangsrouting, Transfer-Lifecycle |
| `Sync/FloatcutSyncIdentity.swift` | Peerfeld mit rückwärtsrobustem Codable und V2-Storemodelle |
| `Sync/FloatcutSyncImageTransfer.swift` (neu) | getrennte Sender-/Receiver-Zustandsautomaten, Temp-Datei und Hashing |
| `AppController.m` / `.h` | lokaler Bildsendepunkt und Remote-Bildimport mit Pasteboard-Blockierung |
| `FloatcutPreferencesWindowController.swift` | Zahnrad-Menü pro Peer und unmittelbare Zustandsbindung |
| `German.lproj/Localizable.strings` | deutsche UI- und Fehlermeldungen |
| `English.lproj/Localizable.strings` | englische UI- und Fehlermeldungen |
| `Tests/SyncProtocolTests/main.swift` | V2-Codec-, Fixture- und Pairingtests |
| neue Sync-Transfer-Tests/Skript | Zustandsautomat, Limits, Cleanup, Toggle und Loop-Schutz |
| `docs/Protocol/` | unveränderter V2-Snapshot und macOS-Conformance |
| `docs/PLATFORM_NOTES.md` | macOS-Bildtypen, ImageIO-Grenzen, Temp-Dateien und Updateverhalten |

## 15. Definition of Done

Die Umsetzung ist erst abgeschlossen, wenn alle folgenden Punkte erfüllt sind:

- Floatcut publiziert und spricht ausschließlich das normative Protocol V2.
- V1-Pins wurden nicht automatisch zu V2-Vertrauen.
- Textsync, Pairing, Resume, Widerruf, Discovery und TLS funktionieren weiterhin.
- PNG und JPEG funktionieren in beiden Richtungen gegen den unabhängigen SRC.
- Der Zahnradbutton ist bei jedem gekoppelten V2-Peer vorhanden.
- Der Bildsendeschalter ist lokal, persistent und standardmäßig aus.
- Ein ausgeschalteter Schalter verhindert nur ausgehende Bilder zu diesem Peer.
- Eingehende Bilder werden unabhängig vom Schalter verarbeitet.
- Remote-Bilder werden niemals weitergeleitet.
- Teilbilder und sensible Inhalte bleiben weder auf Disk noch in Logs zurück.
- Alle automatisierten Tests, Lokalisierungsprüfungen und Conformance-Gates passen.
- Das Universal-AppBundle baut für `arm64` und `x86_64`, ist gültig signiert und
  ein gleich signiertes Update kann die bestehende Sync-Identität ohne Reset laden.
