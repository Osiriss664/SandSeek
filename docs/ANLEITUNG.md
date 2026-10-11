# SandSeek: Anleitung

SandSeek recherchiert für dich im Web. Du stellst eine Frage, ein Sprachmodell auf deinem
eigenen Mac sucht und liest Webseiten, und du bekommst eine Antwort mit nummerierten Quellen.
Deine Frage und die Antwort bleiben auf deinem Mac. Ins Internet gehen die Suchbegriffe, die
das Modell aus deiner Frage bildet, und das Laden der Webseiten; Suchmaschine und Webseiten
sehen dabei deine IP-Adresse.

## Was du brauchst

- einen Mac mit Apple-Chip und macOS 26, am besten mit 16 GB Speicher
- Apples Programm **container** ([hier laden](https://github.com/apple/container/releases))
- ein **Modell-Programm**, das schon läuft: TUFF (ab Version 8.3.1) oder llama.cpp
- die Entwickler-Werkzeuge von Apple (Xcode oder die Kommandozeilen-Werkzeuge), um die App
  einmal zu bauen

## Einmal einrichten

1. **container installieren.** Lade das Installationspaket von der Seite oben und öffne es.
2. **App bauen.** Öffne das Programm *Terminal*, wechsle in den SandSeek-Ordner und gib ein:
   `Scripts/package_app.sh`. Das dauert einige Minuten. Danach liegt die App unter
   `build/SandSeek.app`. Du kannst sie in den Ordner *Programme* ziehen.
3. **App öffnen.** Doppelklick auf `SandSeek.app`. Wenn macOS die App nicht öffnen will,
   erlaube sie unter *Systemeinstellungen > Datenschutz & Sicherheit*.

## Das Modell-Programm starten

SandSeek startet das Modell-Programm nicht selbst. Du startest es vorher.

- **TUFF:** In TUFF im Bereich *Server* die *Background API* einschalten, oder im Terminal
  `tuff serve` eingeben. TUFF hört dann nur auf deinem Mac (Adresse 127.0.0.1:8080).
- **llama.cpp:** In SandSeek bei *Model server* **llama.cpp** wählen. Die Karte zeigt einen
  fertigen Startbefehl. Mit **Copy start command** kopieren, im Terminal einfügen, das
  Modell eintragen und Return drücken. Der Befehl enthält `--host 127.0.0.1`: das heißt, nur
  dein Mac darf zugreifen. Lass diesen Teil immer drin. llama.cpp ist nur eingeschränkt
  getestet: Mit dem Modell Bonsai ist die Prüfung gegen Angriffe aus Webseiten noch nicht
  gemessen. Mit TUFF und Qwen ist sie bestanden.

Auf einem Mac mit 16 GB darf immer nur ein Modell-Programm laufen.

## Die erste Frage

1. Drücke bei *Model server* auf **Check**. Steht dort **Connected**, ist alles verbunden.
2. Drücke bei *Web sandbox* auf **Start Sandbox**. Beim ersten Mal dauert das einige Minuten,
   weil die Schutz-Umgebung gebaut wird. Wenn **Ready** (grün) dasteht, kann es losgehen.
3. Wähle das Modell, dann **Quick answer** (schnell) oder **Thorough** (gründlicher, dauert
   länger).
4. Schreibe deine Frage und drücke **Research** (oder Befehl-Return).

Links siehst du, was passiert: welche Suchen laufen und welche Seiten gelesen werden. Rechts
erscheint am Ende die Antwort mit Quellen wie [1], [2]. Eine Frage dauert meist zwei bis
acht Minuten.

## Stopp

Drücke **Stop**, wenn du abbrechen willst. Was bis dahin gelesen wurde, wird als Bericht
ohne Antwort gespeichert. Das Modell-Programm hört dann auch auf zu rechnen. Bei einer
sehr langen Frage kann das einige Sekunden dauern.

## Berichte

Jede fertige Antwort wird gespeichert. Du findest sie links in der Seitenleiste unter
**Reports**, mit Datum und Frage. Die Dateien liegen im Ordner
`Library/Application Support/SandSeek/Reports` in deinem Benutzerordner. Zum Löschen drücke
bei einem Bericht auf **Delete** und bestätige mit **Move to Trash**: Er wandert in den
Papierkorb.

Ein Klick auf eine Quelle öffnet sie nicht sofort. Die App zeigt zuerst die ganze Adresse,
und erst nach deiner Bestätigung öffnet sie sich im Browser. Links in der Antwort selbst
tun nichts. Das ist Absicht.

## Was die Sicherheitsprüfung bedeutet

Webseiten sind nicht vertrauenswürdig. Manche enthalten Text, der dem Modell Befehle geben
will. SandSeek schützt so:

- Das Modell darf nur **suchen** und **Seiten lesen**. Es kann nichts ausführen und keine
  Dateien öffnen. Auch PDFs aus dem Netz kann es lesen (bis 5 MB und 50 Seiten, kein
  Scan, kein verschlüsseltes PDF); das passiert ebenfalls in der Wegwerf-Umgebung.
- Das Lesen der Seiten passiert in einer **Wegwerf-Umgebung** (einem kleinen Linux-Rechner in
  deinem Mac), die deine Dateien nicht sieht und dein Heimnetz nicht erreicht.
- Vor **jeder** Frage prüft die App, ob diese Umgebung richtig abgesichert ist. Steht bei
  *Web sandbox* **Ready**, hat die Prüfung bestanden. Steht dort **Not verified** (rot), bleibt
  das Fragen gesperrt.
- **Security check** auf der Sandbox-Karte macht einen längeren Test (etwa eine Minute) und
  zeigt jede Prüfung einzeln. Alles sollte grün sein.
- Bei **Check** am Modell-Programm prüft die App außerdem, ob es auch von anderen Geräten in
  deinem Netz erreichbar wäre. Dann erscheint eine orange Warnung. Bei llama.cpp: starte das
  Programm neu und achte darauf, dass `--host 127.0.0.1` dabei ist. TUFF bleibt immer auf
  127.0.0.1; eine Warnung bei TUFF heißt, dass ein anderes Programm diesen Anschluss benutzt.
  Erscheint stattdessen ein Hinweis, dass die App es nicht feststellen konnte, erlaube
  SandSeek unter *Systemeinstellungen > Datenschutz & Sicherheit > Lokales Netzwerk* den
  Zugriff und drücke noch einmal **Check**.

Das ist keine Garantie. Ein Modell kann falsche Seiten glauben und sich irren. Lies die
Quellen, vor allem bei wichtigen Fragen. Mehr dazu steht in `docs/SECURITY.md`.

## Wenn etwas nicht klappt

- **Not running** beim Modell-Programm: Es läuft nicht oder unter einer anderen Adresse. Starte
  es und drücke **Check**.
- **Not verified** bei der Sandbox: Drücke **Stop Sandbox**, dann wieder **Start Sandbox**.
  Bleibt es rot, öffne die Sicherheitsprüfung und kopiere die roten Zeilen in den Chat, in dem du Hilfe suchst.
- **Die Frage ist sehr langsam:** Schließe andere große Programme. Ein Mac mit 16 GB schafft
  nur ein Modell zur Zeit.
- **llama.cpp lehnt den Schlüssel ab:** Starte es neu mit dem Befehl von der Karte.

## Aufräumen

Beende SandSeek und das Modell-Programm. Lege die App und, wenn du willst, den Ordner
`SandSeek` in `Library/Application Support` in den **Papierkorb** (dort liegen auch deine
Berichte, kopiere sie vorher, wenn du sie behalten willst). Eine genaue Liste steht in
`docs/INSTALL.md`.
