# DICOM-Importer

Native macOS-App (SwiftUI, macOS 14+) zum Einlesen von DICOM-Untersuchungen – von CD/DVD, aus Ordnern/ZIP-Archiven oder über den **QR-Code** eines Befundbriefs (Bildportal) – und zur Ablage auf einem NAS, bevorzugt per **WebDAV**.

> Version 2 ist eine vollständige Neuentwicklung. Die bisherige Python/Tk-Version liegt unter [`legacy/`](legacy/).

## Was ist neu gegenüber Version 1?

| Problem in v1 | Lösung in v2 |
|---|---|
| Import scheitert, wenn der Mountpoint nicht verfügbar ist | **Lokale Warteschlange:** Die Untersuchung wird zuerst lokal gesichert (CD kann sofort raus), die Übertragung ins Archiv läuft im Hintergrund und wird automatisch wiederholt (Netzwerkwechsel, alle 60 s, Backoff bis 30 min). Unterbrochene Uploads werden fortgesetzt. |
| Mounten über die App klappt oft nicht | **Kein Mounten mehr nötig:** WebDAV direkt über HTTPS. Alternativ ein beliebiger (im Finder verbundener) Ordner. |
| Transfer aufs NAS | **WebDAV-Client** (PROPFIND/MKCOL/PUT/MOVE), Passwort im Schlüsselbund, selbstsignierte NAS-Zertifikate per SHA-256-Fingerabdruck vertrauen, freier Speicher per Quota. Upload in einen temporären Ordner, der erst am Ende umbenannt wird → **keine halb kopierten Untersuchungen im Archiv**. |
| Untersuchungen nur per QR-Code | **QR-Scanner** (Mac-Kamera oder iPhone via Continuity Camera, Foto/PDF des Briefs, Zwischenablage) → Portal öffnet sich in einem eingebauten Browser (ohne gespeicherte Cookies). Heruntergeladene ZIP/DICOM-Dateien werden automatisch entpackt und eingelesen. |
| Python/Tk, PyInstaller-Bundle | **Native SwiftUI-App**, eigener schneller DICOM-Header-Parser ohne Abhängigkeiten. |

Weitere Verbesserungen:

- Eingelegte DICOM-CDs werden automatisch erkannt und eingelesen, danach optional ausgeworfen.
- Mehrere Untersuchungen auf einer CD werden getrennt (nach Study Instance UID) und einzeln archiviert.
- Nur DICOM-Dateien werden übernommen (Viewer-Software etc. auf der CD wird ignoriert).
- Modalität aus allen Serien (z. B. `PT+CT`), SR/PR/KO werden ignoriert.
- Zeichensätze (ISO_IR 100/192) für Umlaute, optional `MUSTERMANN` → `Mustermann`.
- Ordnername wie bisher: `JJJJMMTT-JJJJMMTT-Nachname, Vorname-MOD` (Untersuchungsdatum, Geburtsdatum). Existiert er schon, wird ` (2)` angehängt.

## Projektstruktur

```
Core/        Swift Package „DICOMImporterCore“ (plattformneutral, getestet)
  DICOM/        DICOM-Header-Parser, Scanner (Gruppierung nach Studie)
  Destinations/ WebDAV- und Ordner-Ziel
  Transfer/     Persistente Warteschlange (Outbox), Staging
App/         SwiftUI-App (Import, QR/Portal, Warteschlange, Einstellungen)
project.yml  XcodeGen-Projektbeschreibung
legacy/      alte Python-Version
```

## Bauen

Voraussetzungen: Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open DICOMImporter.xcodeproj
```

Tests des Kerns (ohne Xcode-Projekt):

```bash
swift test --package-path Core
```

Die GitHub Action `.github/workflows/build.yml` führt die Tests aus und baut eine ad-hoc-signierte App als Artefakt.
Eine ad-hoc-signierte App muss beim ersten Start per Rechtsklick → „Öffnen“ gestartet werden.

## Einrichtung

### WebDAV auf Synology (empfohlen)

1. Im Paket-Zentrum **WebDAV Server** installieren, HTTPS aktivieren (Port 5006).
2. Freigegebenen Ordner (z. B. `DICOM`) anlegen, Benutzer mit Schreibrecht.
3. In der App unter *Einstellungen → Archiv*: `https://<nas>:5006/DICOM`, Benutzer, Passwort → *Verbindung testen*.
4. Bei selbstsigniertem Zertifikat wird der SHA-256-Fingerabdruck angezeigt; nach Abgleich mit dem NAS *Diesem Zertifikat vertrauen*.

### Ordner / SMB

Alternativ ein lokaler Ordner oder eine im Finder verbundene Freigabe. Ist sie nicht verbunden, bleiben die Daten in der Warteschlange.

### Lokale Daten

Warteschlange und zwischengespeicherte Untersuchungen liegen unter
`~/Library/Application Support/DICOM-Importer/Outbox`. Nach erfolgreicher Übertragung werden die lokalen Kopien gelöscht.
Portal-Downloads werden nach dem Sichern bzw. beim nächsten Start entfernt. Protokoll: Konsole.app, Subsystem `de.sommeru.DICOMImporter`.

## Hinweise zu Bildportalen

Die Portale der Praxen/Kliniken sind sehr unterschiedlich. Die App öffnet die Adresse aus dem QR-Code in einem eingebetteten Browser; Anmeldung (Geburtsdatum, Zugangscode) erfolgt wie gewohnt. Jeder Download (ZIP, ISO, DICOM) wird abgefangen und eingelesen. Portale, die nur einen Online-Viewer ohne Download anbieten, können nicht übernommen werden.

## Lizenz

GPLv3. © 2025 J. Ulrich Sommer
