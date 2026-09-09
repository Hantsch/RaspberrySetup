# DNS-Server mit AdGuard Home

Raspberry-Pi-Hostname und SSH-Alias: **`dns-server`**. Die Anwendung ist AdGuard Home;
der Rechnername bleibt auch bei einem späteren Softwarewechsel passend.

**SSH wird vollständig in WSL eingerichtet.** Deine Linux-Schlüssel, `~/.ssh/config`,
`known_hosts` und dein SSH-Agent werden weiterverwendet. PowerShell startet die
Automatisierung; Bash und Python führen die Arbeiten auf dem Pi aus.

```text
Internet -> Magenta-Router -> TP-Link (DHCP) -> LAN-Geräte
                                 |
                          Raspberry Pi (DNS)
PowerShell -> WSL -> ssh dns-server -> AdGuard Home
```

## Initial Setup

### 1. Image und Netzwerk vorbereiten

- Windows 10/11, PowerShell 5.1+ und WSL mit Bash, `ssh`, `scp`, `wslpath`.
  Fehlende SSH-Werkzeuge unter Debian/Ubuntu: `sudo apt-get install openssh-client`
  **in WSL**. Das Repository liegt auf einem Windows-Laufwerk, das WSL erreichen kann.
- Mit [Raspberry Pi Imager](https://www.raspberrypi.com/software/) **Raspberry Pi OS
  Lite, 64-bit** für Pi 3/4/5 oder Zero 2 W flashen; bei älteren Modellen ohne
  64-bit-Unterstützung Lite 32-bit. Kein Desktop nötig. Aktuelle
  [OS-Images](https://www.raspberrypi.com/software/operating-systems/) basieren auf Trixie.
- Zuverlässiges Netzteil, SD-Karte ab 16 GB. **Flashen löscht die ausgewählte Karte.**

Nutze deinen vorhandenen **WSL-Schlüssel** und kopiere dessen öffentlichen `.pub`-Teil
in Imager. Nur wenn du einen neuen Schlüssel möchtest, einmal in **WSL Bash**:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_dns-server
cat ~/.ssh/id_ed25519_dns-server.pub
```

Eine Passphrase wählen; vorhandene Schlüssel nicht überschreiben.

| Imager-Einstellung | Wert |
|---|---|
| Hostname | `dns-server` |
| Benutzer | Eigenen Admin-Benutzer anlegen; kein vorausgesetzter Benutzer `pi` |
| SSH | Aktivieren, Public-Key-Anmeldung mit deinem WSL-Schlüssel |
| Sprache/Region | Tastatur, Zeitzone und gegebenenfalls WLAN-Land |
| Netzwerk | Ethernet am TP-Link bevorzugt; alternativ WLAN-Zugangsdaten eintragen |

Pi starten. Im TP-Link eine **DHCP-Reservierung** für dessen verwendete MAC-Adresse
einrichten. Lease erneuern oder Pi neu starten, bis die reservierte IP aktiv ist.
Den bisherigen Router-DNS erst nach erfolgreichen Funktionstests umstellen.

### 2. SSH-Alias in WSL

In deiner bestehenden **WSL-Datei `~/.ssh/config`** ergänzen, vor einem `Host *`-Block:

```sshconfig
Host dns-server
    HostName <reservierte-Pi-IP>
    User <Imager-Benutzer>
    IdentityFile ~/.ssh/id_ed25519_dns-server
    IdentitiesOnly yes
```

`IdentityFile` auf deinen tatsächlichen Linux-Schlüssel setzen. Einen vorhandenen
SSH-Agent weiterverwenden. Bei verschlüsselten Schlüsseln muss der Agent auch aus
neuen WSL-Prozessen erreichbar sein, beispielsweise über
`IdentityAgent ~/.ssh/agent.sock` mit dem **tatsächlichen Socket deines Agents**.
Den Schlüssel dort mit `ssh-add` laden. Eine nur im interaktiven Terminal gesetzte
Variable `SSH_AUTH_SOCK` genügt möglicherweise nicht für PowerShell-Aufrufe.

```bash
# In WSL; beim ersten Verbinden den Host-Fingerprint prüfen und bestätigen:
ssh dns-server
# Auf dem Pi prüfen, dann mit exit zurück:
sudo -v
hostname -s
ip -4 -brief address
exit
```

Der Fingerprint kann an der Pi-Konsole mit
`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` geprüft werden.
Aus **PowerShell** den späteren Zugriffsweg testen:

```powershell
wsl --exec ssh -o BatchMode=yes dns-server true
```

Die Automatisierung verwendet die Standard-Distribution und deren Standardbenutzer.
Bei Bedarf `-WslDistribution Ubuntu` an jeden `manage.ps1`-Aufruf anhängen oder mit
`wsl --set-default Ubuntu` deine bestehende Distribution als Standard auswählen.
Manuelle Befehle dann entsprechend mit `wsl -d Ubuntu --exec ssh ...` ausführen.

### 3. Konfigurieren und installieren

Alle folgenden PowerShell-Befehle im Repository-Hauptverzeichnis ausführen:

```powershell
Copy-Item ./dns-server/config/example.json ./dns-server/config/local.json
notepad ./dns-server/config/local.json
# Falls die Ausführung lokaler, geprüfter Skripte gesperrt ist, für diese Sitzung:
Set-ExecutionPolicy -Scope Process Bypass
./dns-server/manage.ps1 Setup
```

| Konfiguration | Bedeutung |
|---|---|
| `hostname` | Tatsächlicher Pi-Hostname, standardmäßig `dns-server` |
| `ipv4`, `lan_subnet` | Reservierte IP und TP-Link-LAN-CIDR; Beispielwerte ersetzen |
| `interface` | Tatsächliche Schnittstelle, meist `eth0` oder `wlan0` |
| `timezone` | Zum Beispiel `Europe/Vienna` |
| `upstream_dns` | Resolver-IP oder `https://`-/`tls://`-Adresse; Beispiel: Quad9 über HTTPS |
| `bootstrap_dns` | Resolver-IPs zum Auflösen der verschlüsselten Upstream-Hostnamen |
| `dns_test_name` | Öffentlicher Name mit IPv4-Antwort, standardmäßig `example.com` |

Keine Resolver verwenden, die ihre Anfragen zurück an diesen Pi leiten.
Bootstrap-Namensauflösung erfolgt unverschlüsselt; die normalen Weiterleitungen
zum Beispiel-Upstream verwenden HTTPS. Clients im LAN verwenden zunächst normales DNS.

Setup prüft Hostname, Adresse und Netzmaske, aktualisiert OS-Pakete und installiert
das offizielle ARM-Release nach `/opt/AdGuardHome`. Die offizielle Einrichtungs-API
legt die aktuelle Konfiguration an. **Einmal das Passwort für AdGuard-Benutzer `admin`
im Terminal eingeben und bestätigen.** Es landet weder im Repository noch in Befehlsargumenten.

```powershell
./dns-server/manage.ps1 Status
$piAddress = (Get-Content ./dns-server/config/local.json -Raw | ConvertFrom-Json).ipv4
Resolve-DnsName example.com -Server $piAddress -DnsOnly

# SSH-Tunnel offen halten; im Windows-Browser http://127.0.0.1:3000 öffnen:
./dns-server/manage.ps1 Admin
```

Die Weboberfläche lauscht ausschließlich auf Pi-Loopback. Der SSH-Tunnel verschlüsselt
den Zugriff. `Ctrl+C` beendet den Tunnel. Anmeldung: `admin` und dein gewähltes Passwort.
DNS lauscht auf Loopback und der reservierten IPv4; zugelassen sind Loopback und dein LAN.

Setup ist wiederholbar: Es bewahrt Benutzer, Passwörter, Listen und sonstige Einstellungen.
Verwaltet werden Zeitzone, DNS-Adressen/Port, Upstreams/Bootstrap, leere Fallback-Liste,
LAN-Zugriff, Webadresse und deaktiviertes DHCP. Änderungen dieser Werte in der UI
werden beim nächsten Setup wieder durch `local.json` ersetzt. Netzwerk und Hostname
werden geprüft, nicht automatisch geändert. Eine unterbrochene Erstinstallation kann
mit `Setup` fortgesetzt werden; fremde AdGuard-Installationen werden nicht überschrieben.

### 4. TP-Link umstellen

- Im **LAN-DHCP** nur die reservierte Pi-IP als DNS verteilen. Zweites DNS-Feld leer
  lassen oder dieselbe IP wiederholen. Ein öffentlicher zweiter DNS erlaubt Umgehung.
- TP-Link bleibt DHCP-Server; AdGuard-DHCP bleibt aus. Im Router-Modus bedient Magenta
  nur das vorgelagerte Netz. Im AP-Modus die Einstellung am tatsächlichen DHCP-Router vornehmen.
- Client-Leases erneuern: `ipconfig /renew`, `ipconfig /flushdns`, dann `ipconfig /all`
  und AdGuards Abfrageprotokoll prüfen.
- Diese Automatisierung richtet **IPv4-DNS** ein. Alternative IPv6-DNS-Ankündigungen
  verhindern oder AdGuard separat für eine stabile IPv6-Adresse konfigurieren.
  Browser-DoH, Android Private DNS und VPN-DNS können die DHCP-Einstellung umgehen.
- Keine Portweiterleitung für DNS oder die Admin-Oberfläche ins Internet einrichten.

## Normal Maintenance

```powershell
./dns-server/manage.ps1 Status
./dns-server/manage.ps1 Backup
./dns-server/manage.ps1 Maintain
# Neustart ausschließlich bei bewusst gewähltem Wartungsfenster:
wsl --exec ssh -t dns-server "sudo reboot"
```

Zum Beispiel wöchentlich warten; vorher [Release Notes](https://github.com/AdguardTeam/AdGuardHome/releases)
lesen. `Maintain` lädt zuerst ein geprüftes Backup auf Windows, führt dann
`apt-get upgrade` und AdGuards offiziellen `--update` aus und prüft anschließend den Dienst.
Die Filter aktualisiert AdGuard selbst, anfänglich alle 24 Stunden; manuell über die Filter-Seite.

Backup und Wartung verursachen kurze DNS-Unterbrechungen. Bei fehlgeschlagenem Backup
starten keine Updates. Keine automatischen Reboots, Distribution-Upgrades oder Paketlöschungen.
OS-Konfigurationsdateien bleiben erhalten; zurückgehaltene Pakete werden angezeigt.
Nicht mehrere Administrationsläufe gleichzeitig ausführen.

Status prüft Dienst/Autostart, UDP/TCP-DNS, Weboberfläche, gespeicherte Filteraktivierung,
Filtercache, Disk/Inodes (Fehler ab 90%), fehlgeschlagene Systemdienste und zeigt
RAM/Last, Temperatur/Throttling und Reboot-Hinweise. Filtercache allein beweist nicht,
dass jeder Client korrekt filtert: zusätzlich dessen Abfragen im Webprotokoll prüfen.
Ein fehlender Reboot-Marker schließt bei Pi OS einen nötigen Kernel-Neustart nicht aus.

Unattended Upgrades werden nicht aktiviert: Wartungsfenster für den einzigen DNS-Server
sollen bewusst gewählt werden. Eine bereits vorhandene OS-Update-Policy bleibt bestehen.

## Backups und Wiederherstellung

`dns-server/backups/<Zeitstempel>-<ID>/` enthält `adguard-home.zip`, `SHA256.txt` und
`local.json`. Archiviert werden Programm, Konfiguration und Daten einschließlich
Abfragehistorie im Installationsverzeichnis; AdGuards eigene alten Update-Backups werden
ausgelassen. Externe Datenpfade benötigen eigene Backups. Kein vollständiges OS-Image.
Archive enthalten sensible Daten: geschützt aufbewahren, Kopie auf zweitem Datenträger.
Keine automatische Löschung alter Backups; lokale Konfiguration und Backups sind Git-ignoriert.

Wiederherstellung auf **derselben CPU-/OS-Architektur**: frischen Pi wie oben einrichten
und `Setup` ausführen. Gesicherte `local.json` zurückkopieren und Netzwerkwerte prüfen.
In **WSL** das gewünschte Archiv hochladen (Pfad ersetzen):

```bash
scp /mnt/c/Pfad/zum/adguard-home.zip dns-server:~/adguard-home.zip
ssh dns-server
# Auf dem Pi: ersetzt die Installation; der bisherige Stand bleibt als Ordner erhalten.
sudo systemctl stop AdGuardHome
sudo mv /opt/AdGuardHome "/opt/AdGuardHome.before-restore-$(date +%Y%m%d-%H%M%S)"
sudo python3 -m zipfile -e "$HOME/adguard-home.zip" /opt
sudo chmod 700 /opt/AdGuardHome
sudo chmod 755 /opt/AdGuardHome/AdGuardHome
sudo chmod 600 /opt/AdGuardHome/AdGuardHome.yaml
sudo /opt/AdGuardHome/AdGuardHome --check-config -c /opt/AdGuardHome/AdGuardHome.yaml -w /opt/AdGuardHome
sudo systemctl start AdGuardHome
exit
```

Danach in PowerShell `./dns-server/manage.ps1 Status` ausführen. Zurückgespielt werden
auch alte Admin-Passwörter und Bind-Adressen. Bei geänderter Pi-IP `Setup` mit der
angepassten `local.json` ausführen. Beim Wechsel der Architektur das alte Programm
nicht übernehmen; Konfiguration/Daten separat in eine passende Installation migrieren.

## Bestehender Pi mit altem Namen / Pi-hole

Falls der Pi bereits als `pi-hole` eingerichtet ist, zunächst über den alten WSL-Alias
verbinden. Vorhandene Pi-hole-Einstellungen bei Bedarf über dessen Teleporter sichern.
Bei tatsächlich installiertem Pi-hole während eines Wartungsfensters
`sudo systemctl disable --now pihole-FTL` ausführen. Es wird nicht automatisch deinstalliert.
Danach `sudo hostnamectl set-hostname dns-server` und mit `sudoedit /etc/hosts` den alten
Hostnamen in der `127.0.1.1`-Zeile ersetzen. Den neuen WSL-Alias `dns-server` auf dieselbe
reservierte IP/Benutzer/Schlüssel setzen. Erst dann AdGuard-Setup starten.
Pi-hole-Teleporter-Archive sind keine AdGuard-Backups; Filterlisten gezielt übernehmen.

## Troubleshooting

| Problem | Prüfung / Lösung |
|---|---|
| SSH funktioniert nur interaktiv | In WSL Agent/`IdentityAgent` prüfen; aus PowerShell `wsl --exec ssh -o BatchMode=yes dns-server true` |
| Falsche Distribution | `wsl --list --verbose`; `-WslDistribution` verwenden |
| Alter Host-Key nach Reflash | Neuen Fingerprint prüfen, dann in WSL `ssh-keygen -R <Pi-IP>` und erneut verbinden |
| Hostname/IP-Prüfung scheitert | In WSL `ssh dns-server "hostname -s; ip -4 -brief address"`; Alias/Reservierung/JSON korrigieren |
| Dienst startet nicht | In WSL `ssh -t dns-server "sudo journalctl -u AdGuardHome -n 100 --no-pager"` |
| Erstinstallation bricht ab | `/opt/AdGuardHome/bootstrap.log` auf dem Pi prüfen; `Setup` erneut ausführen |
| Port belegt | Auf dem Pi `sudo ss -lntup`; Konflikt auf 53 oder 3000 beheben |
| Filtercache fehlt | In der UI unter Filter aktualisieren, Internet/Zeitzone prüfen und `Status` wiederholen |
| Admin-Tunnel scheitert | Lokalen Port 3000 freimachen und WSLs Weiterleitung von Windows-Localhost prüfen |
| Clients umgehen Filter | DHCP/IPv6/DoH/VPN prüfen; DNS TCP und UDP 53 sowie Gäste-Isolation beachten |
| DNS-Ausfall | Vorübergehend Router-DNS zurückstellen und Client-Leases erneuern; nach Reparatur zurückwechseln |

Die Automatisierung startet WSLs Login-Bash; dessen Profil darf keine Eingaben verlangen
oder Banner ausgeben. Für `Admin` muss WSLs Weiterleitung von Windows-Localhost aktiv sein.
Direkt aus WSL funktionieren `ssh dns-server` und
`ssh -N -L 127.0.0.1:3000:127.0.0.1:3000 dns-server` ebenfalls.

## Lokale Prüfung und technische Grundlage

```powershell
./dns-server/tests/verify.ps1
wsl --exec bash ./dns-server/tests/verify.sh
# In einer Test-WSL mit python3-yaml:
wsl --exec python3 ./dns-server/tests/verify.py
# Optional mit einer separat heruntergeladenen AdGuard-Binärdatei für das Testsystem:
wsl --exec python3 ./dns-server/tests/integration.py /Pfad/zu/AdGuardHome
```

Die verify-Tests verwenden temporäre Dateien und simulierte Dienste. Der optionale
Integrationstest startet eine echte temporäre Instanz auf hohen Loopback-Ports und
prüft Einrichtungs-API und Konfigurationsformat; er installiert keinen Systemdienst.
Echte ARM-Installation, Updates, SSH-Tunnel und Router-DNS müssen auf deiner Hardware
geprüft werden.
Installation verwendet dasselbe Release-Paket wie der
[offizielle Installer](https://github.com/AdguardTeam/AdGuardHome/blob/master/scripts/install.sh),
anschließend die [Einrichtungs-API](https://github.com/AdguardTeam/AdGuardHome/blob/master/openapi/openapi.yaml)
und `AdGuardHome -s install`. YAML wird nur bei gestopptem Dienst geändert und mit
`--check-config` validiert; Updates verwenden `--update`.
Siehe [AdGuard-Konfiguration](https://github.com/AdguardTeam/AdGuardHome/wiki/Configuration).
