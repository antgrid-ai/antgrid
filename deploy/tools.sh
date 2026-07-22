#!/usr/bin/env bash
# On-demand operator tools wrapper (pgweb, dozzle, filebrowser). These are NOT part of
# blue-green deploys and deploy.sh never touches them — start them when you need
# them, stop them when you're done.
#
#   ./tools.sh up [service]      start (pulls the image on first run); default: all
#   ./tools.sh stop [service]    stop but keep the container; default: all
#   ./tools.sh restart [service] restart; default: all
#   ./tools.sh down              stop AND remove every tool (whole project)
#   ./tools.sh logs <service>    follow a tool's logs
#   ./tools.sh status            show what's running + host port bindings
#
# Services (each binds to 127.0.0.1 only — reach via an SSH tunnel from your laptop):
#   pgweb        read-only Postgres browser   127.0.0.1:8081  (needs PG_DATABASE_URL in .env)
#   dozzle       live container-log viewer    127.0.0.1:8082
#   filebrowser  config file editor (/srv)    127.0.0.1:8083  (edits .env — holds SECRETS)
#
#   ssh -L 8081:127.0.0.1:8081 <user>@<host>   # then open http://localhost:8081  (pgweb)
#   ssh -L 8082:127.0.0.1:8082 <user>@<host>   # then open http://localhost:8082  (dozzle)
#   ssh -L 8083:127.0.0.1:8083 <user>@<host>   # then open http://localhost:8083  (filebrowser)
set -euo pipefail

# Resolve our own absolute path BEFORE cd (so `help` can still read this file),
# then run from this script's own dir so docker compose finds compose.tools.yml
# AND auto-loads ./.env (that's where ${PG_DATABASE_URL} for pgweb resolves from —
# compose reads .env literally, so the OAuth placeholders don't break it).
self="$(readlink -f "$0")"
cd "$(dirname "$self")"

compose() { docker compose -f compose.tools.yml -p ab-tools "$@"; }

cmd="${1:-status}"
[ "$#" -gt 0 ] && shift

case "$cmd" in
  up)             compose up -d "$@" ;;
  stop)           compose stop "$@" ;;
  restart)        compose restart "$@" ;;
  down)           compose down ;;   # whole-project teardown; ignores service args
  logs)           compose logs -f "$@" ;;
  status | ps)    compose ps ;;
  -h | --help | help)
    sed -n '2,20p' "$self" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "tools.sh: unknown command '$cmd'" >&2
    echo "usage: ./tools.sh {up|stop|restart|down|logs|status} [service]" >&2
    echo "services: pgweb (8081), dozzle (8082), filebrowser (8083)" >&2
    exit 2
    ;;
esac
