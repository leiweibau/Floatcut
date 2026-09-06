# Floatcut für macOS

[English](../readme.md) | Deutsch

<p align="center">
  <img src="../AppIcon.png" alt="Floatcut App-Icon" width="175" height="175">
</p>

Floatcut ist ein schlanker Zwischenablage-Manager für macOS. Die App führt einen durchsuchbaren lokalen Verlauf kopierter Texte und Bilder, bietet einen getrennten Favoritenspeicher und kann neue Clips direkt mit gekoppelten Geräten im lokalen Netzwerk austauschen.

**Aktuelle Version:** 4.0<br>
**Bedienungsanleitung:** [Deutsch](bedienung.md) · [English](user-guide.md)

<p align="center">
  <img src="screenshots/clipboard-menu.png" alt="Zwischenablage-Menü von Floatcut" width="432">
</p>

## Funktionen

- Schneller Zwischenablageverlauf in Menüleiste, Suchfenster und tastaturgesteuertem Bezel
- Getrennter Favoritenspeicher mit Favoriten- und Löschschaltfläche je Eintrag
- Konfigurierbare globale Hotkeys, Speichergrößen, Sicherung und Darstellung
- Lokale Peer-to-Peer-Synchronisation mit verschlüsselter Kopplung und Widerrufen
- Textsynchronisation und optionaler Versand von PNG-/JPEG-Bildern je Zielgerät
- Dezente Kennzeichnung von Clips, die von einem anderen Gerät empfangen wurden
- Manuelle Migration einer vorhandenen Flycut-Installation
- Deutsche und englische Benutzeroberfläche
- Keine iCloud-Abhängigkeit, kein Cloud-Konto, keine Telemetrie und kein zentraler Zwischenablage-Server

## Voraussetzungen

- macOS 13.5 oder neuer
- Bedienungshilfen-Berechtigung zum automatischen Einfügen in die aktive Anwendung
- Lokales-Netzwerk-Berechtigung für Gerätesuche und Synchronisation

## Installation

1. `Floatcut.app` nach `/Applications` kopieren.
2. Floatcut starten. Da Entwicklungs- und Release-Bundles lokal beziehungsweise ad hoc signiert und nicht notarisiert sind, kann macOS den ersten Start blockieren.
3. Falls erforderlich, unter **Systemeinstellungen → Datenschutz & Sicherheit** die Option **Trotzdem öffnen** wählen.
4. Die Bedienungshilfen-Berechtigung erteilen, wenn Floatcut ausgewählte Clips automatisch einfügen soll.

Hinweise zu Gatekeeper und Bedienungshilfen für vertrauenswürdige lokale Builds enthält die englische Dokumentation [Release setup](RELEASE_SETUP.md). Gatekeeper sollte nicht global deaktiviert werden.

## Erste Schritte

- Wie gewohnt kopieren. Floatcut erfasst unterstützte Inhalte, solange die Aufzeichnung aktiviert ist.
- Das Menüleisten-Icon anklicken, um die letzten Einträge zu sehen.
- Mit **Umschalt-Befehl-V** das Bezel öffnen, mit den Pfeiltasten navigieren und mit Return einfügen.
- Mit **Umschalt-Befehl-B** den Zwischenablageverlauf durchsuchen.
- Mit dem Stern neben dem Suchfeld zwischen Verlauf und Favoriten umschalten.
- Mit Wahltaste-Klick auf das Menüleisten-Icon die Aufzeichnung vorübergehend aus- oder wieder einschalten.

Die Tastenkürzel lassen sich unter **Einstellungen → Hotkeys** ändern. Favoriten, Synchronisation, Diagnose, Migration und Fehlerbehebung werden in der [vollständigen Bedienungsanleitung](bedienung.md) beschrieben.

## Build

Nach der Installation von Xcode erzeugt dieser Befehl ein universelles Release-App-Bundle unter `dist/`:

```bash
bash Scripts/package-app.sh
```

Das Ergebnis ist `dist/Floatcut.app`. Das Skript verwendet nach Möglichkeit die stabile lokale Signierungsidentität `Floatcut Local Development` und fällt sonst auf eine Ad-hoc-Signatur zurück. Weitere Details stehen unter [Release setup](RELEASE_SETUP.md).

## Datenschutz und Datenspeicherung

Zwischenablageverlauf und Favoriten werden lokal für den jeweiligen macOS-Benutzer unter der Anwendungsdomäne von Floatcut (`de.meierkarsten.floatcut`) gespeichert. Es erfolgt kein Upload zu iCloud. Die Peer-to-Peer-Synchronisation sendet neue Clips nur an ausdrücklich gekoppelte und gerade erreichbare Geräte; sie ist weder Cloud-Speicher noch Offline-Warteschlange.

Zwischenablage-Manager können vertrauliche Informationen enthalten. Floatcut kann Passwortfelder und passwortähnliche Werte ignorieren; mit Wahltaste-Klick lässt sich die Aufzeichnung pausieren. Vor Aktivierung der Synchronisation sollten die Aufzeichnungseinstellungen geprüft werden.

## Dokumentation

- [Bedienungsanleitung (Deutsch)](bedienung.md)
- [User guide (English)](user-guide.md)
- [Release-, Signierungs- und Gatekeeper-Hinweise](RELEASE_SETUP.md)
- [Plattform- und Migrationshinweise](PLATFORM_NOTES.md)
- [Synchronisationsprotokoll](Protocol/)

## Herkunft und Lizenz

Floatcut führt die Arbeit von [Jumpcut](https://github.com/snark/jumpcut) und [Flycut](https://github.com/haad/Flycut/) fort. Ausführliche Hinweise stehen unter **Einstellungen → Danksagung**.

Copyright © 2002 - 2019 by Steven Cook (Jumpcut)<br>
Copyright © 2011, General Arcade, Gennadiy Potapov, Adam Hamsik (Flycut)<br>
Copyright © 2026 by Karsten Meier (Floatcut)

Floatcut steht unter der [MIT-Lizenz](../license.txt).
