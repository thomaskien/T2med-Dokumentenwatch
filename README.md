# T2med Tempwatch für Atril unter XFCE

## Video-Demo

<p>
  <a href="https://github.com/thomaskien/T2med-Dokumentenwatch/raw/refs/heads/main/2026-03-28%2020-34-56.mkv">
    ▶ Video ansehen / herunterladen
  </a>
</p>

<p><em>Falls das Video im Browser nicht direkt abgespielt wird, bitte lokal öffnen.</em></p>

## Zielsetzung

Dieses Setup dient dem **besseren Befundstudium** mit T2med auf großen Bildschirmen oder **Zweitschirm**

Besonders sinnvoll ist es bei:

- **Monitoren ab 27 Zoll** mit **2560 Pixeln Breite**
- optimal bei **30 Zoll** mit **2560 × 1600 Pixeln**
- alternativ: zweiter Monitor

Die Idee ist, dass T2med nach dem Öffnen eines Dokuments im Hauptfenster benutzbar bleibt, während das zugehörige PDF automatisch in **Atril** auf einer definierten Bildschirmfläche erscheint.

## Funktionsprinzip

T2med legt geöffnete Dokumente temporär unter `/tmp/T2med-tmp-...` ab. Der Watcher beobachtet diese Verzeichnisse und reagiert auf neu geschriebene PDFs.

Dabei passiert Folgendes:

1. eine neue PDF-Datei wird erkannt
2. die Datei wird automatisch mit **Atril** geöffnet
3. das Atril-Fenster wird an die konfigurierte Position verschoben und skaliert
4. das T2med-Fenster wird ebenfalls an die konfigurierte Position gesetzt (ausser es ist maximiert, dann passiert nichts)
5. der Fokus geht zurück zu T2med
6. optional wird automatisch `Escape` an T2med gesendet, damit man sofort in die Übersicht zurückkehrt

Zusätzlich gibt es ein **Tray-Icon im XFCE-Panel**:

- **Linksklick**: `killall atril`
- **Rechtsklick-Menü**:
  - Atril schließen
  - Watcher neu starten
  - Konfiguration öffnen
  - Tray beenden

## Voraussetzungen

- Linux mit **XFCE**
- **X11**
- T2med erzeugt Dokumente unter `/tmp/T2med-tmp-*`
- Atril ist als externer PDF-Viewer gewünscht

Benötigte Pakete:

- `inotify-tools`
- `xdotool`
- `x11-utils`
- `yad`

## Installation

Der Installer richtet alles automatisch ein:

- Watcher unter `~/.local/bin/t2med-tempwatch`
- Konfiguration unter `~/.config/t2med-tempwatch/config`
- Tray-Symbol unter `~/.local/bin/t2med-atril-tray`
- XFCE-Autostart-Launcher unter `~/.config/autostart/`

Nach der Installation werden Watcher und Tray direkt gestartet.

## Benutzung

### Normaler Ablauf

1. in T2med ein Dokument öffnen
2. das PDF erscheint automatisch in Atril
3. Atril wird an die gewünschte Bildschirmposition gesetzt
4. der Fokus kehrt zu T2med zurück
5. durch das optionale automatische `Escape` landet man sofort wieder in der Übersicht

### Tray-Symbol

Im XFCE-Panel erscheint ein PDF-Symbol.

- **Linksklick** schließt alle Atril-Fenster
- **Rechtsklick** öffnet das Menü für Watcher und Konfiguration

## Konfiguration

Die zentrale Datei ist:

```bash
~/.config/t2med-tempwatch/config
```

Wichtige Optionen:

```bash
OPENER="atril"

ATRIL_EDGE="right"
ATRIL_WIDTH_FACTOR="0.33"
ATRIL_OFFSET_FACTOR="0.00"
ATRIL_HEIGHT_FACTOR="1.00"
ATRIL_Y_POS="0"

T2MED_EDGE="left"
T2MED_WIDTH_FACTOR="0.66"
T2MED_OFFSET_FACTOR="0.00"
T2MED_HEIGHT_FACTOR="1.00"
T2MED_Y_POS="0"

MIN_OPEN_INTERVAL="1.5"
AUTO_ESCAPE_AFTER_OPEN="yes"
TMP_PREFIX="T2med-tmp-"
```

### Bedeutung der Positionsparameter

Für **Atril** und **T2med** gibt es jeweils:

- `EDGE="left"` oder `EDGE="right"`
- `WIDTH_FACTOR` als Anteil der **gesamten X11-Bildschirmbreite**
- `OFFSET_FACTOR` als zusätzlicher Rand von links oder rechts
- `HEIGHT_FACTOR` als Anteil der gesamten Höhe
- `Y_POS` als feste vertikale Startposition

Beispiele:

```bash
ATRIL_EDGE="right"
ATRIL_WIDTH_FACTOR="0.33"
ATRIL_OFFSET_FACTOR="0.00"
```

→ Atril nimmt das rechte Drittel der gesamten Desktopbreite ein.

```bash
T2MED_EDGE="left"
T2MED_WIDTH_FACTOR="0.30"
T2MED_OFFSET_FACTOR="0.30"
```

→ T2med beginnt bei 30 % der Gesamtbreite und ist selbst 30 % breit.

## Wichtige Dateien

```bash
~/.local/bin/t2med-tempwatch
~/.local/bin/t2med-atril-tray
~/.config/t2med-tempwatch/config
~/.config/autostart/t2med-tempwatch.desktop
~/.config/autostart/t2med-atril-tray.desktop
~/.cache/t2med-tempwatch.log
```

## Nützliche Befehle

```bash
~/.local/bin/t2med-tempwatch status
~/.local/bin/t2med-tempwatch restart
~/.local/bin/t2med-tempwatch edit-config
```

Logs ansehen:

```bash
tail -n 100 ~/.cache/t2med-tempwatch.log
```

## Hinweise

- Das Setup ist auf **ruhiges, schnelles Befundstudium** optimiert.
- Die Fensterzuordnung unter X11 ist nie perfekt deterministisch; deshalb enthält der Watcher Debouncing, Sperren und Fallback-Logik.
- Für große Monitore ist das Ergebnis besonders angenehm, weil T2med und PDF gleichzeitig gut lesbar bleiben.

