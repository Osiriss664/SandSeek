# So funktioniert SandSeek

Kurz und ohne Fachwissen. Die ausführliche Fassung auf Englisch steht in
[HOW_IT_WORKS.md](HOW_IT_WORKS.md), die Bedienung in [ANLEITUNG.md](ANLEITUNG.md).

## Die drei Teile

- **Das Modell-Programm** (TUFF oder llama.cpp) läuft auf deinem Mac und denkt.
  Du startest es selbst. Es ist nur von deinem Mac aus erreichbar.
- **SandSeek** (die App oder der Befehl `sandseek`) ist der Vermittler. Es fragt
  das Modell, was als Nächstes zu tun ist, erledigt das und gibt das Ergebnis
  zurück ans Modell.
- **Die Sandbox** ist ein kleiner Wegwerf-Computer (eine Linux-VM von Apple
  `container`) auf deinem Mac. Nur sie geht ins Internet.

## Was bei einer Frage passiert

1. Du stellst eine Frage.
2. Das Modell entscheidet: suchen oder eine Seite lesen. Andere Werkzeuge hat es
   nicht, also keine Befehle, keine Dateien, kein eigenes Netz.
3. Die Sandbox sucht im Web oder lädt die Seite oder das PDF. Sie macht daraus
   reinen Text und gibt nur diesen Text zurück.
4. SandSeek entfernt unsichtbare Zeichen und markiert den Text als „fremder
   Webinhalt“, damit das Modell ihn nicht mit deiner Frage verwechselt.
5. Nach einigen Runden schreibt das Modell die Antwort mit nummerierten Quellen
   [1], [2]. SandSeek speichert sie als Bericht.

## Was dich schützt

- Die Sandbox kann deinen Mac, deine Dateien und dein Heimnetz nicht erreichen.
  Ihre Firewall lässt nur SandSeek herein, und Adressen im eigenen Netz lehnt
  sie ab.
- Jede Antwort der Sandbox ist signiert. SandSeek merkt, wenn ein anderes
  Programm sich als Sandbox ausgibt.
- PDFs werden nur in der Sandbox gelesen, in einem eigenen Prozess mit Grenzen
  für Speicher und Zeit. Heraus kommt nur Text.
- Ein Bericht lädt nichts nach. Eine Quelle öffnet sich erst, wenn du es
  bestätigst.

## Was nicht geschützt ist

- Eine Webseite oder ein PDF kann versteckte Anweisungen enthalten. Das Modell
  kann ihnen folgen. Es kann dann aber nur suchen und lesen, nichts auf deinem
  Mac tun.
- Eine Antwort kann falsch sein. Prüfe die Quellen, besonders bei Zahlen und
  Namen.
- Deine Suchbegriffe und die Adressen der gelesenen Seiten gehen ins Internet.
  Deine Frage und die Antwort bleiben auf dem Mac.

Alle Einzelheiten und die Tests: [SECURITY.md](SECURITY.md).
