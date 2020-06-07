#!/bin/bash

# cleanchannels.sh - Kanalliste des VDR aufräumen
# Author: MegaV0lt
VERSION=200607

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

# Variablen
SELF="$(readlink /proc/$$/fd/255)" || SELF="$0"  # Eigener Pfad (besseres $0)
SELF_NAME="${SELF##*/}"
CHANNELSCONF='/etc/vdr/channels.conf'   # Kanalliste des VDR
OLDMARKER='-OLD-'                       # Markierung (Keine ~ ; : verwenden!)
SORTMARKER=':Andere'                    # Marker für "sortchannels.sh" behalten
# VDR ab 2.1.3 - OBSOLETE Marker. Auskommentieren, wenn Kanäle nicht entfernt werden sollen
VDROBSOLETE='OBSOLETE'                  # Auskommentieren, wenn OBSOLETE drin bleiben soll
DAYS=25                                 # Liste alle XX Tage prüfen
LOGFILE='/var/log/cleanchannels.log'    # Aktivieren für zusätzliches Log
MAXLOGSIZE=$((50*1024))                 # Log-Datei: Maximale größe in Byte
CHANNELSNEW="${CHANNELSCONF}.new"       # Neue Kanalliste
CHANNELSBAK="${CHANNELSCONF}.bak"       # Kopie der Kanalliste
CHANNELSREMOVED="${CHANNELSCONF}.removed" # Gelöschte Kanäle
SETUPCONF='/etc/vdr/setup.conf'         # VDR Einstellungen (Wird nur gelesen)
printf -v RUNDATE '%(%d.%m.%Y %R)T\n' -1  # Aktuelles Datum und Zeit
#DEBUG=1                                # Debug-Ausgaben
group=0 ; delchan=0 ; marked=0          # Für die Statistik

# Funktionen
f_log() {  # Gibt die Meldung auf der Konsole und im Syslog aus
  logger -s -t "$SELF_NAME" "$*"
  [[ -n "$LOGFILE" ]] && echo "$*" >> "$LOGFILE"        # Log in Datei
}

### Skript start!

if [[ -n "$1" ]] ; then # Falls dem Skript die Tage übergeben wurden.
  [[ $1 =~ ^[0-9]+$ ]] && DAYS="$1"  # Numerischer Wert
fi

[[ -n "$LOGFILE" ]] && f_log "==> $RUNDATE - $SELF_NAME #$VERSION - Start..."

if [[ -e "$CHANNELSNEW" && $DAYS -ne 0 ]] ; then  # Erster Start?
  printf -v ACT_DATE '%(%s)T\n' -1 ; FDATE=$(stat -c %Y "${CHANNELSNEW}")
  DIFF=$((ACT_DATE - FDATE))     # Sekunden
  if [[ $DIFF -lt $((DAYS*60*60*24)) ]] ; then
    TAGE=$((DIFF /86400)) ; STD=$((DIFF % 86400 /3600))
    MIN=$((DIFF % 3600 /60)) #; SEK=$((DIFF % 60))
    [[ $TAGE -gt 0 ]] && TAGSTR="$TAGE Tag(en) "
    f_log "Letzte Ausführung vor $TAGSTR$STD Std. $MIN Min.! Stop."
    exit 1                        # Letzter Start vor weniger als XX Tage!
  fi
else
  if [[ $DAYS -eq 0 ]] ; then        # Erzwungener Start?
    f_log 'Erzwungener Start des Skripts'
   else                             # Erster Start?
    f_log 'Erster Start des Skripts'
  fi
fi

while read -r LINE ; do  # Hier werden verschiedene VDR-Optionen geprüft
  if [[ "$LINE" == 'EPGScanTimeout = 0' ]] ; then
    f_log "WARNUNG: EPG-Scan ist deaktiviert! (${LINE})"
  fi
  if [[ "$LINE" == 'UpdateChannels = 0' ]] ; then
    f_log "FATAL: Kanäle aktualisieren ist deaktiviert! (${LINE})"
    exit 1  # Ohne Kanalaktualisierung geht das hier nicht!
  fi
done < "$SETUPCONF"  # VDR-Einstellungen

if [[ -e "$CHANNELSCONF" ]] ; then  # Prüfen, ob die channels.conf existiert
  cp --force "$CHANNELSCONF" "$CHANNELSBAK"  # Kanalliste kopieren
  [[ -e "$CHANNELSNEW" ]] && rm --force "$CHANNELSNEW"  # Frühere Liste löschen
else
  f_log "FATAL: $CHANNELSCONF nicht gefunden!"
  exit 1
fi

# Die $CHANNELSREMOVED sammelt die gelöschten Kanäle. Markierung setzen, um
#+später leichter zu sehen, wann die Kanäle entfernt wurden. Die Markierung wird
#+nur gesetzt, wenn auch mindestens ein Kanal gelöscht wird.
REMOVED=":==> Entfernt am ${RUNDATE}"

while read -r CHANNEL ; do
  if [[ "${CHANNEL:0:1}" == ':' ]] ; then   # Marker auslassen (: an 1. Stelle)
    if [[ "$CHANNEL" == "$SORTMARKER" ]] ; then  # Marker für "sortchannels.sh"
      echo "$CHANNEL" >> "$CHANNELSNEW"          # Kanal in die neue Liste
      if [[ -n "$MARKERTMP" ]] ; then            # Gespeicherter Marker vorhanden?
        unset -v 'MARKERTMP'                     # Gespeicherten Marker löschen
        ((delgroup++))
      fi
      continue                                   # Weiter mit der nächsten Zeile
    fi
    if [[ -n "$MARKERTMP" ]] ; then  # Gespeicherter Marker vorhanden?
      f_log "Leere Kanalgruppe \"${MARKERTMP:1}\" entfernt!"
      ((delgroup++))
    fi
    MARKERTMP="$CHANNEL"             # Marker zwischenspeichern
    continue                         # Weiter mit der nächsten Zeile
  fi
  if [[ -n "$VDROBSOLETE" && "$CHANNEL" =~ $VDROBSOLETE ]] ; then  # Markierung gefunden?
    ((obsolete++)) ; OBSFOUND=1
    [[ "$DEBUG" ]] && echo "$VDROBSOLETE - $CHANNEL"
  fi
  if [[ "$CHANNEL" =~ $OLDMARKER || -n "$OBSFOUND" ]] ; then  # Markierung gefunden?
    if [[ -n "$REMOVED" ]] ; then
      echo "$REMOVED" >> "$CHANNELSREMOVED"  # Markierung nach *.removed
      unset -v 'REMOVED'                     # Markierung löschen
    fi
    echo "$CHANNEL" >> "$CHANNELSREMOVED"    # Kanal nach *.removed
    ((delchan++)) ; unset -v 'OBSFOUND'
    [[ "$DEBUG" ]] && echo "$OLDMARKER - $CHANNEL"
  else                                         # Keine Markierung
    IFS=':' read -r -a CHANNELDATA <<< "$CHANNEL"  #In Array einfügen. Daten sind mit : getrennt
    if [[ "${CHANNELDATA[0]}" =~ ';' ]] ; then
      CHANNEL="${CHANNEL/;/;$OLDMARKER}"       # Marker einfügen (Provider)
    else     
      CHANNEL="${CHANNEL/:/;$OLDMARKER:}"      # Kein Provider gefunden
    fi
    if [[ -n "$MARKERTMP" ]] ; then         # Gespeicherter Marker vorhanden?
      echo "$MARKERTMP" >> "$CHANNELSNEW"   # Marker in die neue Liste
      unset -v 'MARKERTMP'                  # Gespeicherten Marker löschen
      ((group++))
    fi
    echo "$CHANNEL" >> "$CHANNELSNEW"       # Kanal in die neue Liste
    ((marked++))
  fi
done < "$CHANNELSBAK"  # Backup verwenden um konflikt mit VDR zu vermeiden

# Als letzter Eintrag kommt noch ein Neu-Marker. Damit kann man schön
#+kontrollieren, was seit dem Aufräumen wieder neu dazugekommen ist
if [[ -n "$MARKERTMP" ]] ; then             # Gespeicherter Marker vorhanden?
  if [[ "$MARKERTMP" =~ ':==' ]] ; then     # Keine neuen Kanäle seit letzem Lauf!
    f_log "Keine neuen Kanäle seit letzem Lauf! (${MARKERTMP})"
  fi
  echo "$MARKERTMP" >> "$CHANNELSNEW"       # Marker in die neue Liste
  unset -v 'MARKERTMP'                      # Gespeicherten Marker löschen
  ((group++))
else                                        # Letzter war ein Kanaleintrag
  echo ":==> Neu seit $RUNDATE" >> "$CHANNELSNEW"
fi

if [[ ! "$(pidof vdr)" ]] ; then            # VDR läuft?
  cp --force "$CHANNELSNEW" "$CHANNELSCONF" # Neue Liste aktivieren
else
  f_log "VDR läuft! Neue Kanalliste: $CHANNELSNEW"
fi

if [[ -e "$LOGFILE" ]] ; then               # Log-Datei umbenennen, wenn zu groß
  FILESIZE="$(stat -c %s "$LOGFILE")"
  [[ $FILESIZE -ge $MAXLOGSIZE ]] && mv --force "$LOGFILE" "${LOGFILE}.old"
fi

# Statistik
f_log "$group Kanalgruppen (:) gefunden"
[ -n "$delgroup" ] && f_log "$delgroup leere Kanalgruppe(n) entfernt"
f_log "$delchan Kanäle wurden nach $CHANNELSREMOVED verschoben"
[ -n "$obsolete" ] && f_log "$obsolete Kanäle vom VDR als \"OBSOLETE\" markiert"
f_log "$marked Kanäle wurden neu markiert (${OLDMARKER})"

exit
