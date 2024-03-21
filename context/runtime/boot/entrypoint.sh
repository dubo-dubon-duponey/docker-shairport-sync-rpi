#!/usr/bin/env bash
set -o errexit -o errtrace -o functrace -o nounset -o pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]:-$PWD}")" 2>/dev/null 1>&2 && pwd)"
readonly root
# shellcheck source=/dev/null
. "$root/helpers.sh"
# shellcheck source=/dev/null
. "$root/mdns.sh"

helpers::logger::set "$LOG_LEVEL"

helpers::logger::log INFO "[entrypoint]" "Starting container"

helpers::logger::log DEBUG "[entrypoint]" "Checking directories permissions"
helpers::dir::writable "$XDG_RUNTIME_DIR/dbus" create
helpers::dir::writable "$XDG_RUNTIME_DIR/shairport-sync" create
helpers::dir::writable "$XDG_CACHE_HOME/shairport-sync" create
helpers::dir::writable "$XDG_STATE_HOME/avahi-daemon"

helpers::logger::log INFO "[entrypoint]" "Starting dbus"
mdns::start::dbus "$LOG_LEVEL"

helpers::logger::log INFO "[entrypoint]" "Starting avahi"
mdns::start::avahi "$LOG_LEVEL"

helpers::logger::log INFO "[entrypoint]" "Starting nqptp"

{
  nqptp 2>&1
} > >(helpers::logger::slurp "$LOG_LEVEL" "[nqptp]") \
  && helpers::logger::log INFO "[nqptp]" "nqptp stopped" \
  || helpers::logger::log ERROR "[nqptp]" "nqptp stopped with exit code: $?" &

helpers::logger::log DEBUG "[entrypoint]" "Preparing configuration"
[ "${MOD_MQTT_ENABLED:-}" == true ] && MOD_MQTT_ENABLED=yes || MOD_MQTT_ENABLED=no
[ "${MOD_MQTT_COVER:-}" == true ] && MOD_MQTT_COVER=yes || MOD_MQTT_COVER=no

configuration="$(cat "$XDG_CONFIG_DIRS"/shairport-sync/main.conf)"
[ ! -e "$XDG_CONFIG_HOME"/shairport-sync/main.conf ] || configuration+="$(cat "$XDG_CONFIG_HOME"/shairport-sync/main.conf)"

env


# shellcheck disable=SC2016
configuration+="$(printf '

mqtt = {
	enabled = "%s"; // set this to yes to enable the mqtt-metadata-service
	hostname = "%s"; // Hostname of the MQTT Broker
	port = %s; // Port on the MQTT Broker to connect to
	username = "%s"; //set this to a string to your username in order to enable username authentication
	password = "%s"; //set this to a string you your password in order to enable username & password authentication
//	capath = NULL; //set this to the folder with the CA-Certificates to be accepted for the server certificate. If not set, TLS is not used
	cafile = "%s"; //this may be used as an (exclusive) alternative to capath with a single file for all ca-certificates
	certfile = "%s"; //set this to a string to a user certificate to enable MQTT Client certificates. keyfile must also be set!
	keyfile = "%s"; //private key for MQTT Client authentication
//	topic = NULL; //MQTT topic where this instance of shairport-sync should publish. If not set, the general.name value is used.
//	publish_raw = "no"; //whether to publish all available metadata under the codes given in the metadata docs.
//	publish_parsed = "no"; //whether to publish a small (but useful) subset of metadata under human-understandable topics
//	empty_payload_substitute = "--"; // MQTT messages with empty payloads often are invisible or have special significance to MQTT brokers and readers.
//    To avoid empty payload problems, the string here is used instead of any empty payload. Set it to the empty string -- "" -- to leave the payload empty.
//	Currently published topics:artist,album,title,genre,format,songalbum,volume,client_ip,
//	Additionally, messages at the topics play_start,play_end,play_flush,play_resume are published
	publish_cover = "%s"; //whether to publish the cover over mqtt in binary form. This may lead to a bit of load on the broker
//	enable_remote = "no"; //whether to remote control via MQTT. RC is available under `topic`/remote.
//	Available commands are "command", "beginff", "beginrew", "mutetoggle", "nextitem", "previtem", "pause", "playpause", "play", "stop", "playresume", "shuffle_songs", "volumedown", "volumeup"
};

' \
  "$MOD_MQTT_ENABLED" \
  "${MOD_MQTT_HOST:-}" \
  "${MOD_MQTT_PORT:-1883}" \
  "${MOD_MQTT_USER:-}" \
  "${MOD_MQTT_PASSWORD:-}" \
  "${MOD_MQTT_CA:-}" \
  "${MOD_MQTT_CERT:-}" \
  "${MOD_MQTT_KEY:-}" \
  "$MOD_MQTT_COVER")"

printf "%s" "$configuration" > "$XDG_RUNTIME_DIR"/shairport-sync/main.conf
helpers::logger::log DEBUG "[entrypoint]" "Configuration finalized: $configuration"

helpers::logger::log DEBUG "[entrypoint]" "Preparing command"
# https://github.com/mikebrady/shairport-sync/blob/master/scripts/shairport-sync.conf
args=(\
  --name "$MOD_MDNS_NAME" \
  --output "$OUTPUT" \
  --mdns avahi \
  --port "${ADVANCED_AIRPLAY_PORT:-7000}" \
  --configfile "$XDG_RUNTIME_DIR"/shairport-sync/main.conf \
)

# Technically, there is also -vvv - which is "probably too much"
[ "$LOG_LEVEL" != "debug" ] || args+=(-vv --statistics)
[ "$LOG_LEVEL" != "info" ] || args+=(-v)
[ "$STUFFING" == "soxr" ] && args+=(--stuffing soxr) || args+=(--stuffing basic)
args+=("$@")
[ ! "$DEVICE" ] || [ "$OUTPUT" != "alsa" ] || args+=(-- -d "$DEVICE")

helpers::logger::log DEBUG "[entrypoint]" "Command ready to execute - handing over now:"
helpers::logger::log INFO "[entrypoint]" "Starting: shairport-sync ${args[*]}"
# Slurp logs at log_level and relog properly
{
  exec shairport-sync "${args[@]}" 2>&1
} > >(helpers::logger::slurp "$LOG_LEVEL" "[shairport-sync]")
