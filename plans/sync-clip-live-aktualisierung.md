# Plan: Geöffnete Clipliste bei Sync-Empfang live aktualisieren

Status: implementiert; manueller Peer-/GUI-Abnahmetest ausstehend<br>
Geltungsbereich: Floatcut für macOS; keine Änderung am Sync-Protokoll

## Ziel

Trifft während eines geöffneten Zwischenablage-Menüs ein neuer Text- oder
Bildclip über den Peer-to-Peer-Sync ein, soll die Liste ohne Schließen und
erneutes Öffnen den aktuellen Inhalt anzeigen. Suche, aktive Ansicht,
Tastaturfokus und Scrollposition sollen dabei nicht unerwartet zurückgesetzt
werden. Ein Sync-Clip gehört in den normalen Verlauf, nicht automatisch in die
Favoriten.

## Ausgangsbefund im Code

- `FloatcutSyncCoordinator.applyRemoteText` und `applyRemoteImage` übergeben
  die validierten Inhalte asynchron auf den Main Thread an die
  `AppController`-Callbacks. Für die UI ist daher kein weiterer Netzwerk- oder
  Clipboard-Polling-Mechanismus nötig.
- `AppController` fügt Text und Bilder über `FloatcutOperator` ein und reicht
  `@selector(updateMenu)` als Callback weiter. `updateMenu` aktualisiert das
  Popover aber nur, wenn es gerade als `isShown` gilt. Ein normaler Aufruf setzt
  außerdem die Suchanfrage zurück. Der vorhandene
  `preserveStatusPopoverSearchOnNextMenuUpdate`-Schalter wird für
  Favoritenaktionen benutzt, nicht für Sync-Empfang.
- `FloatcutOperator` verwendet beim Hinzufügen `clippingStore`; dieser zeigt
  je nach Auswahl auf Verlauf oder Favoriten. Bei geöffneter Favoritenansicht
  kann ein eingehender Sync-Clip deshalb im falschen Speicher landen.
- Der `receivedFromSync`-Status wird erst nach dem Einfüge-Callback gesetzt.
  Das derzeitige asynchrone `updateMenu` kann ihn zwar später sehen, doch die
  Reihenfolge sollte ausdrücklich abgesichert werden, damit der farbige Rahmen
  beim ersten Rendern zuverlässig erscheint.
- Die SwiftUI-Liste erhält Daten über
  `FloatcutStatusPopoverController.updateItems`; deren Zeilen besitzen stabile
  Clip-IDs. `setFavoritesStoreActive` setzt das Scrollen zurück, aber nur bei
  einem tatsächlichen Wechsel der Speicheransicht.

Der Befund erklärt mögliche Fehlerpfade, beweist aber noch nicht, welcher
davon den konkret beobachteten fehlenden Refresh auslöst. Vor der Änderung
ist der Fall mit einem verbundenen Testclient reproduzierbar zu machen.

## Umsetzung

1. **Reproduktion und Messpunkte.** Mit synthetischen Clips getrennt für Text
   und PNG/JPEG prüfen: Popover offen/geschlossen, Verlauf/Favoriten aktiv,
   leere/nichtleere Suche. Im Debug-Build sparsame Ereignisse für
   `applied`/`duplicate`/`skipped`, `updateMenu`-Einplanung und tatsächliches
   `updateItems` protokollieren – ohne Clip-Inhalt, Bilddaten oder Schlüssel.
   Vorhandene detaillierte Sync-Diagnose möglichst wiederverwenden.
2. **Empfang vom sichtbaren Store trennen.** Die beiden Sync-Callbacks sollen
   Text und Bild immer in den primären Verlauf einfügen, unabhängig von der
   gerade gewählten Favoritenansicht. Dazu im `FloatcutOperator` eine klar
   benannte, gezielte Einfüge-API für den primären Store ergänzen oder einen
   gleichwertigen sicheren Pfad verwenden. Die Ansicht dafür nicht temporär
   umschalten; das würde UI-Zustand und Benutzeraktion verändern.
3. **Remote-Metadaten vor dem UI-Snapshot setzen.** `receivedFromSync` beim
   Erzeugen des Clips beziehungsweise vor dem Änderungs-Callback setzen.
   Sicherstellen, dass `applied` erst nach erfolgreicher Übernahme zurückgeht;
   bei `duplicate` oder `skipped` keinen neuen Listen-Refresh erzwingen.
   Vorhandene Pasteboard-Blocktokens und den Schutz gegen erneutes Weiterleiten
   empfangener Clips unverändert lassen.
4. **Gezielten Live-Refresh einführen.** Nach erfolgreichem Import einen
   Aktualisierungspfad verwenden, der den vorhandenen Main-Thread-/Coalescing-
   Mechanismus nutzt, aber die aktuelle Suche nicht löscht. Wenn das Popover
   geöffnet und der normale Verlauf aktiv ist, `displayItemsMatchingSearch`
   für die aktuelle Suchanfrage neu bilden und an `updateItems` geben. Bei
   geschlossener Liste keine sichtbare UI-Arbeit erzwingen; das nächste Öffnen
   lädt den aktuellen Verlauf. Bei aktiven Favoriten diese Ansicht und deren
   Suchtext erhalten; der Clip erscheint nach dem Wechsel zum Verlauf.
5. **Zustandswechsel und Mehrfachempfang absichern.** Ein ausstehender
   asynchroner Refresh darf nach schnellem Umschalten von Verlauf/Favoriten,
   Ändern des Suchtextes oder Schließen des Popovers nicht mit veralteten
   Parametern rendern. Den aktiven Store und Suchtext erst zum Ausführungszeitpunkt
   lesen. Mehrere unmittelbar folgende Clips dürfen zu einem Refresh gebündelt
   werden, solange der letzte Snapshot alle angenommenen Clips enthält.
   Tastaturfokus und Scrollposition möglichst erhalten; nur explizites
   Umschalten oder erneutes Öffnen darf die bisherige Scroll-Reset-Logik
   auslösen.

## Erwartetes Verhalten

| Situation beim Empfang | Ergebnis |
| --- | --- |
| Menü offen, normaler Verlauf, keine Suche | Neuer Clip erscheint sofort oben mit Sync-Rahmen. |
| Menü offen, normaler Verlauf, Suche aktiv | Suchtext und Fokus bleiben; nur passende Clips erscheinen. |
| Menü offen, Favoriten aktiv | Favoriten bleiben unverändert; nach Umschalten zum Verlauf ist der Clip sichtbar. |
| Menü geschlossen | Keine zusätzliche sichtbare Arbeit; beim nächsten Öffnen ist der Clip vorhanden. |
| Duplikat, pausierter Empfang oder abgelehnter Transfer | Kein neuer Eintrag und kein unnötiger UI-Refresh. |

## Tests und Abnahme

- Engine-Regressionstests für Text- und Bildimport bei beiden ausgewählten
  Stores ergänzen: Ziel ist immer der primäre Verlauf, Favoriten bleiben
  unverändert, Reihenfolge/Größenlimit/Duplikatverhalten bleiben bestehen.
- Einen AppController-/Popover-Test oder eine kleine injizierbare
  Aktualisierungskomponente ergänzen, die offenen Verlauf mit und ohne Suche,
  Favoritenansicht, geschlossenes Popover und rasch aufeinanderfolgende
  Empfänge prüft. Nicht nur die Engine testen: Der Fehler betrifft den
  Übergang vom Import zur sichtbaren SwiftUI-Liste.
- Manuell mit einem gepairten zweiten Client oder SRC prüfen: Text, PNG und
  JPEG während geöffneter Liste empfangen; Suche eingeben; Ansicht wechseln;
  Clip-Favoritenbutton benutzen; Popover während des Transfers schließen.
  Den Sync-Rahmen und die Bildvorschau beim ersten Rendern kontrollieren.
- Prüfen, dass lokale Copy-/Handoff-Erfassung, 1-Sekunden-Polling, Bezel,
  Favoritenlöschung, `Alles löschen`, Persistenz und Sync-ACKs unverändert
  funktionieren. Vorhandene Engine-, Sync- und UI-relevante Tests ausführen.
- Kein Sync-Protokollwechsel, keine neue Lokalisierung, keine
  Versionsänderung und kein Commit/Push allein aufgrund dieses Plans.

## Abnahmekriterium

Ein erfolgreich angenommener Sync-Clip wird in einer bereits geöffneten
normalen Clipliste sichtbar, ohne das Menü neu zu öffnen und ohne die laufende
Suche zu löschen. Bei aktiven Favoriten bleibt die Ansicht stabil und der Clip
landet trotzdem im normalen Verlauf. Text und Bilder verhalten sich gleich;
Duplikate und abgelehnte Clips erzeugen keine Phantomzeilen.

## Umsetzungsstand

- Text und Bilder werden über gezielte Operator-APIs in den primären Verlauf
  übernommen. Die Sync-Herkunft ist bereits vor Store-Delegate und UI-Callback
  gesetzt; Favoritenansicht und deren Stackposition bleiben erhalten.
- Der Status-Menü-Refresh wird gebündelt und erhält bei Sync-Importen den
  aktuellen Suchtext. Sichtbarkeit, aktiver Speicher und Suchtext werden erst
  beim Ausführen des Refresh geprüft. Bei geschlossenem Popover entfällt die
  sichtbare Aktualisierung.
- Der Passwortfilter für empfangene Texte bleibt aktiv, legt dabei aber keinen
  Pasteboard-Typ-Diagnoseclip im gerade sichtbaren Favoritenspeicher an.
- Automatisch geprüft: Engine-Regressionstests einschließlich Import/Marker,
  Favoriten, Duplikaten, Limit und Refresh-Coalescing; Sync-Protokoll- und
  Sync-Work-Tests; Debug-App-Build außerhalb von `dist`.
- Noch offen: manueller End-to-End-Test mit einem gepairten zweiten Client
  bei geöffnetem Popover für Text, PNG und JPEG sowie Suche, Scrollposition
  und schnelles Wechseln zwischen Verlauf und Favoriten.
