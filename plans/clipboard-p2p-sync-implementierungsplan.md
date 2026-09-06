# Implementierungsplan: Floatcut Clipboard-P2P-Synchronisation

## 1. Ziel und Verbindlichkeit

Dieser Plan setzt `docs/clipboard-p2p-sync-konzept.md` in eine umsetzbare, plattformübergreifende Spezifikation um. Ziel sind zwei unabhängig entwickelte Anwendungen – Floatcut für macOS und eine Implementierung auf einer weiteren Plattform –, die ohne Cloud, Konto oder Vermittlungsserver direkt miteinander kommunizieren.

Die in den Abschnitten **„Normative Protokollfestlegung“**, **„Pairing“**, **„Geräteidentität und TLS“** und **„Kompatibilitätstests“** genannten Werte und Byteformate sind für beide Implementierungen verbindlich. Begriffe wie **MUSS**, **DARF NICHT**, **SOLL** und **KANN** sind entsprechend RFC 2119 zu verstehen. Eine abweichende technische Wahl darf erst nach gemeinsamer Änderung der Spezifikation und – bei inkompatiblen Änderungen – einer neuen Protokollversion erfolgen.

Nicht Ziel von Version 1 sind Cloud-Synchronisation, Internet-Synchronisation, NAT-Traversal, Relays, Benutzerkonten, Offline-Warteschlangen, Verlaufssynchronisation, Favoritensynchronisation, Bildübertragung oder Weiterleitung über mehrere Geräte.

## 2. Unveränderliche Produktregeln

Beide Implementierungen müssen folgende Regeln unabhängig von UI und Betriebssystem einhalten:

1. Die Kommunikation findet ausschließlich direkt im lokalen Netz statt.
2. Ein Gerät wird erst nach einer auf beiden Geräten bestätigten Kopplung vertrauenswürdig.
3. Alle Verbindungen verwenden TLS 1.3. Ein ungekoppeltes Zertifikat darf ausschließlich während des Pairings und für Pairing-Nachrichten akzeptiert werden.
4. Nach erfolgreichem Pairing wird das Zertifikat strikt gepinnt. Ein abweichendes Zertifikat ist ein Sicherheitsereignis und darf nicht stillschweigend ersetzt werden.
5. Nur neu lokal erfasste Text-Clips werden an gerade verbundene Peers gesendet.
6. Es gibt keine persistente oder nach einem Reconnect nachgeholte Sende-Warteschlange.
7. Ein von einem Peer empfangener Clip darf niemals an einen anderen Peer weitergesendet werden. Das gilt auch dann, wenn die normale Duplikatentfernung deaktiviert ist.
8. Die bestehende lokale Prüfung auf leere, übersprungene oder redundante Inhalte wird vor dem Versand verwendet.
9. Version 1 überträgt ausschließlich UTF-8-Text. Lokale Bilder und sonstige Pasteboard-Typen bleiben lokal.
10. Maximal zehn aktive, gekoppelte Peers werden unterstützt. Widerrufene Peers zählen nicht zum Limit.

## 3. Vorbereitende Spezifikationsartefakte

Vor der Netzwerkimplementierung wird im Repository ein plattformneutraler Ordner `docs/Protocol/` angelegt. Dieser ist die gemeinsame Referenz für beide Agenten und enthält:

- `docs/Protocol/floatcut-sync-v1.md`: vollständige Wire-Spezifikation aus Abschnitt 4 dieses Plans;
- `docs/Protocol/schemas/`: JSON-Schemas für jeden Nachrichtentyp;
- `docs/Protocol/fixtures/valid/`: gültige, vollständig gerahmte Beispielnachrichten als Binärdateien und lesbares JSON;
- `docs/Protocol/fixtures/invalid/`: zu große Frames, ungültiges UTF-8, falsche Hashes, unbekannte Pflichtversionen und unzulässige Nachrichtenfolgen;
- `docs/Protocol/fixtures/pairing-vectors.json`: Eingaben und erwartete Ergebnisse für Pairing-Transcript, SHA-256 und Vergleichscode;
- `docs/Protocol/CONFORMANCE.md`: Checkliste, die beide Implementierungen vor einem gemeinsamen Testlauf ausfüllen.

Die Artefakte dürfen keine plattformspezifischen Swift-, Objective-C-, C#- oder anderen Laufzeittypen enthalten. UUIDs, Zeitstempel, Binärdarstellungen und Zeichenkodierung werden dort als Bytes bzw. JSON-Werte festgelegt.

**Hinweis an den Agenten der anderen Plattform:** Implementiere zuerst Codec, Framing und die Pairing-Testvektoren gegen diese Dateien. Beginne erst danach mit Discovery, Clipboard-API und UI. Dadurch werden Protokollabweichungen entdeckt, bevor sie in plattformspezifischem Code verborgen sind.

## 4. Normative Protokollfestlegung (Version 1)

### 4.1 Discovery über DNS-SD/mDNS

Verbindlicher Diensttyp:

```text
_floatcutsync._tcp
```

Der Port wird ausschließlich über den DNS-SD-SRV-Eintrag bekanntgegeben. Die TXT-Daten enthalten genau die folgenden definierten Schlüssel:

| Schlüssel | Format | Bedeutung |
|---|---|---|
| `id` | kanonische UUID in Kleinbuchstaben | dauerhafte Geräte-ID |
| `pv` | `1` | höchste unterstützte Protokoll-Hauptversion |
| `platform` | kurze ASCII-Kennung, z. B. `macos`, `windows`, `linux` | Anzeige und Diagnose |
| `caps` | kommaseparierte ASCII-Werte | in v1 exakt `clip.text.utf8` |
| `pair` | `0` oder `1` | ob neue Pairing-Anfragen derzeit erlaubt sind |

Der DNS-SD-Instanzname ist ein lesbarer Gerätename mit kurzer ID als Suffix, beispielsweise `MacBook – a1b2c3d4`. Er ist nicht sicherheitsrelevant. Anzeigenamen sind auf 64 UTF-8-Bytes zu begrenzen, beim Anzeigen als nicht vertrauenswürdiger Text zu behandeln und dürfen niemals als Geräteidentität verwendet werden.

Clipboard-Inhalte, Zertifikate, Schlüssel, Pairing-Codes oder Benutzerdaten dürfen nicht in TXT-Einträgen erscheinen. Unbekannte TXT-Schlüssel werden ignoriert. Geräte mit unbekannter `pv` werden sichtbar als inkompatibel angezeigt, aber nicht für Clipboard-Daten verbunden.

Die veröffentlichte DNS-SD-Record-Kette muss standardkonform und vollständig sein. Insbesondere darf das SRV-Ziel **nicht** erneut der Service-Instanzname sein:

```text
PTR  _floatcutsync._tcp.local.
  -> <instance>._floatcutsync._tcp.local.
SRV  <instance>._floatcutsync._tcp.local.
  -> <host>.local.:<port>
TXT  <instance>._floatcutsync._tcp.local.
A/AAAA <host>.local.
  -> tatsächlich erreichbare Listener-Adresse(n)
```

Ein SRV-Ziel wie `<instance>._floatcutsync._tcp.local.` kann in Browsern zwar als sichtbarer Dienst erscheinen, ist aber kein Hostname. In realen Tests blieb die anschließende Verbindung dadurch in `preparing` und lief erst nach dem Timeout aus. Der Agent der anderen Plattform muss deshalb PTR, SRV, TXT sowie A/AAAA getrennt prüfen und darf „im Browser sichtbar“ nicht mit „auflösbar und erreichbar“ gleichsetzen.

Der Listener soll IPv4 und IPv6 akzeptieren. Ist echtes Dual-Stack auf der Plattform nicht möglich, dürfen nur Adressen veröffentlicht werden, auf denen derselbe Port tatsächlich lauscht. Discovery-Entfernen/Neu-Hinzufügen ist ein normaler Netzwechsel und weder Entkopplung noch Identitätswechsel; sichtbare Geräte müssen anhand der Geräte-ID dedupliziert und bei Remove-Events sauber entfernt werden.

### 4.2 Transport und Framing

- Direkte TCP-Verbindung mit TLS 1.3.
- Keine WebSockets, kein HTTP, kein UDP-Datentransport und keine zeilenbasierte JSON-Kodierung.
- Jede Anwendungsnachricht besteht aus einem 4 Byte langen, vorzeichenlosen Big-Endian-Längenfeld, gefolgt von exakt so vielen Bytes UTF-8-kodiertem JSON.
- Das Längenfeld bezeichnet nur den JSON-Payload, nicht die vier Präfixbytes.
- Maximale Frame-Länge: `1_048_576` Bytes. Ein größerer Wert wird vor Speicherallokation abgewiesen und die Verbindung geschlossen.
- JSON-Objekte dürfen höchstens acht Ebenen tief verschachtelt sein.
- JSON-Schlüsselreihenfolge ist semantisch ohne Bedeutung. Doppelte Schlüssel sind ungültig.
- Zahlen müssen als JSON-Integer ohne Exponent übertragen werden. Zeitwerte bleiben unter `2^53` und sind dadurch auch in JavaScript-Laufzeiten exakt darstellbar.
- Keine Kompression in Version 1.

Jede Nachricht enthält mindestens:

```json
{
  "v": 1,
  "type": "HELLO",
  "message_id": "01234567-89ab-4cde-8f01-23456789abcd"
}
```

`message_id` ist eine zufällige UUIDv4 in kanonischer Kleinschreibung. Unbekannte optionale Felder müssen ignoriert werden. Eine unbekannte Nachricht bei `v: 1` führt zu `ERROR` mit `code: "unknown_message_type"`; die Verbindung darf anschließend bestehen bleiben. Eine nicht unterstützte Hauptversion erlaubt nur `ERROR` mit `code: "incompatible_version"`, danach wird geschlossen.

### 4.3 Einheitliche Datendarstellungen

- Geräte-, Clip-, Request-, Revocation- und Message-IDs: UUIDv4, Format `8-4-4-4-12`, hexadezimal in Kleinbuchstaben.
- Zeitstempel: Millisekunden seit Unix-Epoch UTC als JSON-Integer; sie dienen nur Anzeige/Diagnose, nicht Konfliktauflösung oder Sortierung zwischen Geräten.
- SHA-256-Werte und Zertifikat-Fingerprints: exakt 64 Hex-Zeichen in Kleinbuchstaben.
- Zufalls-Nonces: exakt 32 Byte, Base64url ohne `=`-Padding.
- Text: JSON-String, bei Kodierung strikt UTF-8. Keine Unicode-Normalisierung, keine Änderung von CR/LF und kein automatisches Trimmen.
- Gerätenamen: maximal 64 UTF-8-Bytes; längere Namen werden lokal vor Versand an einer gültigen Unicode-Grenze gekürzt.

### 4.4 Verbindliche Nachrichtentypen

#### `HELLO`

Wird unmittelbar nach aufgebautem TLS-Kanal von beiden Seiten gesendet, bevor andere Anwendungsnachrichten verarbeitet werden.

```json
{
  "v": 1,
  "type": "HELLO",
  "message_id": "...",
  "device_id": "...",
  "device_name": "MacBook – a1b2c3d4",
  "platform": "macos",
  "capabilities": ["clip.text.utf8"],
  "certificate_sha256": "64 lowercase hex characters",
  "session_nonce": "base64url-without-padding"
}
```

Die Geräte-ID MUSS mit der URI im Zertifikat übereinstimmen, der Fingerprint MUSS dem tatsächlich im TLS-Kanal präsentierten Zertifikat entsprechen. Abweichungen beenden die Verbindung.

#### Pairing-Nachrichten

`PAIR_REQUEST`:

```json
{
  "v": 1,
  "type": "PAIR_REQUEST",
  "message_id": "...",
  "request_id": "...",
  "initiator_nonce": "32-byte-base64url"
}
```

`PAIR_CHALLENGE` ergänzt dieselbe `request_id` und `acceptor_nonce`. `PAIR_CONFIRM` enthält `request_id` und `transcript_sha256`. `PAIR_STATUS` enthält `request_id`, `transcript_sha256` und `state` mit `confirmed` oder `complete`; diese Nachricht dient ausschließlich der unten beschriebenen Wiederaufnahme nach einem Verbindungsabbruch. `PAIR_COMPLETE` enthält `request_id` und `transcript_sha256`. `PAIR_REJECT` enthält `request_id` und einen der Codes `user_rejected`, `timeout`, `peer_limit`, `pairing_disabled`, `already_paired` oder `invalid_request`.

Nur Nachrichten der aktiven Pairing-State-Machine dürfen verarbeitet werden. Eine Pairing-Anfrage läuft nach 120 Sekunden ab. Parallel darf pro Peer nur eine Anfrage existieren. `PAIR_COMPLETE` ist für dieselbe `request_id` und denselben Transcript-Hash terminal und idempotent: Trifft es nach dem eigenen Abschluss bereits im Zustand `Trusted` ein, wird es ohne erneute Persistenz und ohne `ERROR/invalid_state` akzeptiert. Ein abweichendes `PAIR_COMPLETE` bleibt ein Zustandsfehler.

#### `CLIPBOARD_UPDATE`

```json
{
  "v": 1,
  "type": "CLIPBOARD_UPDATE",
  "message_id": "...",
  "clip_id": "...",
  "source_device_id": "...",
  "created_at_ms": 1788253200000,
  "content_type": "text/plain;charset=utf-8",
  "utf8_size": 12,
  "content_sha256": "64 lowercase hex characters",
  "hop_count": 0,
  "content": "Hello world!"
}
```

Verbindliche Prüfungen:

- nur auf einer vollständig gekoppelten und gepinnten Verbindung zulässig;
- `source_device_id` muss der authentifizierte direkte Peer sein;
- `hop_count` muss exakt `0` sein;
- `content_type` muss exakt `text/plain;charset=utf-8` sein;
- `content` muss zwischen 1 und `524_288` UTF-8-Bytes lang sein;
- `utf8_size` und `content_sha256` müssen nach eigener UTF-8-Kodierung exakt stimmen;
- ein bereits in der sitzungsweiten Replay-Liste bekannter `clip_id` wird nicht erneut angewendet.

Der Empfänger antwortet optional diagnostisch mit `CLIPBOARD_ACK`, Felder `clip_id` und `status`. Zulässige Statuswerte sind `applied`, `duplicate`, `skipped`, `unsupported` und `invalid`. Ein ACK löst niemals eine Wiederholung aus. Bei einem Verbindungsabbruch wird der Clip nicht für später gespeichert.

#### Verbindungs- und Verwaltungsnachrichten

- `PING`: enthält `sent_at_ms`; Antwort `PONG` übernimmt dieselbe `message_id` als `reply_to`.
- `UNPAIR`: enthält `revocation_id`, `revoked_at_ms` und optional `reason: "user_request"`.
- `UNPAIR_ACK`: enthält dieselbe `revocation_id`.
- `ERROR`: enthält `code`, eine nicht sensible Kurzbeschreibung `detail` und optional `reply_to`.

Fehlercodes mindestens: `invalid_frame`, `invalid_json`, `incompatible_version`, `unknown_message_type`, `not_paired`, `identity_mismatch`, `invalid_state`, `payload_too_large`, `hash_mismatch`, `rate_limited`.

### 4.5 Reihenfolge und Verbindungszustand

Der Parser implementiert explizit diese Zustände:

```text
TCP/TLS -> AwaitingHello -> Pairing | Trusted -> Closing
```

`CLIPBOARD_UPDATE` ist nur in `Trusted` erlaubt. Vorher werden ausschließlich `HELLO`, passende Pairing-Nachrichten einschließlich `PAIR_STATUS`, `UNPAIR`, `UNPAIR_ACK`, `PING`, `PONG` und `ERROR` akzeptiert. Pro Verbindung werden Nachrichten seriell in Empfangsreihenfolge verarbeitet; eine globale Reihenfolge über mehrere Peers existiert nicht.

Um doppelte Dauerverbindungen zu vermeiden, ist bei bereits gekoppelten Geräten ausschließlich das Gerät mit der lexikografisch kleineren kanonischen Geräte-UUID der aktive Verbindungsinitiator. Das größere Gerät lauscht. Eine Verbindung, die dieser Regel widerspricht, wird nach `HELLO` geschlossen. Für die initiale Pairing-Verbindung darf der Benutzer-Initiator unabhängig von der UUID verbinden.

Reconnect nach Verbindungsverlust: exponentiell mit Jitter bei ungefähr 1, 2, 4, 8, 16 und maximal 30 Sekunden. Verlässt der Peer die Discovery, wird der Versuch ausgesetzt. `PING` wird nach 30 Sekunden ohne Nutzdaten gesendet; nach 90 Sekunden ohne empfangene Daten gilt die Verbindung als verloren.

Der Verbindungsaufbau vor einem vollständigen `HELLO` benötigt einen eigenen kurzen Timeout; als interoperabel erprobter Richtwert gelten 15 Sekunden. Dieser Timeout ist vom 120-Sekunden-Pairing-Timeout getrennt. Die Implementierung muss mindestens `opening/resolving`, `connecting/preparing`, `TLS ready`, `HELLO received` und `peer identified` unterscheidbar machen. So lassen sich DNS-SD-/Firewall-/Berechtigungsfehler von einem Protokollfehler nach aufgebautem TLS trennen. Mehrfaches Klicken auf „Koppeln“ darf keine parallelen Verbindungen zum selben Peer öffnen; eine bereits aktive oder aufbauende Verbindung wird stattdessen sichtbar gemeldet.

Die Replay-Liste umfasst maximal 2.048 `message_id`/`clip_id`-Werte oder zehn Minuten und bleibt ausschließlich im RAM. Sie ist keine Offline-Warteschlange.

## 5. Geräteidentität und TLS

### 5.1 Dauerhafte lokale Identität

Beim ersten Aktivieren der Funktion erzeugt jedes Gerät:

- eine UUIDv4 als dauerhafte `device_id`;
- ein nicht exportierbares ECDSA-P-256-Schlüsselpaar;
- ein selbstsigniertes X.509-Endzertifikat mit SHA-256/ECDSA;
- eine Gültigkeit von zehn Jahren, `CA=false`, Key Usage `digitalSignature`, Extended Key Usage `serverAuth` und `clientAuth`;
- Subject Alternative Name `URI:urn:floatcut:device:<device_id>`.

Der private Schlüssel muss in der nativen sicheren Ablage liegen. Auf macOS: Keychain/Security Framework, nach Möglichkeit mit nicht exportierbarem `SecKey`. Auf Windows: CNG/Windows Certificate Store; DPAPI nur, falls die gewählte TLS-Bibliothek zwingend einen geschützten Key-Blob benötigt. Auf anderen Plattformen ist das jeweilige native Secret-/Key-Storage zu verwenden.

Das Zertifikat bleibt über App-Neustarts und Updates stabil. Kann die Identität nicht mehr geladen werden, darf nicht automatisch eine neue Identität gegenüber bekannten Peers ausgegeben werden. Die UI meldet „Lokale Sync-Identität nicht verfügbar“ und bietet eine bewusste Rücksetzung, nach der alle Peers neu gekoppelt werden müssen.

Neben der Persistenz der Protokollidentität muss auch die **Anwendungsidentität gegenüber dem nativen Secure Store über Updates stabil bleiben**. Beim macOS-Interop-Test führte eine pro Build wechselnde Ad-hoc-Codesignatur dazu, dass ein vorhandener privater Sync-Schlüssel nach dem Ersetzen des AppBundles nicht mehr zugreifbar war. Lokale und produktive Builds müssen deshalb mit einer stabilen Codesigning-Identität bzw. Designated Requirement gebaut werden. Auf Windows sind dieselben Upgrade-Tests mit der gewählten Paket-/Publisher-Identität und CNG-/Certificate-Store-ACL durchzuführen; auf anderen Plattformen entsprechend mit der Bindung des nativen Secret Stores.

Das Codesigning-/Paket-Zertifikat ist strikt von der selbstsignierten Floatcut-TLS-Geräteidentität zu trennen und darf nicht als Protokollschlüssel verwendet werden. Nach dem einmaligen Wechsel von einer instabilen Build-Signatur auf eine stabile Signatur kann eine bewusste Sync-Identitätsrücksetzung noch einmal erforderlich sein. Danach muss ein erneutes Ersetzen der Anwendung durch einen gleich signierten Build die Geräte-ID, den TLS-Schlüssel und alle Pins erhalten.

Eine bewusste Identitätsrücksetzung erzeugt immer eine neue Geräte-ID und ein neues TLS-Zertifikat. Andere Peers behandeln dies als neues Gerät und behalten den alten, nun offline sichtbaren Peer bis zum manuellen Widerruf/Entfernen. Anzeigename, Hostname oder Plattform dürfen niemals benutzt werden, um den neuen Peer still mit dem alten Vertrauenseintrag zu verknüpfen.

**Frühes Technik-Risiko:** Die Erzeugung einer `SecIdentity` aus einem programmatisch erzeugten selbstsignierten Zertifikat muss auf macOS als erster technischer Spike validiert werden. Falls dafür ein kleiner X.509-DER-Builder oder eine geprüfte Bibliothek nötig ist, muss deren Umfang und Lizenz vor der restlichen Implementierung feststehen. Niemals `openssl` als Laufzeitabhängigkeit oder Shell-Prozess in der App verwenden.

### 5.2 Zertifikatsprüfung und Pinning

TLS verwendet gegenseitige Client-/Server-Zertifikate. Während einer Pairing-Verbindung darf die normale CA-Kettenprüfung durch folgende eng begrenzte Prüfung ersetzt werden: Zertifikat ist selbstsigniert und kryptografisch gültig, aktuell gültig, ECDSA P-256, besitzt die geforderten Key Usages und die Geräte-URI. Bis zum abgeschlossenen Pairing bleibt der Kanal untrusted und darf keine Clipboard-Nachricht verarbeiten.

Nach Pairing wird pro Peer mindestens gespeichert:

- Geräte-ID;
- SHA-256-Fingerprint des vollständigen DER-Zertifikats;
- Zertifikat bzw. öffentlicher Schlüssel;
- Anzeigename und Plattform;
- Pairing-Zeitpunkt, zuletzt gesehen, Fähigkeiten und Aktivierungsstatus.

Bei jeder späteren Verbindung müssen Geräte-ID, Zertifikats-URI und Fingerprint exakt übereinstimmen. Ein unbekanntes oder geändertes Zertifikat erzeugt den Zustand `identity_mismatch`, beendet die Verbindung und zeigt eine Warnung. Es gibt keinen „trotzdem verbinden“-Knopf. Nur „Peer entfernen und neu koppeln“ darf diesen Zustand auflösen.

## 6. Pairing mit Vergleichscode

### 6.1 Ablauf

1. Initiator wählt ein entdecktes Gerät, erzeugt `request_id` und 32 zufällige Byte `initiator_nonce`, öffnet einen Pairing-TLS-Kanal und sendet `HELLO`, danach `PAIR_REQUEST`.
2. Empfänger zeigt Gerätename, Plattform und eine Annahme-/Ablehnen-Abfrage. Erst nach Annahme erzeugt er 32 zufällige Byte `acceptor_nonce` und sendet `PAIR_CHALLENGE`.
3. Beide Seiten berechnen aus exakt denselben Binärwerten den Transcript-Hash und zeigen den sechsstelligen Code.
4. Auf beiden Geräten muss der Benutzer bestätigen, dass die Codes gleich sind. Jede Seite sendet danach `PAIR_CONFIRM` mit dem vollständigen Transcript-Hash.
5. Nach der lokalen Bestätigung wird ein auf zehn Minuten begrenzter Pending-Datensatz mit `request_id`, Transcript-Hash, Geräte-ID und Zertifikat-Pin atomar gespeichert. Er ist noch nicht `Trusted` und berechtigt nicht zum Empfang von Clipboard-Daten.
6. Erst wenn lokale Bestätigung, entfernte Bestätigung und identischer Hash vorliegen, wird der Peer atomar auf `complete` gesetzt. Beide Seiten senden `PAIR_COMPLETE`; erst dann wechselt der Kanal zu `Trusted`. Da beide Sends gleichzeitig eintreffen können, ist das passende fremde `PAIR_COMPLETE` auch nach dem lokalen Wechsel nach `Trusted` eine gültige, folgenlose Abschlussbestätigung. Es darf weder eine zweite Kopplung erzeugen noch die Verbindung schließen.
7. Der vollständige Pending-Datensatz bleibt nach einem erfolgreichen Abschluss noch zehn Minuten persistent. Bricht die Verbindung zwischen oder unmittelbar nach den Bestätigungen ab, darf ausschließlich mit derselben Geräte-ID und demselben gepinnten Zertifikat fortgesetzt werden. Nach Reconnect senden beide Seiten `PAIR_STATUS` für den Pending-Datensatz. `confirmed` bedeutet „lokal bestätigt“, `complete` bedeutet „beide Bestätigungen lagen bereits vor“. Ein empfangenes `complete` mit identischem Transcript hebt den eigenen `confirmed`-Datensatz auf `complete`; zwei `confirmed`-Zustände tauschen erneut `PAIR_CONFIRM` aus und schließen das Pairing ab. Eine Referenz-/Fremdimplementierung, die ihren vollständigen Pending-Datensatz früher kompakt hält, MUSS `PAIR_STATUS: complete` eines bereits gepinnten Peers idempotent mit `PAIR_COMPLETE` beantworten. Abweichende IDs, Pins oder Hashes verwerfen den Pending-Datensatz und erfordern ein neues Pairing. Ein abgelaufener Pending-Datensatz wird gelöscht und ebenfalls nicht automatisch fortgeführt.

Aus dem Floatcut↔Python-Realtest ergeben sich vier zusätzliche Persistenzinvarianten:

- Der Empfang von `PAIR_CONFIRM`, `PAIR_STATUS` oder `PAIR_COMPLETE` darf niemals eine lokale Benutzerbestätigung erfinden. `local_confirmed=true` entsteht ausschließlich durch eine lokale, bewusste Codebestätigung.
- Sobald beide Bestätigungen vorliegen, werden zuerst die terminalen Pending-Flags (`local_confirmed`, `remote_confirmed`, vollständiger Transcript-/Pin-Kontext) atomar gespeichert und erst danach der dauerhafte Peer-Eintrag angelegt. Ein Absturz zwischen diesen Schreibvorgängen darf keinen scheinbar gekoppelten Peer mit unvollständigem Resume-Zustand erzeugen.
- Existiert aus einer älteren Implementierung bereits ein korrekt gepinnter Peer-Datensatz, aber ein unvollständiger Pending-Datensatz derselben `request_id`, desselben Pins und desselben Transcript-Hashs, darf dieser Zustand als terminal repariert werden. Die Reparatur darf nur aus dem bereits persistenten Pin abgeleitet werden, nicht aus einer neuen unbestätigten Netzwerkbehauptung.
- Passende `PAIR_COMPLETE`-Nachrichten können nahezu gleichzeitig in beide Richtungen laufen. Deshalb muss der Handler auch nach dem eigenen Wechsel zu `Trusted` noch exakt dieselbe Abschlussnachricht akzeptieren. Der Realtest zeigte erwartungsgemäß je ein lokales Senden und ein anschließendes Empfangen von `PAIR_COMPLETE`, ohne Verbindungsabbruch.

### 6.2 Exakte Code-Berechnung

Der Eingabebytestrom ist ohne Längenfelder und ohne JSON-Kanonisierung:

```text
ASCII("FLOATCUT-PAIR-V1\0")
|| initiator_device_id as 16 RFC-4122 bytes
|| initiator_certificate_sha256 as 32 raw bytes
|| initiator_nonce as 32 raw bytes
|| acceptor_device_id as 16 RFC-4122 bytes
|| acceptor_certificate_sha256 as 32 raw bytes
|| acceptor_nonce as 32 raw bytes
```

Dann:

```text
transcript_sha256 = SHA-256(input)
comparison_number = uint32_big_endian(transcript_sha256[0..3]) mod 1_000_000
comparison_code = comparison_number as zero-padded 6 decimal digits
```

Normativer Testvektor:

```text
initiator_device_id: 00112233-4455-6677-8899-aabbccddeeff
initiator_certificate_sha256 bytes: 00 01 02 ... 1f
initiator_nonce bytes:              20 21 22 ... 3f
acceptor_device_id: ffeeddcc-bbaa-9988-7766-554433221100
acceptor_certificate_sha256 bytes:  40 41 42 ... 5f
acceptor_nonce bytes:               60 61 62 ... 7f
input length: 177 bytes
transcript_sha256: 36794c2420c79ca869dd9655453b500589149947b0a22e36c2c365f4657755e1
comparison_code: 919012
```

**Hinweis an den anderen Agenten:** UUIDs dürfen hierfür nicht als Text und unter Windows nicht in der internen GUID-Feldreihenfolge serialisiert werden. Verwendet werden die 16 RFC-4122-Netzwerkbytes in der sichtbaren Hex-Reihenfolge.

## 7. Entkopplung und Widerruf

Beim lokalen Entkoppeln wird sofort ein persistenter Tombstone erzeugt: `peer_device_id`, bisheriger Fingerprint, `revocation_id`, `revoked_at_ms`, `acknowledged=false`. Ab diesem Moment werden alle Clipboard-Nachrichten dieses Peers blockiert.

- Ist der Peer online, wird `UNPAIR` gesendet. Der Empfänger entfernt den Peer, legt ebenfalls einen Widerrufszustand an und antwortet `UNPAIR_ACK`.
- Ist er offline, bleibt der Tombstone erhalten. Bei späterer Discovery darf eine ausschließlich für Widerruf zulässige Verbindung aufgebaut werden, um `UNPAIR` zuzustellen.
- Ein Tombstone wird nicht zeitgesteuert still gelöscht. Ein bewusstes neues Pairing darf ihn nach erneuter Codebestätigung ersetzen.
- Ein widerrufener Peer darf keine alte Vertrauensbeziehung durch ein verzögertes Paket oder einen alten lokalen Store wiederherstellen.

Die UI unterscheidet „entkoppelt“, „Widerruf noch nicht zugestellt“ und „Widerruf bestätigt“. Das Entfernen eines Peers löscht keine Clipboard-Historie.

## 8. Integration in Floatcut (macOS)

### 8.1 Zielarchitektur

Neue Swift-Komponenten unter einem eigenen Bereich, beispielsweise `Sync/`:

- `SyncIdentityStore`: lokale Geräte-ID, `SecIdentity`, Zertifikat-Fingerprint;
- `PeerStore`: atomare persistente Peer-Metadaten;
- `RevocationStore`: persistente Tombstones;
- `SyncProtocolCodec` und `SyncFrameDecoder`: strikt plattformneutrale Kodierung/Validierung;
- `SyncDiscoveryService`: `NWBrowser`, Bonjour-Auflösung und deduplizierte Gerätesicht;
- `SyncListener`: `NWListener` mit TLS und Service-Ankündigung;
- `PeerConnection`: TLS-Verbindung, Framing, State-Machine, Pinning, Keepalive und Backoff;
- `PairingManager`: genau ein Pairing-State-Machine-Ablauf pro Peer;
- `ClipboardSyncCoordinator`: verbindet Netzwerkereignisse mit dem bestehenden Floatcut-Clipboardpfad;
- `SyncPreferencesModel`: UI-Zustand ohne Netzwerklogik.

Network.framework übernimmt Listener, Browser und TCP/TLS. Security Framework/Keychain verwaltet Schlüssel und Zertifikate; CryptoKit kann SHA-256, Nonces und P-256-Hilfsoperationen übernehmen. Netzwerk- und Dateiarbeit läuft nicht auf dem Main Thread. Alle `NSPasteboard`- und UI-Zugriffe werden explizit auf den Main Thread serialisiert.

Erforderliche Projektanpassungen:

- Network.framework und Security.framework verlinken;
- `NSLocalNetworkUsageDescription` mit verständlicher Erklärung ergänzen;
- `NSBonjourServices` mit `_floatcutsync._tcp` ergänzen;
- Objective-C/Swift-Brücke nur über kleine, `@objc`-fähige Interfaces erweitern;
- keine Änderung an Bundle-ID, bestehender Preference-Migration oder lokalem Store-Format erzwingen.

### 8.2 Gemeinsamer Clipboard-Verarbeitungspfad

Das bestehende Polling in `AppController.m` bleibt notwendig, insbesondere für Inhalte, die durch Universal Clipboard/Handoff ohne lokalen Copy-Hotkey eintreffen. Es wird nicht durch Event-Hooks ersetzt.

Die Verarbeitung wird konzeptionell in einen gemeinsamen Eingang mit expliziter Herkunft aufgeteilt:

```text
ClipboardOrigin.localOS
ClipboardOrigin.remote(peerID, clipID)
```

Lokaler Ablauf:

1. `NSPasteboard.changeCount` wie bisher beobachten und die Typen zur Materialisierung von Universal-Clipboard-Inhalten abfragen.
2. Bestehende `shouldSkip`-Prüfung durchführen.
3. Inhalt über den bestehenden Floatcut-Store aufnehmen; nur ein tatsächlich akzeptierter lokaler Text-Clip löst `didAcceptLocalClip` aus.
4. Der Coordinator erstellt genau ein `CLIPBOARD_UPDATE` und sendet es einmal an jeden aktuell verbundenen, aktivierten und vertrauenswürdigen Peer.
5. Kein Peer verbunden: Nachricht verwerfen, nicht persistieren und nicht später nachsenden.

Entfernter Ablauf:

1. Protokoll, Pin, Größe, Hash, Replay-ID und Ein-Hop-Regel validieren.
2. Inhalt mit `ClipboardOrigin.remote` an den lokalen Storepfad übergeben. Bestehende lokale Deduplizierung darf verhindern, dass derselbe Verlaufseintrag erneut angelegt wird.
3. Den Inhalt trotzdem auf das System-Pasteboard schreiben, damit die eigentliche Clipboard-Synchronisation funktioniert.
4. Den dabei entstehenden `changeCount` als Remote-/Self-Write markieren, bevor das Polling ihn als lokalen Benutzer-Clip behandeln kann. Der Zugriff muss auf dem Main Thread atomar geordnet sein.
5. Wegen der Herkunft `remote` darf unter keinen Umständen `didAcceptLocalClip` ausgelöst werden – auch nicht bei deaktivierter Duplikatentfernung, zeitgleichen Peers oder einem später beobachteten Pasteboard-Event.
6. Remote-Clips werden als normaler Verlaufseintrag mit dem Peer-Anzeigenamen als Quelle gespeichert, niemals automatisch als Favorit. Ein fremder App-Pfad oder Bundle-Identifier wird nicht übernommen.

Die heutige boolesche Rückgabe von `addClipping` sollte für die Integration durch ein internes Resultat wie `accepted`, `duplicate`, `skipped` oder `empty` ergänzt werden. Bestehende Aufrufer können weiterhin eine boolesche Fassade verwenden. Das Resultat dient nur ACK und Diagnose; ein Remote-Clip wird nie zurückgesendet.

Für parallele Remote-Schreibvorgänge wird nicht nur ein einzelner globaler boolescher Schalter verwendet. Stattdessen führt der Coordinator eine begrenzte Liste selbst geschriebener Pasteboard-`changeCount`-Werte bzw. einen auf dem Main Thread geschützten Write-Token. Damit kann ein unmittelbar folgendes echtes lokales Copy-Ereignis nicht versehentlich unterdrückt werden.

### 8.3 Einstellungen und Bedienoberfläche

In der Einstellungs-Sidebar kommt ein Bereich „Synchronisation“ hinzu:

- Hauptschalter, standardmäßig aus;
- lokaler Gerätename;
- Status der lokalen Netzwerkberechtigung;
- Liste „Gekoppelte Geräte“ mit online/offline, Plattform, zuletzt gesehen, Aktivschalter und „Entkoppeln“;
- Liste „Verfügbare Geräte“ mit „Koppeln“;
- eingehende Pairing-Anfrage, Codeanzeige und Bestätigung auf beiden Geräten;
- nach „Koppeln“ sofort sichtbarer Status „Verbindung wird hergestellt“, anschließend „Verbunden“ erst nach `Trusted`; eine bereits aktive Verbindung oder ein Verbindungsfehler wird sichtbar statt still ignoriert;
- verständliche Zustände für Peer-Limit, inkompatible Version, Zertifikatswechsel und ausstehenden Widerruf;
- bewusste Funktion „Sync-Identität zurücksetzen“ mit Warnung, dass danach alle Peers neu gekoppelt werden müssen;
- ein Identitätsfehler verweist direkt auf diese Rücksetzfunktion; nach erfolgreicher Rücksetzung verschwindet die Warnung im selben UI-Zyklus und der neue Status wird nicht erst nach Fenster- oder App-Neustart sichtbar;
- optional aktivierbares detailliertes Sync-Diagnoselog für Discovery, Verbindungsaufbau, TLS/HELLO, Pairing, Keepalive und Widerruf, mit klarer Anzeige des Speicherorts und einer Funktion zum Deaktivieren.

Die Pairing- und Sync-Funktion darf keine Clipboard-Inhalte in Geräteansichten oder Benachrichtigungen anzeigen. Wenn Floatcuts vorhandene Clipboard-Erfassung über das Menü pausiert wird, pausieren in Version 1 sowohl Senden als auch Anwenden empfangener Clips; Discovery und Geräteverwaltung dürfen aktiv bleiben. Dies verhindert überraschende Clipboard-Änderungen bei bewusst pausierter Anwendung.

## 9. Hinweise für die Implementierung auf der anderen Plattform

Die andere Implementierung darf intern eine vollständig andere Architektur besitzen. Folgende Grenzen sind jedoch nicht austauschbar:

- identischer DNS-SD-Diensttyp und identische TXT-Werte;
- TLS 1.3 mit ECDSA-P-256-Identitäten und identischem Zertifikat-Pinning;
- exakt dasselbe 4-Byte-Framing und UTF-8-JSON;
- exakt dieselben Feldnamen, Enumerationen, Limits und Bytekodierungen;
- identische Pairing-Transcript-Berechnung;
- direkte Peer-Quelle und `hop_count: 0`;
- keine Queue, kein History-Backfill und kein Weiterleiten empfangener Inhalte;
- unveränderte Textbytes hinsichtlich Normalisierung und Zeilenenden.

Für eine Windows-Implementierung besonders beachten:

- Clipboard-Beobachtung und -Schreiben müssen auf einem STA-Thread mit Message Loop erfolgen.
- Der Windows-Clipboard-Sequence-Number bzw. ein anwendungsinternes Write-Token muss Remote-Schreibvorgänge markieren; ein einfacher Zeitfilter ist nicht ausreichend.
- Eine .NET-/Schannel-Lösung muss vorab nachweisen, dass gegenseitiges TLS 1.3 mit selbstsignierten Zertifikaten und einer eigenen Pin-Prüfung ohne globale Lockerung der Zertifikatsvalidierung funktioniert.
- Schlüssel vorzugsweise über CNG und den Windows Certificate Store erzeugen und nicht als frei lesbare PFX-Datei ablegen.
- Die gewählte mDNS-API muss DNS-SD-SRV/TXT korrekt unterstützen; ein fest kodierter Port oder Broadcast-Ersatz ist inkompatibel.
- Windows-Zeilenenden dürfen empfangenen Text nicht verändern. Der Inhalt aus JSON wird exakt als Unicode-Text ins Clipboard geschrieben.

Für Linux oder andere Plattformen gelten entsprechend ein nativer Secret Store, ein mDNS/DNS-SD-Stack, TLS 1.3 mit Custom Pin Validation und eine Clipboard-API mit expliziter Remote-Origin-Unterdrückung. Fehlt eine sichere Schlüsselablage, ist das ein blockierendes Plattformproblem und kein Grund, Schlüssel ungeschützt zu speichern.

Der andere Agent soll eine kurze `docs/PLATFORM_NOTES.md` liefern, die für jede normative Anforderung die verwendete Betriebssystem-API und die Abweichungsfreiheit dokumentiert.

## 10. Speicherung, Datenschutz und Logging

Persistiert werden nur Identität, Peer-Metadaten, Einstellungen und Widerrufstombstones. Nicht persistiert werden ausgehende Netzwerkqueues, empfangene Protokollframes oder zusätzliche Sync-Verläufe. Der existierende lokale Floatcut-Verlauf bleibt davon unberührt und folgt weiter dessen Aufbewahrungsregeln.

Logs dürfen enthalten: Zeit, lokale/entfernte Geräte-ID gekürzt, Nachrichtentyp, Byteanzahl, Zustandswechsel, Fehlercode, Fingerprint gekürzt und Latenz. Logs dürfen niemals enthalten: Clipboard-Inhalt, vollständige Hashes, Nonces, Vergleichscodes, private Schlüssel oder vollständige Zertifikate. Produktionslogging verwendet strukturierte Kategorien und eine begrenzte Rotation.

Für plattformübergreifende Fehlersuche soll jede Implementierung ein opt-in aktivierbares, maschinenlesbares JSONL-Diagnoselog anbieten. Zeitstempel müssen UTC enthalten; ein zufälliger `run_id`, eine gekürzte Peer-ID und eine lokale `connection_id` erlauben Korrelation, ohne Geheimnisse offenzulegen. Mindestens folgende Ereignisgruppen müssen unterscheidbar sein:

- Discovery: Service hinzugefügt/aktualisiert/entfernt, Anzahl kompatibler Peers, aufgelöster Host, Adressfamilie und Port;
- Transport: `connection_opening`, Namensauflösung, `connection_preparing`, `connection_ready`, Vor-HELLO-Timeout, Abbruch und Ende;
- Protokoll: Nachrichtentyp gesendet/empfangen, `peer_identified`, State-Machine-Übergang und redigierter Fehlercode;
- Pairing: Anfrage initiiert/empfangen, lokale Annahme, Code dargestellt (ohne Code), lokale Bestätigung, entfernte Bestätigung, Abschluss und Resume;
- Betrieb: `PING`/`PONG`, Online-/Offline-Übergang, Widerruf erzeugt/gesendet/bestätigt sowie Identität geladen/zurückgesetzt.

Gerätename und vollständige lokale IP-Adresse sollten nur dann geloggt werden, wenn dies für den ausdrücklich aktivierten Diagnosemodus erforderlich ist. Auch im Diagnosemodus bleiben Vergleichscode, Nonces, Transcript-Hash, vollständiger Zertifikat-Fingerprint und Clipboard-Daten verboten. Ein normaler Produktionsstart darf nicht ungefragt dauerhaft auf Debug-Level loggen.

Empfohlene Schutzgrenzen:

- maximal fünf neue Verbindungen pro IP und Minute;
- maximal drei gleichzeitige Pairing-Anfragen;
- maximal eine Pairing-Anfrage je Geräte-ID;
- Eingangsbuffer hart auf Frame-Limit begrenzen;
- JSON vollständig validieren, bevor UI oder Clipboard angesprochen werden;
- Gerätenamen und Fehlertexte beim Anzeigen niemals als Markup interpretieren.

## 11. Teststrategie und gemeinsame Abnahmekriterien

### 11.1 Tests je Implementierung

1. **Codec/Framing:** fragmentierte Präfixe, mehrere Frames in einem Read, leere/zu große Frames, ungültiges UTF-8, doppelte JSON-Schlüssel, unbekannte Felder.
2. **Kryptografie:** Zertifikatsprofil, Fingerprint, Base64url, UUID-Bytes, normativer Pairing-Vektor, manipulierte Nonces und Hashes.
3. **State Machine:** Clipboard vor HELLO/Pairing, falsche Nachricht in jedem Zustand, Timeout, Reject, paralleles Pairing, Reconnect sowie simultane `PAIR_CONFIRM`/`PAIR_COMPLETE`-Nachrichten. Ein passendes terminales `PAIR_COMPLETE` im Zustand `Trusted` darf die Verbindung nicht schließen.
4. **Pinning:** bekanntes Zertifikat akzeptiert; neuer Schlüssel bei gleicher Geräte-ID blockiert; falsche SAN blockiert; abgelaufenes Zertifikat blockiert.
5. **Clipboard:** Unicode inklusive Emoji und kombinierender Zeichen, CR/LF-Erhalt, 1 Byte, exakt 512 KiB, 512 KiB + 1, leerer Inhalt, Hash-/Längenfehler.
6. **Loop-Schutz:** Remote-Write erzeugt lokales Clipboard-Event, wird aber nie gesendet; funktioniert mit deaktivierter Duplikatentfernung.
7. **Persistenz:** Neustart erhält Identität und Pins; keine Nachricht wird nach Neustart nachgeholt; Tombstones überleben Neustarts.
8. **Robustheit:** Parser-Fuzzing, langsame/fragmentierte Gegenstelle, abrupter Disconnect, zehn Peers, elfter Peer abgewiesen.

### 11.2 Verbindliche Cross-Platform-Matrix

Vor Freigabe müssen echte Builds beider Plattformen gemeinsam folgende Fälle bestehen:

| Fall | Erwartung |
|---|---|
| Discovery in beide Richtungen | Name, ID, Plattform und Fähigkeit identisch sichtbar |
| DNS-SD-Record-Kette | SRV zeigt auf einen per A/AAAA auflösbaren Host, nicht auf die Service-Instanz; der veröffentlichte Port ist erreichbar |
| IPv4 und IPv6 | Verbindung funktioniert über jede veröffentlichte Adressfamilie; unerreichbare Familien werden nicht beworben |
| Pairing von macOS initiiert | auf beiden Geräten Code `919012` für den Fixture-Test; reales Pairing speichert Pins |
| Pairing von Fremdplattform initiiert | identisches Verhalten und kein zweiter Peer-Datensatz |
| Doppelklick während Verbindungsaufbau | exakt eine Verbindung; zweite Aktion meldet den aktiven Aufbau statt still nichts zu tun |
| Simultanes `PAIR_COMPLETE` | beide Peers bleiben nach dem Atom-Commit verbunden; kein `ERROR/invalid_state` und kein Offline-Status |
| Reconnect mit vollständigem Pending-Datensatz | `PAIR_STATUS: complete` wird mit bestehendem Pin sicher abgeschlossen; der Peer wird danach online angezeigt |
| Lokale Bestätigung fehlt | entferntes `PAIR_STATUS`/`PAIR_COMPLETE` erzeugt keine lokale Bestätigung und keinen Trusted-Peer |
| Keepalive nach Pairing | `PING`/`PONG` hält den offenen Trusted-Kanal online und wird auf beiden Seiten diagnostisch sichtbar |
| Text macOS → andere Plattform | exakter UTF-8-Inhalt einmal angewendet |
| Text andere Plattform → macOS | exakter UTF-8-Inhalt einmal angewendet |
| Dreieck A–B–C | von A an B empfangener Clip wird von B niemals an C weitergesendet |
| Deduplizierung aus | weiterhin keine Schleife oder Weiterleitung |
| Empfänger offline | Clip wird nicht nach Reconnect nachgeliefert |
| Zwei gleichzeitige Verbindungen | UUID-Regel lässt exakt eine vertrauenswürdige Verbindung bestehen |
| Zertifikat geändert | Verbindung blockiert, sichtbare Warnung, kein Clipboard-Zugriff |
| Update mit stabiler App-Signatur | vorhandene Geräte-ID und privater TLS-Schlüssel bleiben ohne Reset zugreifbar; Pins bleiben gültig |
| Wechsel von instabiler auf stabile Signatur | genau eine bewusst geführte Rücksetzung ist möglich; Warnung verschwindet sofort; keine automatische Ersatzidentität |
| Identität bewusst zurückgesetzt | Gegenstelle erkennt eine neue Geräte-ID und behält den alten Peer getrennt, bis er manuell entfernt wird |
| Offline entkoppelt | lokale Sperre sofort; Widerruf beim nächsten Sichtkontakt zugestellt |
| Unbekannte optionale Felder | Nachricht wird weiterhin verarbeitet |
| `v: 2` gegen v1 | verständliche Inkompatibilität, keine Datenübertragung |
| Diagnose-Redaktion | Pairing und Texttransfer sind nachvollziehbar, aber Code, Nonces, Hashes, Schlüssel und Inhalt fehlen vollständig im Log |

Für den Dreieckstest werden Netzwerklogs verwendet, nicht nur sichtbare Clipboard-Ergebnisse. Dadurch wird nachgewiesen, dass B keinen Frame an C sendet und nicht nur ein Duplikat verwirft.

### 11.3 Erkenntnisse und schneller Interoperabilitäts-Testablauf

Am 2. September 2026 wurde ein reales Pairing zwischen Floatcut auf macOS und dem Python-Referenzclient aus dem eigenständigen Repository `Floatcut-SRC` durchgeführt. Dabei wurden gegenseitiges TLS 1.3, `HELLO`, eine von Floatcut initiierte `PAIR_REQUEST`, beidseitiger sechsstelliger Codevergleich, beide `PAIR_CONFIRM`-Nachrichten, idempotente `PAIR_COMPLETE`-Nachrichten sowie ein anschließend offener `Trusted`-Kanal mit `PING`/`PONG` beobachtet. Beide Seiten persistierten Peer und terminalen Pending-Zustand. Der konkrete Laufzeitcode war nur sitzungsbezogen und ist ausdrücklich **kein** Testvektor; ausschließlich `919012` aus Abschnitt 6.2 ist normativ.

Auf demselben Trusted-Kanal empfing der Referenzclient außerdem ein echtes `CLIPBOARD_UPDATE`, verwarf den Inhalt wie für das Protokoll-Orakel vorgesehen und antwortete mit `CLIPBOARD_ACK/unsupported`. Bei der anschließend in Floatcut ausgelösten Entkopplung empfing er `UNPAIR`, antwortete mit `UNPAIR_ACK`, entfernte die aktive Verbindung und den aktuellen Peer-Eintrag und persistierte einen Tombstone mit `acknowledged=true`. Ein älterer Peer-Eintrag der vorangegangenen, zurückgesetzten Floatcut-Identität blieb davon unberührt. Dies bestätigt sowohl die Trennung nach Geräte-ID als auch die Regel, dass ein Namensgleichheit keine Identitäten zusammenführt.

Der Agent der anderen Plattform soll für den ersten gemeinsamen Lauf exakt diese Reihenfolge verwenden:

1. Mit einem frischen, eindeutig benannten State-Verzeichnis starten und `doctor`/Secure-Store-Selbsttest ausführen. Den Python-Referenzclient für LAN-Tests außerhalb einer App-Sandbox starten, weil Multicast dort sonst irreführend blockiert sein kann.
2. Lokale-Netzwerk-, eingehende-Verbindungs- und Drittanbieter-Firewall-Dialoge auf beiden Seiten bewusst freigeben. Bei einem hängenden Verbindungsaufbau zuerst diese Ebene sowie SRV/A/AAAA prüfen, nicht sofort Pairing oder TLS ändern.
3. Discovery in beide Richtungen prüfen. Service-ID, SRV-Ziel, Hostauflösung, Port und tatsächlich gewählte Adressfamilie protokollieren. Einen Remove/Add-Zyklus durch Stoppen und Neustarten einer Seite testen.
4. Pairing von Plattform A initiieren. Auf B muss eine konkrete eingehende Session sichtbar werden; beim Referenzclient mit `connections` prüfen und erst dann `accept <session-id>` ausführen. Ein empfangener `PAIR_REQUEST` kann vor Annahme nur im aktiven Sessionzustand liegen und muss daher nicht bereits im persistenten Pending-Store stehen.
5. Den auf beiden Seiten dargestellten Code als Mensch vergleichen. Erst bei Gleichheit auf beiden Seiten bestätigen (`confirm <session-id> <code>` im Referenzclient). Den Code weder in automatisierten Logs noch in Bugreports speichern.
6. In beiden Logs nachweisen: je eine lokale und entfernte Bestätigung, atomare Persistenz, `PAIR_COMPLETE` in beide Richtungen und Übergang zu `Trusted`. `connections` muss den Peer mit `trusted=True` zeigen; ein Peer-Datensatz allein beweist keinen Online-Zustand.
7. Mindestens bis zum nächsten `PING`/`PONG` verbunden bleiben. Danach beide Prozesse einzeln neu starten und prüfen, dass der kanonische UUID-Initiator genau eine Verbindung wiederherstellt.
8. Den identischen Ablauf in umgekehrter Initiatorrichtung wiederholen. Anschließend Verbindungsabbruch zwischen Bestätigung und Abschluss provozieren und `PAIR_STATUS`-Resume prüfen.
9. Online- und Offline-Widerruf testen. Erst danach eine lokale Identitätsrücksetzung testen; die Gegenstelle muss anschließend alten und neuen Peer anhand der Geräte-ID getrennt behandeln.
10. Zuletzt die Anwendung durch einen neu gebauten, gleich signierten Build ersetzen. Wenn dafür erneut eine Sync-Identitätsrücksetzung erforderlich ist, ist die Paket-/Secure-Store-Identität noch nicht updatefest und das Plattform-Gate nicht bestanden.

Typische Fehlerbilder und die zuerst zu prüfende Ursache:

| Beobachtung | Zuerst prüfen |
|---|---|
| Dienst sichtbar, Verbindung bleibt in `preparing` | SRV-Ziel ist fälschlich Service-FQDN; fehlendes A/AAAA; Listener nicht auf beworbener Adressfamilie; Firewall-/Local-Network-Dialog |
| Klick auf „Koppeln“ wirkt ohne Reaktion | bereits aktive/aufbauende Verbindung; fehlende UI-Abbildung des Zustands; Vor-HELLO-Timeout und dessen Fehlermeldung |
| Anfrage geloggt, aber Pending-Datei leer | vor Benutzerannahme zulässiger Session-Zustand; Session-ID in der aktiven Verbindung anzeigen/abfragen |
| Nach beidseitiger Bestätigung sofort offline | terminales fremdes `PAIR_COMPLETE` nach lokalem `Trusted` fälschlich als `invalid_state` behandelt; Peer vor Pending-Flags persistiert |
| Nach Reconnect bleibt Pairing pending | vollständigen Pending-Datensatz zehn Minuten halten; `PAIR_STATUS: complete` idempotent beantworten; niemals lokale Bestätigung aus Remote-Status erfinden |
| Peer gekoppelt, aber UI zeigt offline | Peer-Store nicht mit aktiver Trusted-Verbindung verwechseln; `PING`/`PONG`, kanonische UUID-Richtung und Connection-Lifecycle prüfen |
| `UNPAIR_ACK` gesendet, Peer weiterhin online | Verbindung nach ACK nicht geschlossen/entfernt; Peer-Store und Connection-Registry nicht gemeinsam aktualisiert; Tombstone nicht atomar persistiert |
| Sync-Identität nach App-Update nicht verfügbar | wechselnde Codesigning-/Paketidentität oder Secure-Store-ACL; nicht automatisch neue TLS-Identität erzeugen |
| Nach Identitätsreset doppelter Gerätename | erwartete neue Geräte-ID; alten Peer explizit widerrufen/entfernen, niemals nach Namen zusammenführen |

Der Python-Referenzclient ist dabei ein Protokoll-Orakel, keine Produktimplementierung: Er wird einschließlich seines eigenen Implementierungsplans separat in `Floatcut-SRC` gepflegt, simuliert Discovery, Pairing, Resume und Widerruf, wendet aber keine Clipboard-Daten an. Für Automatisierung soll `--control-format jsonl` verwendet werden; für den ersten manuellen Lauf sind `devices`, `connections`, `pending`, `peers`, `accept`, `confirm` und `revoke` die wichtigsten Befehle. Jeder Lauf erhält ein eigenes State-Verzeichnis, damit alte Peer- und Pending-Datensätze ein frisches Ergebnis nicht verfälschen.

## 12. Umsetzungsphasen und Arbeitspakete

### Phase 0 – Spezifikation einfrieren

- Wire-Dokument, Schemas, gültige/ungültige Fixtures und Pairing-Vektor anlegen.
- Beide Agenten bestätigen schriftlich alle normativen Entscheidungen.
- Je Plattform einen kleinen Headless-Codec-Test gegen dieselben Fixtures ausführen.

**Gate:** Kein Discovery-/TLS-/UI-Code, bevor beide Codec-Tests identische Ergebnisse liefern.

### Phase 1 – Identität und Speicher

- lokale Geräte-ID, P-256-Schlüssel und X.509-Zertifikat erzeugen;
- sichere Persistenz und Wiederherstellung testen;
- `PeerStore` und `RevocationStore` mit atomaren Schreibvorgängen implementieren;
- Zertifikatsprofil gegenseitig mit Standardwerkzeugen prüfen.

**Gate:** Beide Plattformen können ihr Zertifikat exportfrei verwenden und den Fingerprint der jeweils anderen Testdatei identisch berechnen.

### Phase 2 – Discovery und TLS-Grundkanal

- Listener, Browser, TXT-Auswertung und Berechtigungsführung implementieren;
- Framing über TLS mit `HELLO`, `PING` und `ERROR` verbinden;
- Duplicate-Connection-Regel, Timeouts und Backoff umsetzen;
- untrusted Pairing-Kanal strikt vom Trusted-Datenkanal trennen.

**Gate:** Gegenseitiges `HELLO` über echten LAN-Verkehr; noch keine Clipboard-Daten.

### Phase 3 – Pairing und Pinning

- komplette Pairing-State-Machine einschließlich beidseitiger UI-Bestätigung;
- terminales, idempotentes `PAIR_COMPLETE`, zehnminütige Aufbewahrung vollständiger Pending-Datensätze und Resume-Test gegen eine Gegenstelle mit abweichender Bereinigungszeit;
- sichtbare Pairing-Statusführung für Verbindungsaufbau, aktive Verbindung, erfolgreichen Trusted-Zustand und Fehler;
- Transcript und sechsstelligen Code aus gemeinsamen Testvektoren prüfen;
- Peer atomar speichern, bekannte Verbindungen pinnen;
- Identity-Mismatch und Pairing-Timeout testen.

**Gate:** Pairing in beiden Initiatorrichtungen, simultaner Abschluss ohne Verbindungsabbruch, Reconnect aus `PAIR_STATUS: complete` sowie negativer MITM-/Zertifikatswechseltest bestanden. Ein Gerät darf erst als online gelten, wenn ein offener `Trusted`-Kanal besteht.

### Phase 4 – Einweg-Textübertragung je Richtung

- `CLIPBOARD_UPDATE` validieren und anwenden;
- Floatcut an vorhandenen Polling-/Storepfad anbinden;
- andere Plattform an nativen Clipboard-Eventpfad anbinden;
- Limits, Hash, ACK-Diagnose und fehlende Offline-Queue prüfen.

**Gate:** Exakte Textübertragung macOS → Fremdplattform und zurück, inklusive Unicode/Zeilenenden.

### Phase 5 – Loop-Schutz und Mehrgerätebetrieb

- Origin-Markierung vollständig umsetzen;
- Dreieckstest und deaktivierte lokale Deduplizierung;
- Fan-out an bis zu zehn direkt verbundene Peers;
- Replay-Cache, Rate Limits und Race-Tests ergänzen.

**Gate:** Kein empfangener Clip erzeugt unter irgendeiner getesteten Einstellung einen ausgehenden Clipboard-Frame.

### Phase 6 – Entkopplung, UI und Fehlerführung

- Online-/Offline-Widerruf, Tombstones und erneutes bewusstes Pairing;
- Einstellungsoberflächen, Statusanzeigen, Berechtigungs- und Sicherheitswarnungen;
- barrierefreie Labels, Lokalisierung und dauerhaft englisch/technisch stabile Protokollwerte trennen;
- Datenschutzkonformes Logging.

**Gate:** vollständige Cross-Platform-Matrix und Neustarttests bestanden.

### Phase 7 – Stabilisierung, abschließende UI-Arbeiten und Freigabe

- Parser und State Machine fuzz-/lasttesten;
- reale Netzübergänge, Sleep/Wake, WLAN-Wechsel und App-Neustart prüfen;
- Energie- und CPU-Verbrauch messen; Discovery/Keepalive dürfen das bestehende Polling nicht verschlechtern;
- Protokoll-Dokumentation und Conformance-Checklisten final gegen implementierten Code abgleichen.

#### Abschließende UI- und UX-Arbeiten

Diese Arbeiten ändern das Wire-Protokoll nicht. Sie sind lokal je Plattform umzusetzen, müssen aber dieselbe Bedeutung und Herkunftslogik verwenden:

1. **Eigener Diagnosebereich:** In der Einstellungs-Sidebar wird ein eigener Bereich „Diagnose“/„Diagnostics“ angelegt. Die Option zum Erfassen von Zwischenablage-Typen wird aus den allgemeinen Erfassungseinstellungen dorthin verschoben. Das detaillierte Sync-Logging einschließlich redigiertem Datenschutzhinweis und auswählbarem/angezeigtem Logpfad wird aus der Synchronisationsseite ebenfalls dorthin verschoben. Die Zwischenablage-Typdiagnose bleibt deaktiviert, solange der Passwortfeld-Filter ausgeschaltet ist, weil der zugrunde liegende Erfassungspfad nur in diesem Fall ausgeführt wird.
2. **Verständliche Lokalisierung:** Die bisher missverständliche Passwortoption wird sinngemäß als „Passwortähnliche Inhalte anhand von Länge und Zeichenarten erkennen“ bezeichnet; die eingetragene Liste beschreibt „Zu ignorierende Passwortlängen“. Die Pasteboard-Diagnose heißt sinngemäß „Zwischenablage-Typen im Verlauf erfassen“, das Netzwerklogging „Detaillierte Sync-Protokollierung aktivieren“. Deutsch und Englisch müssen vollständig gepflegt werden; technische Protokollwerte, Nachrichtentypen und Dateiformate bleiben unübersetzt.
3. **Widerrufe mit Zeitpunkt:** Die Widerrufsansicht verwendet drei über alle Zeilen ausgerichtete Spalten: gekürzte Geräte-ID, lokalisierter Widerrufszeitpunkt sowie Zustell-/Bestätigungsstatus. Datum und Uhrzeit werden ohne zusätzlichen Wochentag angezeigt. Die vorhandene Sortierung `revoked_at_ms` absteigend bleibt bestehen. Die Liste scrollt mit der Einstellungsseite; bestätigte Tombstones werden nicht allein wegen ihres Alters gelöscht.
4. **Persistente Herkunft empfangener Clips:** Ein über `CLIPBOARD_UPDATE` empfangener und lokal akzeptierter Clip erhält ein explizites lokales Herkunftsmerkmal wie `received_from_sync=true`. Dieses Merkmal wird zusammen mit dem lokalen Verlauf gespeichert, beim Laden wiederhergestellt und beim Kopieren/Verschieben in den Favoritenspeicher erhalten. Es ist kein neues Wire-Feld. Alte Floatcut-Einträge ohne Merkmal dürfen einmalig anhand der bisherigen lokalen Quellenkennung `Sync: <peer name>` migriert werden; neue Implementierungen dürfen Anzeigenamen danach nicht als primäre Herkunftserkennung verwenden.
5. **Konfigurierbarer Sync-Rahmen:** Empfangene Sync-Clips erhalten im Menü-Popover und in der Suchliste einen dezenten farbigen Rahmen. Der Rahmen wird als innenliegendes Overlay (`strokeBorder` bzw. plattformäquivalent) mit 1 px Breite gezeichnet und darf weder Zeilenhöhe noch -breite, Scrollposition oder Trefferlayout verändern. Er gilt auch für aus einem Remote-Clip erzeugte Favoriten. Farbe wird über den nativen System-Farbwähler konfiguriert, Transparenz separat als lokales Preference-Feld. Änderungen sollen in bereits geöffneten SwiftUI-/nativen Listen unmittelbar sichtbar werden. Farbe und Transparenz werden niemals an Peers übertragen.
6. **Darstellungs- und Upgradeprüfung:** Rahmen in Hell-/Dunkelmodus, bei Hover, Auswahl, langen lokalisierten Statuszeilen und in beiden Stores prüfen. Einen gespeicherten Remote-Clip über App-Neustart und gleich signiertes App-Update hinweg testen. Lokale Clips dürfen keinen Sync-Rahmen erhalten; Duplikat-, Favoriten- und Suchlogik dürfen durch das zusätzliche Herkunftsfeld nicht verändert werden.
7. **Auslieferbares Bundle:** Nach Abschluss werden Engine-/Protokolltests, String-Datei-Validierung, Universal-Build und Signaturprüfung ausgeführt. Das AppBundle muss mit derselben stabilen lokalen bzw. produktiven Anwendungsidentität signiert werden, die bereits im Update-Test verwendet wurde.

**Gate:** Beide Plattformteams signieren dieselbe `CONFORMANCE.md`; die abschließenden UI-Punkte sind auf der jeweiligen Plattform geprüft und ein updatefest signiertes/paketiertes Bundle wurde erzeugt. Erst danach wird Sync v1 als kompatibel freigegeben.

## 13. Empfohlene Aufgabenteilung zwischen den Agenten

Gemeinsam bzw. zuerst durch den Floatcut-Agenten:

- normative `docs/Protocol/`-Artefakte und Referenzfixtures;
- Testvektoren und Cross-Platform-Testskript;
- Änderungsprozess für das Protokoll.

Floatcut-Agent:

- macOS Keychain/`SecIdentity`-Spike;
- Network.framework Discovery, Listener und Verbindung;
- sichere Einbindung in `AppController`/`FloatcutOperator` ohne Regression des Handoff-Pollings;
- SwiftUI-Einstellungen und macOS-Berechtigungstexte;
- macOS-App-Bundle- und Regressionstests.

Agent der anderen Plattform:

- unabhängige Implementierung des Codecs gegen dieselben Fixtures;
- native sichere Identität, mDNS, TLS und Clipboard-Origin-Markierung;
- plattformspezifische Berechtigungs- und Hintergrundregeln;
- `docs/PLATFORM_NOTES.md` und automatisierbarer Headless-Conformance-Test.

Beide Agenten dürfen Protokolländerungen nicht unilateral „praktischer“ gestalten. Entsteht ein Plattformhindernis, wird zuerst ein minimales reproduzierbares Interoperabilitätsproblem dokumentiert. Eine gemeinsame Änderung erhält eine Spezifikationsrevision; inkompatible Änderungen erhalten `v: 2` und `pv=2`, statt Version 1 still umzudeuten.

## 14. Definition of Done

Die Implementierung gilt erst als abgeschlossen, wenn:

- alle Produktregeln aus Abschnitt 2 automatisiert oder durch einen dokumentierten Integrationstest abgesichert sind;
- beide Anwendungen dieselben Protokollfixtures bytegenau lesen und semantisch gleich schreiben;
- Pairing, Pinning, Zertifikatswechsel und Widerruf in beiden Richtungen getestet wurden;
- neue lokale Texte bidirektional übertragen werden, ohne Offline-Nachlieferung;
- im Dreigeräteaufbau keine Mehrfachweiterleitung stattfindet;
- das bestehende Floatcut-Polling einschließlich Universal Clipboard/Handoff unverändert funktioniert;
- Bilder, Verlauf, Favoriten und übersprungene/sensible Inhalte nicht übertragen werden;
- keine Clipboard-Inhalte oder Geheimnisse in Logs, Discovery oder Peer-Metadaten landen;
- der Diagnosebereich die Pasteboard- und Sync-Protokollierung verständlich bündelt und vollständig lokalisiert ist;
- Widerrufe mit lokalisiertem Zeitpunkt in stabiler Neueste-zuerst-Reihenfolge angezeigt werden, ohne Tombstones zeitgesteuert zu löschen;
- die persistente Remote-Herkunft ausschließlich empfangene Clips kennzeichnet und beim Neustart sowie beim Wechsel in den Favoritenspeicher erhalten bleibt;
- der konfigurierbare Sync-Rahmen Menü- und Suchzeilen nicht vergrößert und Farbe/Transparenz rein lokale Darstellungspräferenzen bleiben;
- die Cross-Platform-Matrix vollständig grün ist und beide Agenten die gemeinsame Conformance-Checkliste bestätigt haben.
