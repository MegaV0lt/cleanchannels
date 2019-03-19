#!/bin/bash

# cleanchannels.sh - Kanalliste des VDR aufräumen
# Author: MegaV0lt
VERSION=161011

# 01.09.2013: Leere Kanalgruppen werden entfernt
#             Neu-Marker wird nur gesetz, wenn auch bereits Kanäle seit dem
#             letzten Lauf gefunden wurden
#             Entfernt-Marker wird nur gesetzt, wenn auch Kanäle gelöscht werden
# 04.09.2013: Log in Datei hinzugefügt. Zum deaktivieren "LOGFILE" auskommentiern (#)
# 06.09.2013: Logdatei nach *.old verschieben, wenn größer als 100 kb
# 12.09.2013: Logdatei - Handling verbessert. Größe einstellbar (in Byte)
#             Fehler beim letzten Marker behoben
# 16.01.2014: VDR (ab 2.1.3) "OBSOLETE" Marker wird mitgeloggt
# 12.02.2014: Optional: Entfernen von "OBSOLETE"-Kanälen

# Funktionsweise:
# 1. Die channels.conf wird gesichert (channels.conf.bak).
# 2. Die channels.conf.bak wird zeilenweise nach Markern ("-OLD-") durchsucht.
#    a) Kanäle mit Marker werden in die channels.conf.removed geschrieben.
#    b) Kanäle ohne Marker werden (neu) markiert und in die channels.conf.new
#+      geschrieben.
# 3. Wenn der VDR nicht läuft, wird die channels.conf.new nach channels.conf
#+   kopiert.

# Die Marker werden beim Provider angelegt (nach dem ;) sind also in der
#+Kanalliste nicht sichtbar.

# Das Skript sollte etwa ein mal im Monat (Vorgabe: 25 Tage) ausgeführt werden.
# Bei Systemen mit nur einem Tuner sollte zur Sicherheit ein größerer Intervall
#+gewählt werden (100 Tage oder mehr). Am besten direkt vor dem VDR-Start mit
#+Parameter für die Tage, die der VDR Zeit bekommen soll, seine Kanalliste zu
#+aktualisieren. Im VDR sollte die Option "EPG aktualisieren" aktiv sein.
# Beispiel:
# /usr/local/sbin/cleanchannels.sh 25 # Alle 25 Tage starten (Vorgabe)

# Um das Skript unter Gen2VDR ab V3 vor dem VDR zu starten, kann die Datei
#+8000_cleanchannels wie folgt unter /etc/vdr.d angelegt werden:
# echo "/usr/local/sbin/cleanchannels.sh 25" > /etc/vdr.d/8000_cleanchannels

# Einstellungen
CHANNELSCONF='/etc/vdr/channels.conf'   # Kanalliste des VDR
OLDMARKER='-OLD-'                       # Markierung (Keine ~ ; : verwenden!)
# VDR ab 2.1.3 - OBSOLETE Marker. Auskommentieren, wenn Kanäle nicht entfernt werden sollen
VDROBSOLETE='OBSOLETE'                  # Auskommentieren, wenn OBSOLETE drin bleiben soll
DAYS=25                                 # Liste alle XX Tage prüfen
LOGFILE='/var/log/cleanchannels.log'    # Aktivieren für zusätzliches Log
MAXLOGSIZE=$((50*1024))                 # Log-Datei: Maximale größe in Byte
CHANNELSNEW="${CHANNELSCONF}.new"       # Neue Kanalliste
CHANNELSBAK="${CHANNELSCONF}.bak"       # Kopie der Kanalliste
CHANNELSREMOVED="${CHANNELSCONF}.removed" # Gelöschte Kanäle
SETUPCONF='/etc/vdr/setup.conf'         # VDR Einstellungen (Wird nur gelesen)
RUNDATE="$(date "+%d.%m.%Y %R")"        # Aktuelles Datum und Zeit
#DEBUG=1                                # Debug-Ausgaben
group=0 ; delchan=0 ; marked=0          # Für die Statistik

# Funktionen
log() {     # Gibt die Meldung auf der Konsole und im Syslog aus
  logger -s -t $(basename ${0%.*}) "$*"
  [[ -n "$LOGFILE" ]] && echo "$*" >> "$LOGFILE"        # Log in Datei
}

### Skript start!

if [[ -n "$1" ]] ; then # Falls dem Skript die Tage übergeben wurden.
  [[ $1 =~ ^[0-9]+$ ]] && DAYS="$1"  # Numerischer Wert
fi

[[ -n "$LOGFILE" ]] && log "==> $RUNDATE - $(basename $0) - Start..."

if [[ -e "$CHANNELSNEW" && $DAYS -ne 0 ]] ; then  # Erster Start?
  ACT_DATE=$(date +%s) ; FDATE=$(stat -c %Y "${CHANNELSNEW}")
  DIFF=$(($ACT_DATE - $FDATE))     # Sekunden
  if [[ $DIFF -lt $(($DAYS*60*60*24)) ]] ; then
    TAGE=$((DIFF /86400)) ; STD=$((DIFF % 86400 /3600))
    MIN=$((DIFF % 3600 /60)) ; SEK=$((DIFF % 60))
    [[ $TAGE -gt 0 ]] && TAGSTR="$TAGE Tag(en) "
    log "Letzte Ausführung vor $TAGSTR$STD Std. $MIN Min.! Stop."
    exit 1                        # Letzter Start vor weniger als XX Tage!
  fi
else
  if [[ $DAYS -eq 0 ]] ; then        # Erzwungener Start?
    log "Erzwungener Start des Skript's"
   else                             # Erster Start?
    log "Erster Start des Skript's"
  fi
fi

while read -r LINE ; do  # Hier werden verschiedene VDR-Optionen geprüft
  if [[ "$LINE" == "EPGScanTimeout = 0" ]] ; then
    log "WARNUNG: EPG-Scan ist deaktiviert! (${LINE})"
  fi
  if [[ "$LINE" == "UpdateChannels = 0" ]] ; then
    log "FATAL: Kanäle aktualisieren ist deaktiviert! (${LINE})"
    exit 1  # Ohne Kanalaktualisierung geht das hier nicht!
  fi
done < "$SETUPCONF"  # VDR-Einstellungen

if [[ -e "$CHANNELSCONF" ]] ; then  # Prüfen, ob die channels.conf existiert
  cp --force "$CHANNELSCONF" "$CHANNELSBAK"  # Kanalliste kopieren
  [[ -e "$CHANNELSNEW" ]] && rm --force "$CHANNELSNEW"  # Frühere Liste löschen
else
  log "FATAL: $CHANNELSCONF nicht gefunden!"
  exit 1
fi

OLDIFS="$IFS"                         # Interner Feldtrenner

# Die $CHANNELSREMOVED sammelt die gelöschten Kanäle. Markierung setzen, um
#+später leichter zu sehen, wann die Kanäle entfernt wurden. Die Markierung wird
#+nur gesetzt, wenn auch mindestens ein Kanal gelöscht wird.
REMOVED=":==> Entfernt am ${RUNDATE}"

while read -r CHANNEL ; do
  if [[ "${CHANNEL:0:1}" = ":" ]] ; then   # Marker auslassen (: an 1. Stelle)
    if [[ -n "$MARKERTMP" ]] ; then        # Gespeicherter Marker vorhanden?
      log "Leere Kanalgruppe \"${MARKERTMP:1}\" entfernt!"
      ((delgroup++))
    fi
    MARKERTMP="$CHANNEL"                   # Marker zwischenspeichern
    continue                               # Weiter mit der nächsten Zeile
  fi
  if [[ -n "$VDROBSOLETE" && "$CHANNEL" =~ "$VDROBSOLETE" ]] ; then  # Markierung gefunden?
    ((obsolete++)) ; OBSFOUND=1
    [[ "$DEBUG" ]] && echo "$VDROBSOLETE - $CHANNEL"
  fi
  if [[ "$CHANNEL" =~ "$OLDMARKER" || -n "$OBSFOUND" ]] ; then  # Markierung gefunden?
    if [[ -n "$REMOVED" ]] ; then
      echo "$REMOVED" >> "$CHANNELSREMOVED"  # Markierung nach *.removed
      unset -v "REMOVED"                     # Markierung löschen
    fi
    echo "$CHANNEL" >> "$CHANNELSREMOVED"    # Kanal nach *.removed
    ((delchan++)) ; unset OBSFOUND
    [[ "$DEBUG" ]] && echo "$OLDMARKER - $CHANNEL"
  else                                         # Keine Markierung
    IFS=':'                                    # Daten sind mit : getrennt
    CHANNELDATA=(${CHANNEL})                   # In Array einfügen
    if [[ "${CHANNELDATA[0]}" =~ ";" ]] ; then
      CHANNEL="${CHANNEL/;/;$OLDMARKER}"       # Marker einfügen (Provider)
    else                                       # Kein Provider gefunden
      CHANNELDATA[0]="${CHANNELDATA[0]};$OLDMARKER"
      CHANNEL="${CHANNELDATA[*]}"              # Aus dem Array -> Variable
    fi
    if [[ -n "$MARKERTMP" ]] ; then         # Gespeicherter Marker vorhanden?
      echo "$MARKERTMP" >> "$CHANNELSNEW"   # Marker in die neue Liste
      unset -v "MARKERTMP"                  # Gespeicherten Marker löschen
      ((group++))
    fi
    echo "$CHANNEL" >> "$CHANNELSNEW"       # Kanal in die neue Liste
    IFS="$OLDIFS" ; ((marked++))
  fi
done < "$CHANNELSBAK"  # Backup verwenden um konflikt mit VDR zu vermeiden

# Als letzter Eintrag kommt noch ein Neu-Marker. Damit kann man schön
#+kontrollieren, was seit dem Aufräumen wieder neu dazugekommen ist
if [[ -n "$MARKERTMP" ]] ; then             # Gespeicherter Marker vorhanden?
  if [[ "$MARKERTMP" =~ ":==" ]] ; then     # Keine neuen Kanäle seit letzem Lauf!
    log "Keine neuen Kanäle seit letzem Lauf! (${MARKERTMP})"
  fi
  echo "$MARKERTMP" >> "$CHANNELSNEW"       # Marker in die neue Liste
  unset -v "MARKERTMP"                      # Gespeicherten Marker löschen
  ((group++))
else                                        # Letzter war ein Kanaleintrag
  echo ":==> Neu seit $RUNDATE" >> "$CHANNELSNEW"
fi

if [[ ! "$(pidof vdr)" ]] ; then            # VDR läuft?
  cp --force "$CHANNELSNEW" "$CHANNELSCONF" # Neue Liste aktivieren
else
  log "VDR läuft! Neue Kanalliste: $CHANNELSNEW"
fi

if [[ -e "$LOGFILE" ]] ; then               # Log-Datei umbenennen, wenn zu groß
  FILESIZE="$(stat -c %s "$LOGFILE")"
  [[ $FILESIZE -ge $MAXLOGSIZE ]] && mv --force "$LOGFILE" "${LOGFILE}.old"
fi

# Statistik
log "$group Kanalgruppen (:) gefunden"
[ -n "$delgroup" ] && log "$delgroup leere Kanalgruppe(n) entfernt"
log "$delchan Kanäle wurden nach $CHANNELSREMOVED verschoben"
[ -n "$obsolete" ] && log "$obsolete Kanäle vom VDR als \"OBSOLETE\" markiert"
log "$marked Kanäle wurden neu markiert (${OLDMARKER})"

exit
