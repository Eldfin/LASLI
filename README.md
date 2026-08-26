# LASLI

LASLI ist eine experimentelle App zur Aufzeichnung und Auswertung von Schlaf-
und Sensordaten. Sie verbindet sich per Bluetooth mit zwei LASLI-Sensoren auf
Basis des Seeed Studio XIAO MG24 Sense und stellt unter anderem Herzfrequenz,
Atemfrequenz, Ohrtemperatur, Körperorientierung und Schnarchereignisse dar.

> **Hinweis:** LASLI ist eine Test- und Forschungsanwendung. Sie ist kein
> Medizinprodukt und darf nicht für Diagnosen oder medizinische Entscheidungen
> verwendet werden.

## App herunterladen

Die aktuellen Installationsdateien befinden sich unter
**[Releases](https://github.com/Eldfin/LASLI/releases/latest)**:

| Plattform | Datei | Installation |
| --- | --- | --- |
| Android | `LASLI-release.apk` | Direkt auf dem Android-Gerät installieren |
| iPhone/iPad | `LASLI-unsigned.ipa` | Mit SideStore signieren und installieren |

Da dieses Repository privat ist, muss der verwendete GitHub-Account zuvor als
Mitwirkender eingeladen worden sein.

## Android installieren

Voraussetzung ist ein Gerät mit Android 8.0 oder neuer.

1. Auf der [Release-Seite](https://github.com/Eldfin/LASLI/releases/latest)
   `LASLI-release.apk` herunterladen.
2. Die heruntergeladene APK auf dem Android-Gerät öffnen.
3. Falls Android nachfragt, dem verwendeten Browser oder Dateimanager einmalig
   das **Installieren unbekannter Apps** erlauben.
4. Die Installation bestätigen und LASLI starten.
5. Die angefragten Berechtigungen für Bluetooth, Benachrichtigungen und
   Mikrofon erteilen. Sie werden für Sensorverbindungen, Nachtmessungen und die
   optionale Schnarcherkennung benötigt.

Android oder Google Play Protect kann darauf hinweisen, dass die App nicht aus
dem Play Store stammt. Die Datei sollte nur aus diesem Repository installiert
werden.

## iPhone oder iPad installieren

Die IPA ist absichtlich nicht mit einem fremden Apple-Zertifikat signiert und
muss deshalb in SideStore mit der eigenen Apple-ID signiert werden. Xcode
installiert diese IPA nicht: Bei der Xcode-Variante wird LASLI stattdessen aus
dem Quellcode gebaut, mit der eigenen Apple-ID signiert und direkt auf das
iPhone übertragen.

### Variante A: SideStore

Voraussetzungen sind iOS/iPadOS 15 oder neuer, eine Apple-ID, WLAN und für die
erste Einrichtung ein Computer.

1. SideStore anhand der
   **[offiziellen Installationsanleitung](https://docs.sidestore.io/docs/installation/prerequisites)**
   einrichten.
2. Auf dem iPhone oder iPad `LASLI-unsigned.ipa` von der
   [Release-Seite](https://github.com/Eldfin/LASLI/releases/latest)
   herunterladen.
3. `LocalDevVPN` aktivieren und SideStore öffnen.
4. Unter **My Apps** die heruntergeladene IPA auswählen und installieren.
5. Falls iOS danach fragt, unter **Einstellungen > Allgemein > VPN und
   Geräteverwaltung** der eigenen Apple-ID vertrauen und den Entwicklermodus
   aktivieren.

Bei einer kostenlosen Apple-ID läuft die Signierung nach sieben Tagen ab.
SideStore muss die App daher regelmäßig aktualisieren. SideStore ist ein
unabhängiges Drittanbieterprojekt und nicht Bestandteil von LASLI.

### Variante B: Aus dem Quellcode mit Xcode

Auf dem Mac müssen Xcode, Flutter, CocoaPods und Git installiert sein.

```bash
git clone https://github.com/Eldfin/LASLI.git
cd LASLI
flutter pub get
cd ios
pod install
open Runner.xcworkspace
```

Danach in Xcode:

1. Das Projekt `Runner` und **Signing & Capabilities** öffnen.
2. Unter **Team** die eigene Apple-ID beziehungsweise das eigene
   **Personal Team** wählen.
3. Falls Xcode es verlangt, eine eindeutige Bundle-ID eintragen.
4. Das entsperrte iPhone per USB anschließen und als Zielgerät wählen.
5. Mit **Run** die App signieren und installieren.

Auch diese kostenlose Xcode-Signierung ist jeweils sieben Tage gültig.

## Erster Start

1. Bluetooth am Smartphone einschalten.
2. Die beiden LASLI-Sensoren einschalten beziehungsweise mit ihrem Wake-Taster
   aufwecken.
3. In LASLI auf **Verbinden** tippen und warten, bis Stirn- und Bauchsensor als
   verbunden angezeigt werden.
4. Die Sensoren anlegen und die Messung auf dem Home-Bildschirm starten.
5. Nach dem Countdown kann das Smartphone gesperrt werden. Zum Beenden LASLI
   erneut öffnen, die Sensoren verbinden und **Stoppen** wählen.

Ohne die zugehörigen MG24-Sensoren kann die App geöffnet und angesehen werden;
Live-Messwerte stehen dann jedoch nicht zur Verfügung.

## Rückmeldung geben

Fehlerberichte und Beobachtungen können unter
**[Issues](https://github.com/Eldfin/LASLI/issues)** eingetragen werden. Hilfreich
sind dabei Smartphone-Modell, Android-/iOS-Version, verwendete Sensoren und eine
möglichst genaue Beschreibung der durchgeführten Schritte.

## Für Entwickler

LASLI wird mit Flutter entwickelt. Jeder Push auf `main` wird auf einem
macOS-Runner analysiert, getestet und als unsignierte iOS-App gebaut. Der
Quellcode kann lokal mit folgenden Befehlen geprüft werden:

```bash
flutter pub get
flutter analyze
flutter test
```
