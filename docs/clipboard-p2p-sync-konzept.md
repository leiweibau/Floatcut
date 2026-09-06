# Konzept: Lokale Peer-to-Peer-Synchronisation für Clipboard Manager

## 1. Ziel

Dieses Dokument beschreibt ein plattformunabhängiges Konzept zur lokalen
Synchronisation von Clipboard-Einträgen zwischen mehreren Instanzen
eines Clipboard Managers.

Ausgangspunkt sind mindestens zwei bestehende Anwendungen für macOS und
Windows. Die konkrete Implementierung soll auf Basis dieses Konzepts
durch einen Entwicklungs-Agenten erfolgen. Das Konzept definiert deshalb
primär Verhalten, Zustände, Sicherheitsanforderungen und
Protokollregeln; konkrete Frameworks, Programmiersprachen und
Bibliotheken sollen passend zu den vorhandenen Codebasen gewählt werden.

### Kernziele

-   Plattformübergreifende Kommunikation zwischen macOS- und
    Windows-Versionen.
-   Vollständig lokaler Betrieb ohne Cloud- oder zentralen
    Vermittlungsserver.
-   Automatische Erkennung kompatibler Instanzen im lokalen Netzwerk.
-   Explizites Pairing mit Zustimmung beider Seiten.
-   Verschlüsselte und authentisierte Kommunikation.
-   Persistente Pairings über Neustarts hinweg.
-   Bidirektionale Übertragung neuer Clipboard-Einträge.
-   Maximal ein Netzwerk-Hop pro Clip.
-   Sauberes Offline-Verhalten ohne nachträgliche Synchronisation
    verpasster Clips.
-   Pairings können von beiden Seiten unabhängig beendet werden.
-   Bestehende lokale Redundanzprüfung des Clipboard Managers wird in
    den Synchronisationsfluss integriert.
-   Softwareseitige Begrenzung auf maximal 10 gepairte Peers pro
    Instanz.

------------------------------------------------------------------------

## 2. Grundarchitektur

Jede Installation arbeitet als gleichberechtigter Peer. Es existiert
kein Master, kein zentraler Server und keine zentrale Datenbank.

``` text
┌───────────────────────────────┐
│ Clipboard Manager             │
│                               │
│  Clipboard Monitor            │
│          │                    │
│          ▼                    │
│  lokale Verarbeitung /        │
│  Redundanzprüfung             │
│          │                    │
│          ▼                    │
│  Clipboard Sync Engine        │
│       │          │            │
│       │          └─ Peer Store│
│       ▼                       │
│  TLS Transport                │
│       │                       │
│       ▼                       │
│  mDNS / DNS-SD Discovery      │
└───────────────────────────────┘
```

Jede Instanz kann gleichzeitig Verbindungen zu mehreren anderen
Instanzen besitzen.

Die maximale Anzahl gepairter Geräte wird zunächst softwareseitig auf
**10 Peers pro Instanz** begrenzt.

------------------------------------------------------------------------

## 3. Peer-to-Peer-Modell

Pairings sind direkte Beziehungen zwischen zwei Instanzen.

Beispiel:

``` text
A ───── B
│
├───── C
│
└───── D
```

A ist direkt mit B, C und D gepairt.

Es besteht daraus **keine automatische Vertrauensbeziehung** zwischen B,
C und D.

Insbesondere ist die Synchronisation kein geroutetes Mesh-Netzwerk.

------------------------------------------------------------------------

## 4. Ein-Hop-Regel

Ein Clip darf maximal **einen Netzwerk-Hop** zurücklegen.

Ein lokal erzeugter Clip wird an alle direkt gepairten und aktuell
erreichbaren Peers übertragen. Ein über das Sync-Protokoll empfangener
Clip darf niemals erneut an andere Peers weitergeleitet werden.

Beispiel:

``` text
A ─── paired ─── B ─── paired ─── C

A kopiert "Hallo"

A → B     erlaubt
B → C     NICHT erlaubt
```

Wenn A zusätzlich direkt mit C gepairt ist:

``` text
      B
     /
    A
     \
      C
```

dann gilt:

``` text
A → B
A → C
```

Beide Übertragungen stammen direkt vom Ursprungsgerät A.

Diese Regel ist unabhängig davon, ob der empfangene Clip anschließend
durch das Betriebssystem als Änderung der lokalen Zwischenablage
gemeldet wird.

------------------------------------------------------------------------

## 5. Discovery

### 5.1 Verfahren

Für die automatische Erkennung im lokalen Netzwerk soll **mDNS/DNS-SD**
verwendet werden.

Eine laufende Instanz veröffentlicht einen eigenen Service,
beispielsweise:

``` text
_clipboardsync._tcp.local
```

Der endgültige Servicename ist implementationsspezifisch festzulegen und
sollte projektspezifisch sowie möglichst kollisionsarm sein.

### 5.2 Veröffentlichte Informationen

Über Discovery dürfen nur Informationen veröffentlicht werden, die für
Erkennung und Verbindungsaufbau erforderlich sind, beispielsweise:

-   Device-ID
-   Anzeigename
-   Plattform
-   Protokollversion
-   TCP-Port
-   optionale Capability-/Feature-Versionen

Keine Clipboard-Inhalte oder geheimen Pairing-Informationen dürfen über
mDNS veröffentlicht werden.

### 5.3 Discovery ist kein Vertrauen

Ein gefundenes Gerät ist zunächst ausschließlich:

``` text
DISCOVERED_UNPAIRED
```

Discovery allein berechtigt niemals zum Empfang von Clipboard-Daten.

------------------------------------------------------------------------

## 6. Permanente Geräteidentität

Jede Installation erzeugt bei der initialen Einrichtung eine dauerhafte
kryptographische Identität.

Mindestens erforderlich:

``` text
device_id
private_key
certificate
```

Die `device_id` muss global eindeutig sein, beispielsweise über UUID.

Der private Schlüssel darf die jeweilige Installation nicht verlassen.

### Sichere Speicherung

Plattformspezifische sichere Speichermechanismen sollen verwendet
werden:

-   macOS: Keychain
-   Windows: geeigneter Windows Credential-/Key-Storage, z. B. DPAPI
    bzw. eine passende native API

Normale Konfigurationsdateien sollen keine ungeschützten privaten
Schlüssel enthalten.

------------------------------------------------------------------------

## 7. Pairing

### 7.1 Initiierung

Der Benutzer sieht im Einstellungsfenster per Discovery gefundene
kompatible Instanzen.

Beispiel:

``` text
MacBook Pro            macOS       Unpaired
DESKTOP-1234           Windows     Paired / Online
Notebook               Windows     Paired / Offline
```

Bei einem unpaired Gerät kann der Benutzer eine Pairing-Anfrage
initiieren.

### 7.2 Ablauf

``` text
Gerät A                              Gerät B

Discovery
<---------------------------------->

Pairing-Anfrage
----------------------------------->

                                Benutzerabfrage
                                [Ablehnen]
                                [Bestätigen]

Pairing bestätigt
<-----------------------------------

Authentisierte Verbindung
<==================================>
```

Ein Pairing ist erst erfolgreich, nachdem die Gegenseite ausdrücklich
zugestimmt hat.

### 7.3 Verifikation

Es wird empfohlen, während des initialen Pairings auf beiden Geräten
einen identischen kurzen Verifizierungscode darzustellen,
beispielsweise:

``` text
482 731
```

Der Code muss aus den kryptographisch ausgehandelten Identitäten bzw.
dem Pairing-Vorgang abgeleitet werden und darf nicht lediglich eine frei
übertragene Zahl sein.

Damit kann der Benutzer erkennen, ob tatsächlich dieselben beiden
Endpunkte miteinander kommunizieren.

------------------------------------------------------------------------

## 8. Transportverschlüsselung und Vertrauen

Die Kommunikation muss verschlüsselt erfolgen.

Vorgesehen ist:

``` text
TCP
 ↓
TLS 1.3
 ↓
Clipboard-Sync-Protokoll
```

Alternativ kann ein TLS-basierter bidirektionaler Transport wie
WebSocket Secure verwendet werden, sofern dies besser zu den bestehenden
Anwendungen passt.

### 8.1 Selbstsignierte Zertifikate

Eine öffentliche PKI ist nicht erforderlich.

Die Instanzen dürfen selbstsignierte Zertifikate verwenden. Entscheidend
ist jedoch:

**Die Anwendung darf nicht pauschal allen selbstsignierten Zertifikaten
vertrauen.**

Beim Pairing wird die Identität des konkreten Peers dauerhaft
gespeichert, beispielsweise durch:

-   Public Key bzw. Public-Key-Fingerprint,
-   Certificate Fingerprint,
-   oder ein vergleichbares Key-Pinning-Verfahren.

Bei späteren Verbindungen muss geprüft werden, ob der präsentierte
Schlüssel exakt zur gespeicherten Peer-Identität gehört.

Ein unbekanntes oder geändertes Zertifikat darf nicht automatisch
akzeptiert werden.

------------------------------------------------------------------------

## 9. Persistenter Peer Store

Nach einem erfolgreichen Pairing speichert jede Seite Informationen über
den Peer.

Konzeptionelles Beispiel:

``` json
{
  "device_id": "bf641ea4-91fc-44af-a3fa-d386bfdf8791",
  "name": "Windows-PC",
  "public_key_fingerprint": "SHA256:...",
  "paired": true,
  "last_seen": "2026-08-31T14:00:00Z"
}
```

Der genaue Aufbau richtet sich nach der vorhandenen Architektur.

Das Pairing bleibt über:

-   Programmneustarts,
-   Betriebssystemneustarts,
-   temporäre Netzwerkunterbrechungen

erhalten.

------------------------------------------------------------------------

## 10. Zustandsmodell

Intern sollte nicht lediglich zwischen `paired` und `unpaired`
unterschieden werden.

Empfohlen werden mindestens folgende Zustände:

``` text
DISCOVERED_UNPAIRED
PAIR_REQUEST_SENT
PAIR_REQUEST_RECEIVED
PAIRED_OFFLINE
PAIRED_ONLINE
REVOKED
```

Die UI kann diese Zustände vereinfachen.

Beispielsweise:

``` text
MacBook Pro
● Online

Windows-PC
○ Offline

Notebook
Pairing möglich
```

------------------------------------------------------------------------

## 11. Online-/Offline-Verhalten

Ein gepairter Peer, dessen Anwendung momentan nicht läuft oder der nicht
erreichbar ist, wird nicht als Fehler behandelt.

Der Zustand lautet:

``` text
PAIRED_OFFLINE
```

Sobald die Instanz wieder entdeckt bzw. erreichbar wird:

1.  Device-ID erkennen.
2.  Peer im lokalen Pairing Store finden.
3.  Verbindung aufbauen.
4.  TLS-/Key-Identität prüfen.
5.  Bei erfolgreicher Prüfung auf `PAIRED_ONLINE` wechseln.

Es ist keine erneute Benutzerbestätigung erforderlich, solange die
gespeicherte kryptographische Identität unverändert gültig ist.

------------------------------------------------------------------------

## 12. Keine Offline-Synchronisation

Während ein Peer offline ist, werden für ihn **keine Clipboard-Einträge
gepuffert**.

Beispiel:

``` text
12:00  B offline
12:01  A kopiert Clip 1
12:02  A kopiert Clip 2
12:03  A kopiert Clip 3
12:05  B online
12:06  A kopiert Clip 4
```

B erhält ausschließlich:

``` text
Clip 4
```

Clip 1--3 werden nicht nachträglich übertragen.

Damit ist keine Queue, kein History-Abgleich und keine Conflict
Resolution zwischen Peers erforderlich.

------------------------------------------------------------------------

## 13. Clipboard-Verarbeitung

Die Netzwerkfunktion soll auf der bestehenden Clipboard-Verarbeitung
aufsetzen und diese nicht umgehen.

Der grundlegende Ablauf lautet:

``` text
Clipboard geändert
       │
       ▼
normale lokale Clipboard-Verarbeitung
       │
       ▼
Prüfung: wurde der Clipboard-Inhalt
gerade durch unser Sync-System gesetzt?
       │
       ├── JA → nicht erneut senden
       │
       ▼
bestehende lokale Redundanzprüfung
       │
       ├── Duplikat → kein neuer Clip / kein Sync
       │
       ▼
neuer lokaler Clip
       │
       ▼
an alle direkt gepairten Online-Peers senden
```

### Zentrale Regel

**Nur ein Clipboard-Ereignis, das nach der normalen lokalen Verarbeitung
tatsächlich als neuer zu synchronisierender Clip akzeptiert wurde, darf
ein ausgehendes Sync-Ereignis erzeugen.**

------------------------------------------------------------------------

## 14. Integration der bestehenden Redundanzprüfung

Die vorhandenen Clipboard Manager besitzen standardmäßig eine aktivierte
lokale Redundanzprüfung.

Diese soll ausdrücklich Teil des Sync-Konzepts sein.

Das ist insbesondere unter macOS relevant, weil Apples Universal
Clipboard/Handoff denselben Clipboard-Inhalt auf mehreren Macs
bereitstellen kann.

Beispiel:

``` text
Mac A ── Apple Universal Clipboard ── Mac B

Mac A ────── Windows C
Mac B ────── Windows C
```

Mac A kopiert:

``` text
"Hallo"
```

Möglicher Ablauf:

``` text
Mac A
 ├── lokaler Clipboard Manager nimmt "Hallo" auf
 ├── Sync → Windows C
 └── Apple Universal Clipboard → Mac B
                                  │
                                  ▼
                         Clipboard Manager B
                                  │
                         lokale Redundanzprüfung
```

Erkennt die bestehende Redundanzprüfung auf Mac B den Clip bereits als
redundant, darf daraus kein neuer Netzwerkversand entstehen.

Dadurch wird vermieden, dass Windows C denselben Clip unabhängig von Mac
A und Mac B mehrfach erhält.

------------------------------------------------------------------------

## 15. Universal Clipboard / Handoff

Die Implementierung darf nicht voraussetzen, dass zuverlässig erkannt
werden kann, ob ein neuer macOS-Clipboard-Inhalt:

-   lokal kopiert wurde,
-   über Apple Universal Clipboard/Handoff kam,
-   oder durch eine andere Anwendung gesetzt wurde.

Die Sync-Architektur muss auch ohne diese Information korrekt
funktionieren.

Die bestehende lokale Redundanzprüfung ist daher die erste Schutzschicht
für solche Fälle.

Eine zusätzliche zeitbasierte Content-Hash-Deduplizierung auf
Netzwerkebene ist **nicht zwingend Bestandteil der ersten
Implementierung**.

Sie kann später ergänzt werden, falls praktische Tests zeigen, dass die
lokale Redundanzprüfung bestimmte externe Duplikate nicht ausreichend
erkennt.

------------------------------------------------------------------------

## 16. Schutz vor eigenen Rückkopplungen

Unabhängig von der normalen Redundanzprüfung muss das Sync-System
erkennen, wenn es selbst einen empfangenen Clip in die lokale
Zwischenablage geschrieben hat.

Beispiel:

``` text
A → B

B empfängt Clip
      │
      ▼
B setzt OS-Clipboard
      │
      ▼
OS meldet Clipboard-Änderung
      │
      X
nicht wieder an Peers senden
```

Dafür muss die Implementierung empfangene bzw. selbst gesetzte
Remote-Clips intern markieren oder über eine robuste äquivalente Methode
erkennen.

Diese Schutzfunktion muss auch funktionieren, wenn der Benutzer die
normale lokale Redundanzprüfung deaktiviert.

------------------------------------------------------------------------

## 17. Clip-Identität

Jeder über das Netzwerk übertragene Clip erhält eine eindeutige ID.

Empfohlen:

-   UUIDv7,
-   ULID,
-   oder eine vergleichbare global eindeutige ID.

Konzeptionelles Nachrichtenformat:

``` json
{
  "type": "clipboard_update",
  "protocol_version": 1,
  "clip_id": "019...",
  "source_device_id": "...",
  "timestamp": 1788185762,
  "content_type": "text/plain",
  "data": "Hallo"
}
```

Die `clip_id` dient der eindeutigen Identifikation einer konkreten
Netzwerkübertragung und der Abwehr doppelter Verarbeitung.

Sie ersetzt nicht die lokale Redundanzprüfung.

------------------------------------------------------------------------

## 18. Optionaler Content-Fingerprint

Das Protokoll darf optional einen reproduzierbaren Content-Fingerprint
vorsehen:

``` text
SHA-256(normalisierter Clipboard-Inhalt)
```

Dieser kann für Diagnose, spätere Deduplizierungsstrategien oder
zusätzliche Schutzmechanismen verwendet werden.

Er soll in der ersten Implementierung jedoch nicht automatisch dazu
führen, dass identische Inhalte dauerhaft als derselbe Clip betrachtet
werden.

Ein Benutzer kann denselben Text zu unterschiedlichen Zeitpunkten
bewusst erneut kopieren.

Falls später eine zeitbasierte Hash-Deduplizierung eingeführt wird, muss
das Zeitfenster bewusst klein und konfigurierbar bzw. klar definiert
sein.

------------------------------------------------------------------------

## 19. Bidirektionale Kommunikation

Nach dem Pairing sind beide Peers gleichberechtigt.

``` text
A ↔ B
```

Sowohl A als auch B dürfen neue lokale Clipboard-Einträge an die jeweils
andere Seite senden.

Die Rolle während des Pairings (`initiator` / `acceptor`) hat nach
Abschluss des Pairings keine Bedeutung für die Synchronisationsrechte.

------------------------------------------------------------------------

## 20. Unpairing

Jeder Peer darf ein Pairing unabhängig davon beenden, wer es
ursprünglich initiiert hat.

### 20.1 Gegenstelle online

Wenn beide Peers erreichbar sind:

1.  Peer A beendet das Pairing.
2.  A übermittelt eine authentisierte Revocation-/Unpair-Nachricht an B.
3.  Beide entfernen bzw. deaktivieren die Pairing-Beziehung.
4.  Beide befinden sich anschließend im Zustand `UNPAIRED`.

### 20.2 Gegenstelle offline

Ist B beim Unpairing offline:

1.  A entfernt/deaktiviert das Pairing lokal.
2.  A speichert einen Revocation-Eintrag für B.
3.  B besitzt zunächst noch seinen alten Pairing-Zustand.
4.  Beim nächsten Verbindungsversuch von B erkennt A die widerrufene
    Beziehung.
5.  A teilt B mit, dass das Pairing nicht mehr gültig ist.
6.  B entfernt daraufhin ebenfalls das Pairing.
7.  Beide Seiten können anschließend erneut gepairt werden.

Konzeptioneller Revocation-Datensatz:

``` text
peer_device_id
peer_public_key_fingerprint
revoked_at
```

Ein widerrufener Peer darf sich nicht allein aufgrund alter lokaler
Pairing-Daten wieder als vertrauenswürdig verbinden.

------------------------------------------------------------------------

## 21. Erneutes Pairing

Nach vollständigem Unpairing wird das Gerät wieder als:

``` text
DISCOVERED_UNPAIRED
```

angezeigt.

Ein neues Pairing ist ausdrücklich zulässig.

Dabei muss der normale Pairing- und Verifikationsprozess erneut
durchlaufen werden.

------------------------------------------------------------------------

## 22. Maximale Peer-Anzahl

Pro Instanz gilt zunächst:

``` text
MAX_PAIRED_PEERS = 10
```

Die Begrenzung ist eine Produkt-/Softwareentscheidung und keine
technische Grenze des Netzwerkmodells.

Discovery darf weiterhin mehr Geräte finden. Ist das Pairing-Limit
erreicht, darf jedoch kein zusätzliches Pairing abgeschlossen werden,
bis mindestens eine bestehende Verbindung entfernt wurde.

Die Begrenzung sollte zentral definiert und nicht an mehreren Stellen
hart codiert werden.

------------------------------------------------------------------------

## 23. Protokollversionierung

Das Netzwerkprotokoll muss von Beginn an versioniert sein.

Beispielsweise:

``` text
protocol_version = 1
```

Die Protokollversion soll bereits während Discovery/Handshake verfügbar
sein, damit inkompatible Instanzen erkannt werden können, bevor
Clipboard-Daten übertragen werden.

Für zukünftige Erweiterungen können zusätzlich Capabilities ausgehandelt
werden.

------------------------------------------------------------------------

## 24. Minimale Nachrichtentypen

Die konkrete Codierung ist implementationsabhängig. Konzeptionell werden
mindestens folgende Vorgänge benötigt:

``` text
HELLO / HANDSHAKE
PAIR_REQUEST
PAIR_ACCEPT
PAIR_REJECT
CLIPBOARD_UPDATE
PING / KEEPALIVE
UNPAIR / REVOKE
ERROR / PROTOCOL_ERROR
```

Nicht jeder Vorgang muss zwingend eine eigene Nachricht darstellen, wenn
die verwendete Transport-/TLS-Architektur einen Teil davon bereits
sicher abbildet.

------------------------------------------------------------------------

## 25. Clipboard-Datentypen

Die erste Implementierung sollte bewusst definieren, welche
Clipboard-Typen unterstützt werden.

Empfehlung für Version 1:

``` text
text/plain
```

Weitere Formate wie:

-   HTML,
-   RTF,
-   Bilder,
-   Dateien,
-   mehrere Clipboard-Repräsentationen desselben Inhalts

sollten nur implementiert werden, wenn die vorhandenen Clipboard Manager
diese Daten bereits sauber abstrahieren.

Das Protokoll muss unbekannte oder nicht unterstützte Content Types
kontrolliert ablehnen bzw. ignorieren können.

------------------------------------------------------------------------

## 26. Größenbegrenzungen

Netzwerkdaten müssen Größenlimits besitzen.

Mindestens erforderlich:

-   maximale Nachrichtengröße,
-   maximale Clipboard-Nutzlast,
-   maximale Länge von Gerätenamen und Metadaten.

Ein Peer darf nicht durch beliebig große Clipboard-Daten unbegrenzt
Speicher allozieren können.

Die konkreten Limits sollen anhand der bestehenden Clipboard Manager
festgelegt werden.

------------------------------------------------------------------------

## 27. Sicherheitsanforderungen

Die Implementierung muss mindestens folgende Grundsätze erfüllen:

1.  Keine Clipboard-Daten an ungepairte Geräte.
2.  Keine automatische Vertrauensstellung allein aufgrund von mDNS.
3.  Verschlüsselte Kommunikation.
4.  Persistente kryptographische Geräteidentität.
5.  Pinning der Identität gepairter Peers.
6.  Keine pauschale Akzeptanz beliebiger selbstsignierter Zertifikate.
7.  Explizite Benutzerbestätigung beim initialen Pairing.
8.  Sichere Speicherung privater Schlüssel.
9.  Größenlimits für eingehende Daten.
10. Validierung aller Protokollnachrichten.
11. Unbekannte Nachrichtentypen dürfen keinen undefinierten Zustand
    verursachen.
12. Revocation eines Pairings muss auch bei zeitweise offline
    befindlichen Peers funktionieren.
13. Ein empfangener Remote-Clip darf niemals einen zweiten Netzwerk-Hop
    erzeugen.
14. Discovery-Daten sind grundsätzlich als nicht vertrauenswürdig zu
    behandeln.
15. Änderungen der kryptographischen Peer-Identität dürfen nicht
    stillschweigend akzeptiert werden.

------------------------------------------------------------------------

## 28. Fehlerverhalten

Normale Netzwerkzustände dürfen keine störenden Benutzerfehler erzeugen.

Insbesondere sind folgende Situationen normal:

``` text
Peer nicht gestartet
Peer heruntergefahren
Notebook im Standby
WLAN kurz unterbrochen
Peer verlässt das lokale Netzwerk
Peer erscheint später wieder
```

Diese Zustände führen lediglich zu:

``` text
PAIRED_OFFLINE
```

Protokollverletzungen, Identitätsänderungen oder ungültige Zertifikate
sind dagegen Sicherheitsereignisse und dürfen nicht als normale
Offline-Situation behandelt werden.

------------------------------------------------------------------------

## 29. Logging

Für Implementierung und Fehlersuche sollte strukturiertes Logging
vorgesehen werden.

Sinnvolle Ereignisse:

``` text
peer_discovered
peer_lost
pair_request_received
pair_accepted
pair_rejected
peer_connected
peer_disconnected
peer_identity_mismatch
clipboard_sent
clipboard_received
clipboard_suppressed_remote
clipboard_suppressed_duplicate
peer_unpaired
revocation_delivered
protocol_error
```

Clipboard-Inhalte selbst sollen standardmäßig **nicht** im Log
ausgegeben werden.

IDs, Größen, Content Types und technische Statusinformationen reichen
für die Diagnose normalerweise aus.

------------------------------------------------------------------------

## 30. Datenschutz

Das System ist bewusst lokal ausgelegt.

Es soll:

-   keinen zentralen Sync-Dienst benötigen,
-   keine Clipboard-Inhalte an externe Server übertragen,
-   keine Telemetrie mit Clipboard-Inhalten erzeugen,
-   keine Cloud-Abhängigkeit für Pairing oder Discovery besitzen.

Apple Universal Clipboard kann parallel existieren, ist aber kein
Bestandteil dieses Sync-Protokolls.

------------------------------------------------------------------------

## 31. Empfohlene Modultrennung

Der Entwicklungs-Agent sollte die konkrete Codebasis prüfen und die
Funktionalität möglichst in getrennte Verantwortungsbereiche aufteilen:

``` text
DiscoveryService
PeerIdentity / KeyStore
PairingManager
PeerStore
PeerConnection
SyncProtocol
ClipboardSyncCoordinator
RevocationStore
```

Die Namen sind nur konzeptionell.

Besonders wichtig ist die Trennung zwischen:

``` text
OS Clipboard
     │
Clipboard Manager Core
     │
Sync Coordinator
     │
Network Protocol
```

Die Netzwerkimplementierung soll nicht direkt unabhängig von der
bestehenden Clipboard-Logik auf das Betriebssystem-Clipboard reagieren.

------------------------------------------------------------------------

## 32. Zentrale Invarianten

Die folgenden Regeln sind als feste Invarianten der Implementierung zu
betrachten.

### Invariante 1 -- Kein Vertrauen durch Discovery

``` text
discovered ≠ trusted
```

### Invariante 2 -- Nur gepairte Peers erhalten Clips

``` text
clipboard_send ⇒ peer.paired && peer.authenticated
```

### Invariante 3 -- Maximal ein Hop

``` text
remote_clip ⇒ never_forward
```

### Invariante 4 -- Offline bedeutet keinen Fehler

``` text
paired + unreachable ⇒ PAIRED_OFFLINE
```

### Invariante 5 -- Keine Offline-Queue

``` text
peer offline ⇒ clip wird für diesen Peer verworfen
```

### Invariante 6 -- Pairing-Rollen sind danach irrelevant

``` text
initiator == acceptor
```

bezogen auf spätere Synchronisations- und Unpairing-Rechte.

### Invariante 7 -- Lokale Redundanzprüfung vor Sync

Ein lokal beobachteter Clip darf erst nach der normalen Verarbeitung und
Redundanzentscheidung einen Sync auslösen.

### Invariante 8 -- Eigene Remote-Clips niemals zurücksenden

Diese Regel gilt auch bei deaktivierter lokaler Redundanzprüfung.

### Invariante 9 -- Identitätswechsel erfordert neues Vertrauen

Ein Peer mit derselben Device-ID, aber unerwartet anderem
kryptographischem Schlüssel darf nicht automatisch als derselbe
vertrauenswürdige Peer behandelt werden.

------------------------------------------------------------------------

## 33. Wesentliche Testszenarien

Der Entwicklungs-Agent soll mindestens folgende Szenarien automatisiert
oder reproduzierbar testen.

### Pairing

-   macOS → Windows
-   Windows → macOS
-   macOS → macOS
-   Windows → Windows
-   Pairing akzeptieren
-   Pairing ablehnen
-   Pairing bei erreichtem 10-Peer-Limit
-   ungültige/veränderte Peer-Identität

### Synchronisation

-   A kopiert → B erhält
-   B kopiert → A erhält
-   A ist mit mehreren Peers verbunden → alle Online-Peers erhalten den
    Clip
-   Offline-Peer erhält keinen Clip
-   wiederkehrender Peer erhält erst neue Clips ab Wiederverbindung
-   Remote-Clip wird nicht zurückgesendet
-   Remote-Clip wird nicht an dritten Peer weitergereicht

### Ein-Hop-Test

``` text
A ↔ B ↔ C
```

A kopiert einen Clip.

Erwartung:

``` text
B erhält ihn.
C erhält ihn nicht.
```

### Direkte Mehrfachverbindung

``` text
A ↔ B
A ↔ C
B ↔ C
```

A kopiert.

Erwartung:

``` text
A → B
A → C
```

B und C dürfen den empfangenen Clip nicht nochmals untereinander
übertragen.

### Apple Universal Clipboard / Handoff

Zwei Macs verwenden Apple Universal Clipboard und beide sind mit
demselben dritten Peer gepairt.

Es ist zu prüfen, dass die bestehende lokale Redundanzprüfung die
erwarteten Duplikate verhindert.

Dabei muss insbesondere geprüft werden, wie sich die aktuelle
macOS-Implementierung tatsächlich verhält; das Konzept darf keine nicht
verifizierte Betriebssystemeigenschaft voraussetzen.

### Deaktivierte Redundanzprüfung

Auch bei deaktivierter lokaler Redundanzprüfung darf:

``` text
A → B → A → ...
```

keine Schleife entstehen.

Ebenso darf:

``` text
A → B → C
```

nicht stattfinden.

### Unpairing

-   Initiator trennt Pairing.
-   ursprünglicher Empfänger trennt Pairing.
-   beide online.
-   Gegenseite offline.
-   Gegenseite kehrt nach Revocation zurück.
-   erneutes Pairing nach vollständiger Trennung.

### Neustarts

-   beide Anwendungen neu starten.
-   nur eine Anwendung neu starten.
-   Betriebssystemneustart.
-   Netzwerkwechsel und Rückkehr ins ursprüngliche LAN.

Das Pairing muss erhalten bleiben.

------------------------------------------------------------------------

## 34. Nicht-Ziele der ersten Version

Folgende Funktionen sind ausdrücklich nicht erforderlich, sofern sie
nicht bereits durch die bestehende Anwendung vorgegeben werden:

-   Cloud-Synchronisation
-   Internet-Synchronisation
-   NAT Traversal
-   Relay-Server
-   Benutzerkonten
-   zentrale PKI
-   nachträglicher History-Abgleich
-   Offline-Queue
-   Multi-Hop-Routing
-   automatische Vertrauensweitergabe
-   Konfliktauflösung zwischen Clipboard-Historien
-   vollständige Synchronisation alter Clipboard-Historien

------------------------------------------------------------------------

## 35. Implementierungsreihenfolge

Eine sinnvolle Reihenfolge ist:

1.  Bestehende Clipboard-Architektur beider Anwendungen analysieren.
2.  Gemeinsames Protokoll und Versionierung festlegen.
3.  Persistente Device-ID und Schlüsselverwaltung implementieren.
4.  mDNS/DNS-SD Discovery implementieren.
5.  TLS-Verbindung und Peer-Authentisierung implementieren.
6.  Pairing-State-Machine implementieren.
7.  Persistenten Peer Store implementieren.
8.  Online-/Offline-Erkennung implementieren.
9.  Text-Clipboard-Synchronisation für genau zwei Peers implementieren.
10. Rückkopplungsschutz implementieren und testen.
11. Ein-Hop-Regel implementieren und testen.
12. Bestehende Redundanzprüfung integrieren.
13. Mehrere parallele Peers implementieren.
14. 10-Peer-Limit implementieren.
15. Unpairing und persistente Revocation implementieren.
16. Apple-Universal-Clipboard-Szenarien praktisch testen.
17. Security-, Größenlimit- und Robustheitstests durchführen.
18. Erst danach weitere Clipboard-Formate ergänzen.

------------------------------------------------------------------------

## 36. Entscheidungspunkte für die konkrete Implementierung

Vor Beginn der eigentlichen Implementierung muss der Agent anhand der
vorhandenen macOS- und Windows-Codebasen folgende Punkte entscheiden
bzw. dokumentieren:

-   Welche mDNS/DNS-SD-Bibliothek wird pro Plattform verwendet?
-   Welcher TLS-/Socket-Stack passt zu den vorhandenen Anwendungen?
-   Wird TCP+TLS direkt oder ein höheres bidirektionales Protokoll
    verwendet?
-   Wie werden Schlüssel plattformspezifisch sicher gespeichert?
-   Wie sieht das binäre oder textuelle Wire-Format aus?
-   Wie wird ein durch den Sync selbst gesetzter Clipboard-Inhalt
    zuverlässig erkannt?
-   Wie funktioniert die bestehende Redundanzprüfung in beiden
    Anwendungen genau?
-   Welche Clipboard-Datentypen sind in Version 1 tatsächlich
    kompatibel?
-   Welche Größenlimits gelten?
-   Welche Reconnect-/Keepalive-Strategie wird verwendet?
-   Wie lange müssen Revocation-Datensätze aufbewahrt werden?
-   Wie werden Protokoll-Upgrades und inkompatible Versionen behandelt?

Diese Entscheidungen dürfen die in diesem Dokument definierten
Invarianten nicht verletzen.

------------------------------------------------------------------------

## 37. Definition of Done für eine erste Version

Eine erste funktionsfähige Version ist erreicht, wenn mindestens
folgende Situation zuverlässig funktioniert:

``` text
Mac A ↔ Windows B
Mac A ↔ Mac C
Windows B ↔ Windows D
```

Alle Pairings erfolgen per Discovery und expliziter Bestätigung.

Jeder Peer:

-   besitzt eine persistente kryptographische Identität,
-   authentisiert gepairte Gegenstellen,
-   zeigt Online-/Offline-Status,
-   überträgt neue lokale unterstützte Clips bidirektional,
-   überträgt Clips ausschließlich an direkte Peers,
-   leitet empfangene Clips niemals weiter,
-   erzeugt keine Rückkopplungsschleifen,
-   verwendet die bestehende Redundanzprüfung vor dem Sync,
-   puffert keine Clips für Offline-Peers,
-   behält Pairings über Neustarts,
-   kann Pairings einseitig widerrufen,
-   verarbeitet einen Widerruf auch nach späterer Rückkehr eines zuvor
    offline befindlichen Peers,
-   akzeptiert nach einem Identitätswechsel keinen Peer stillschweigend
    als bereits vertrauenswürdig.

------------------------------------------------------------------------

## 38. Zusammenfassung

Das System wird als lokales, serverloses
Peer-to-Peer-Synchronisationssystem aufgebaut.

Die wesentliche Kette lautet:

``` text
mDNS/DNS-SD Discovery
        ↓
explizites Pairing
        ↓
persistente Geräteidentität
        ↓
TLS + gepinnte Peer-Identität
        ↓
direkte bidirektionale Peer-Verbindung
        ↓
bestehende lokale Clipboard-Verarbeitung
        ↓
Redundanzprüfung
        ↓
Sync neuer lokaler Clips
```

Dabei gelten drei besonders wichtige Regeln:

``` text
1. Ein empfangener Clip wird niemals weitergeleitet.
2. Offline-Peers erhalten keine nachträgliche Synchronisation.
3. Discovery bedeutet niemals automatisch Vertrauen.
```

Die vorhandene lokale Redundanzprüfung ist bewusst Bestandteil des
Designs. Dadurch können insbesondere identische Clipboard-Ereignisse,
die auf mehreren Macs über Apple Universal Clipboard/Handoff auftreten,
bereits durch die normale Anwendungslogik abgefangen werden.

Zusätzlich muss die Sync-Schicht unabhängig davon zuverlässig erkennen,
welche Clipboard-Änderungen sie selbst durch einen Remote-Empfang
ausgelöst hat. Dadurch bleiben Ein-Hop-Regel und Schleifenschutz auch
dann erhalten, wenn die normale Redundanzprüfung deaktiviert wird.

Dieses Dokument definiert die funktionalen und sicherheitsrelevanten
Leitplanken. Der implementierende Agent soll die konkrete technische
Umsetzung an die bestehenden macOS- und Windows-Codebasen anpassen, ohne
diese Invarianten zu verändern.
