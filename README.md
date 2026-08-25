# LASLI Flutter App

Flutter/Dart-Version der LASLI-Mess-App fuer Android und iOS.

## Enthalten

- BITalino-Anbindung ueber das `bitalino` Flutter-Plugin
- Seeed Studio XIAO MG24 Sense Paar per BLE fuer Stirn-/Bauch-IMU, MAX30102,
  Herzfrequenz, SpO2 und Bauchatmung
- automatische BITalino-Auswahl aus gekoppelten Android-Bluetooth-Geraeten
- YAMNet als TensorFlow-Lite-Modell via `tflite_flutter`
- Live-Kurven via `fl_chart` statt Matplotlib
- CSV-Export in den App-Dokumentenordner
- MR60BHA2-Radarwerte ueber ESPHome Native API im gleichen WLAN
- Schlafjournal mit Abend-/Morgenfragen, Schlafscore, Historie, Korrelationen
  und personalisierten Tipps
- Demo-Modus ohne Hardware

## Starten

Die Android- und iOS-Plattformordner sind bereits erzeugt.

```bash
cd lasli_flutter
flutter pub get
flutter run
```

Falls `flutter` in einem alten Terminal nicht gefunden wird, VS Code oder das
Terminal neu starten. Der User-PATH sollte `C:\Users\eldfi\dev\flutter\bin`
enthalten.

## Android-Hinweise

`tflite_flutter` benoetigt aktuell mindestens Android API 26. Das ist in
`android/app/build.gradle.kts` bereits gesetzt:

```gradle
minSdk = 26
```

Die Android-Berechtigungen sind in `android/app/src/main/AndroidManifest.xml`
bereits eingetragen:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
```

Fuer Android wird automatisch Bluetooth Classic (`BTH`) genutzt. Die App sucht
gekoppelte BITalinos automatisch; falls mehrere gefunden werden, waehle einen
in der BITalino-Auswahl aus. Wenn keiner erscheint, den BITalino zuerst in den
Android-Bluetooth-Einstellungen koppeln und in der App `Suchen` antippen.

## MR60BHA2 Radar

Der Radar-Sensor wird per WLAN ueber ESPHome Native API Port `6053` gelesen.
In der App kann `Radar` aktiviert und im Feld `Radar IP` entweder `auto` oder
eine feste IP-Adresse eingetragen werden. `auto` scannt die privaten `/24`-Netze,
in denen das Handy gerade angemeldet ist. Das ersetzt den Windows-Hotspot, sobald
der Sensor selbst als WLAN-Client im selben WLAN wie das Handy ist.

Mit `WLAN einrichten` koennen WLAN-Zugangsdaten direkt an das ESPHome-Captive-
Portal des Sensors gesendet werden. Dazu muss das Handy vorher mit dem Sensor-
Hotspot `seeedstudio-mr60bha2` verbunden sein; die Standardadresse ist
`192.168.4.1`. Android gibt Apps das Passwort des aktuell verbundenen WLANs
nicht heraus, deshalb muss das WLAN-Passwort in der App eingegeben werden.

Die App zeigt live die ESPHome-Entities des MR60BHA2 an, unter anderem Herzrate,
Atemrate, Person, Zielanzahl, Distanz und Beleuchtungsstaerke, sofern diese vom
Sensor/Firmware-Build bereitgestellt werden. In der CSV werden zusaetzlich
`radar_connected`, `radar_person_detected`, `radar_target_count`,
`radar_distance_cm`, `radar_heart_rate_bpm`,
`radar_breathing_rate_per_min` und `radar_illuminance_lx` gespeichert.

Wichtig: Der Sensor muss seine WLAN-Zugangsdaten bereits kennen. Die App kann
ihn dann im gleichen WLAN finden und verbinden, sie provisioniert aber nicht
automatisch ein neues WLAN auf die ESP32-Firmware.

## XIAO MG24 Sense

In der App `XIAO MG24` als Quelle fuer `Herz/Atmung` auswaehlen und
`Sensoren suchen` antippen. Die Lageerkennung ist in diesem Modus immer aktiv:
ein Board wird an der Stirn, eins am Bauch getragen. Die Atemfrequenz wird aus
dem Winkelverlauf des Bauchsensors berechnet; Herzfrequenz und SpO2 kommen aus
dem MAX30102 und duerfen von einem der beiden Boards gesendet werden.

Die XIAO-Firmware muss ein BLE-GATT-Notify-Profil anbieten:

```text
Stirn-Name:  LASLI-FOREHEAD
Bauch-Name:  LASLI-BELLY
Service:     7a534c49-2f4d-4732-9d53-4d4732340001
Notify-Char: 7a534c49-2f4d-4732-9d53-4d4732340002
```

Jede Notification ist UTF-8 und kann kompaktes JSON senden:

```json
{"r":"belly","a":[0.12,0.02,0.98],"pitch":7.5,"hr":71.2,"spo2":98.4,"bat":87}
```

Alternativ akzeptiert LASLI eine CSV-Zeile:

```text
role,time_ms,ax,ay,az,gx,gy,gz,roll,pitch,angle,hr,spo2,battery
```

`angle` ist der bevorzugte Lagewinkel in Grad. Fehlt er, nutzt LASLI `pitch`,
danach `roll`, danach einen aus der Beschleunigung geschaetzten Winkel. Die CSV
enthaelt zusaetzlich `oxygen_saturation_percent` und mehrere `mg24_*` Spalten.

## Schlafjournal

Beim Start einer Messung fragt LASLI die Abendfragen ab. Beim Stoppen wird die
Messung beendet und danach werden die Morgenfragen abgefragt. Anschliessend
speichert die App einen Schlafzyklus in einer zweiten CSV:

```text
messungen/schlafzyklen.csv
```

Diese Datei enthaelt die Fragebogenantworten, mittlere Herzfrequenz, mittlere
Atemfrequenz, mittleren Relativwinkel zwischen Stirn und Brust, Schnarchanteil
und den berechneten Schlafqualitaets-Score. Zusatzfragen koennen in der App
unter `Zusatzfrage` angelegt werden; sie werden als 1-5-Score oder Ja/Nein
gespeichert und fuer Korrelationen genutzt.

Die Korrelationen werden erst ab mindestens vier gespeicherten Schlafzyklen
angezeigt, weil einzelne Naechte sonst zu stark zufaellig waeren.

Das alte `bitalino`-Plugin ist lokal unter `third_party/bitalino` eingebunden,
damit es mit dem aktuellen Android Gradle Plugin baut.

Debug-APK bauen:

```bash
flutter build apk --debug
```

Ausgabe:

```text
build/app/outputs/flutter-apk/app-debug.apk
```

## Windows-Hinweise

Der Windows-Desktop-Target ist erzeugt. Zum Testen auf dem PC:

```bash
flutter run -d windows
```

Falls Flutter meldet `Building with plugins requires symlink support`, aktiviere
einmal den Windows-Entwicklermodus:

```powershell
start ms-settings:developers
```

Danach die Einstellungen schliessen und erneut ausfuehren:

```bash
flutter run -d windows
```

Auf Windows ist der Demo-Modus zum UI-Test gedacht. Die echte BITalino-Anbindung
kommt in dieser Flutter-Version ueber das Android/iOS-Plugin.

## iOS-Hinweise

LASLI ist fuer iOS 13 und neuer vorbereitet. Die App verwendet dort:

- XIAO-MG24-Verbindungen ueber Core Bluetooth,
- `bluetooth-central` fuer BLE-Ereignisse im Hintergrund,
- Bluetooth-State-Restoration nach einer iOS-Prozessbeendigung,
- `audio` fuer die laufende lokale YAMNet-Schnarcherkennung,
- einen nativen AVAudioEngine-Pfad mit monotonen Zeitstempeln fuer die
  Synchronisierung von Schnarch- und Atemfenstern.

Der `ios/Podfile` aktiviert beim `permission_handler` nur die benoetigten
iOS-Berechtigungen fuer Bluetooth und Mikrofon. Auf dem Mac:

```bash
flutter pub get
cd ios
pod install
cd ..
open ios/Runner.xcworkspace
```

In Xcode unter `Runner > Signing & Capabilities` das eigene Apple-Team waehlen
und sicherstellen, dass die Bundle-ID `de.lasli.app` im Apple-Account
registriert ist. Danach auf einem echten iPhone testen. BLE, Mikrofon,
TensorFlow Lite und Hintergrundbetrieb lassen sich im Simulator nicht
realistisch gemeinsam pruefen.

Ein Release-Build entsteht auf macOS mit:

```bash
flutter build ipa --release
```

Ein iOS-Build und die Apple-Signierung sind unter Windows nicht moeglich.
