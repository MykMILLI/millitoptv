#!/usr/bin/env bash
# Installs MILLITOP TV watch parties into the tvadmin dashboard on millitop-host.
#
#   bash install.sh <commit-sha>
#
# Safe to re-run. Order of work:
#   1. preflight (nothing changes if anything is missing)
#   2. download pinned files from GitHub and verify sha256
#   3. back up server/, web/, package*.json, Dockerfile
#   4. copy files, patch index.mjs/main.jsx/Dockerfile, add nodemailer
#   5. apply the database schema as the database owner
#   6. rebuild + restart the dashboard container, health check
#   7. on any failure after step 3: restore the backup and restart the old build
set -Eeuo pipefail

SHA="${1:-}"
DASH="${DASH:-$HOME/millitop-tv-dashboard}"
REPO="MykMILLI/millitoptv"
BASE="tmp_remote_dashboard"
NODE_IMAGE="node:24-bookworm-slim"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m OK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "Pass the full 40-character commit SHA: bash install.sh <sha>"

# ---------------------------------------------------------------- preflight
say "Preflight"
command -v docker >/dev/null || die "docker not found"
command -v curl >/dev/null || die "curl not found"
command -v sha256sum >/dev/null || die "sha256sum not found"
docker compose version >/dev/null 2>&1 || die "docker compose plugin not found"
cd "$DASH" 2>/dev/null || die "Dashboard folder $DASH not found (set DASH=/path)"
for f in server/index.mjs web/main.jsx package.json .env; do [[ -f "$f" ]] || die "$DASH/$f is missing"; done

# Find the running dashboard container and its compose project.
CONTAINER=""
for c in $(docker ps --format '{{.Names}}'); do
  wd="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$c" 2>/dev/null || true)"
  if [[ -n "$wd" && "$(realpath -m "$wd")" == "$(realpath -m "$DASH")" ]] && docker exec "$c" test -f /app/server/index.mjs 2>/dev/null; then CONTAINER="$c"; break; fi
done
[[ -n "$CONTAINER" ]] || die "Could not find a running compose container built from $DASH (looked for /app/server/index.mjs). Nothing changed."
PROJECT="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$CONTAINER")"
SERVICE="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$CONTAINER")"
CONFIGS="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$CONTAINER")"
COMPOSE=(docker compose -p "$PROJECT" --project-directory "$DASH")
IFS=',' read -ra cfgs <<< "$CONFIGS"
for cfg in "${cfgs[@]}"; do [[ -f "$cfg" ]] && COMPOSE+=(-f "$cfg"); done
ok "dashboard container: $CONTAINER (project $PROJECT, service $SERVICE)"

envval() { grep -E "^$1=" .env | tail -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }
DB_HOST="$(envval DB_HOST || true)"; DB_NAME="$(envval DB_NAME || true)"; DB_NAME="${DB_NAME:-postgres}"
ORIGINS="$(envval ALLOWED_ORIGINS || true)"
PUBLIC="$(envval PUBLIC_ORIGIN || true)"; PUBLIC="${PUBLIC:-https://tvadmin.millitop.net}"
if [[ ",${ORIGINS// /}," != *",$PUBLIC,"* ]]; then
  warn "ALLOWED_ORIGINS in .env does not include $PUBLIC. Browser guests would get 'Origin not permitted'."
  warn "Add it (comma separated) and re-run:  ALLOWED_ORIGINS=...,$PUBLIC"
  die "Fix ALLOWED_ORIGINS first. Nothing changed."
fi
ok "ALLOWED_ORIGINS includes $PUBLIC"

# ---------------------------------------------------------------- download
say "Downloading watch party files at ${SHA:0:12}"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
RAW="https://raw.githubusercontent.com/$REPO/$SHA/$BASE"
curl -fsSL "$RAW/deploy/watch-party/manifest.sha256" -o "$STAGE/manifest.sha256" || die "Could not download the manifest for $SHA"
while read -r sum path; do
  [[ -z "$sum" ]] && continue
  [[ "$path" =~ ^(server|web|deploy)/[A-Za-z0-9._/-]+$ && "$path" != *..* ]] || die "Unexpected path in manifest: $path"
  mkdir -p "$STAGE/files/$(dirname "$path")"
  curl -fsSL "$RAW/$path" -o "$STAGE/files/$path" || die "Download failed: $path"
  echo "$sum  $STAGE/files/$path" | sha256sum -c --quiet - || die "Checksum mismatch: $path"
done < "$STAGE/manifest.sha256"
ok "$(grep -c . "$STAGE/manifest.sha256") files verified"

# ---------------------------------------------------------------- backup
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p backups
BACKUP="backups/pre-watch-party-$STAMP.tgz"
tar czf "$BACKUP" server web package.json $( [[ -f package-lock.json ]] && echo package-lock.json ) $( [[ -f Dockerfile ]] && echo Dockerfile )
ok "backup: $DASH/$BACKUP"

ROLLED_BACK=0
rollback() {
  [[ $ROLLED_BACK == 1 ]] && return; ROLLED_BACK=1
  warn "Restoring $BACKUP and restarting the previous build"
  rm -rf server/watch-party-web
  rm -f server/watch-party-*.mjs server/watch-party-schema.sql web/WatchPartyPanel.jsx
  tar xzf "$BACKUP"
  "${COMPOSE[@]}" build "$SERVICE" >/dev/null 2>&1 && "${COMPOSE[@]}" up -d "$SERVICE" >/dev/null 2>&1 \
    && warn "Previous version restored and running." || warn "Restore rebuild failed; run: ${COMPOSE[*]} up -d --build $SERVICE"
}
trap 'code=$?; if [[ $code != 0 ]]; then rollback; fi; rm -rf "$STAGE"' EXIT

# ---------------------------------------------------------------- install files
say "Installing files"
rm -rf server/watch-party-web
cp -R "$STAGE/files/server/." server/
cp "$STAGE/files/web/WatchPartyPanel.jsx" web/
docker run --rm --user "$(id -u):$(id -g)" -v "$DASH:/app" -v "$STAGE/files/deploy:/deploy:ro" -w /app "$NODE_IMAGE" \
  node /deploy/watch-party/patch-dashboard.mjs /app
for f in server/watch-party-*.mjs server/watch-party-web/watch.js server/watch-party-web/voice.js server/index.mjs; do
  docker run --rm -v "$DASH:/app:ro" -w /app "$NODE_IMAGE" node --check "$f" || die "Syntax check failed: $f"
done
if ! grep -q '"nodemailer"' package.json; then
  say "Adding nodemailer (SMTP)"
  docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e npm_config_update_notifier=false -v "$DASH:/app" -w /app "$NODE_IMAGE" \
    npm install --save-exact --no-audit --no-fund nodemailer@6.10.1 >/dev/null
fi
ok "files installed"

# ---------------------------------------------------------------- database
say "Applying database schema (as the database owner)"
SCHEMA_OK=0
DB_CANDIDATES=()
[[ -n "$DB_HOST" ]] && docker ps --format '{{.Names}}' | grep -qx "$DB_HOST" && DB_CANDIDATES+=("$DB_HOST")
while read -r n; do DB_CANDIDATES+=("$n"); done < <(docker ps --format '{{.Names}} {{.Image}}' | awk '/postgres|supabase\/postgres/ {print $1}')
for db in "${DB_CANDIDATES[@]}"; do
  for user in postgres supabase_admin; do
    has="$(docker exec -u postgres "$db" psql -U "$user" -d "$DB_NAME" -tAc "select to_regclass('millitop_tv.households') is not null" 2>/dev/null || true)"
    [[ "$has" == "t" ]] || continue
    owner="$(docker exec -u postgres "$db" psql -U "$user" -d "$DB_NAME" -tAc "select tableowner from pg_tables where schemaname='millitop_tv' and tablename='households'")"
    { [[ -n "$owner" && "$owner" != "$user" ]] && echo "SET ROLE \"$owner\";"; cat server/watch-party-schema.sql; } \
      | docker exec -i -u postgres "$db" psql -q -U "$user" -d "$DB_NAME" -v ON_ERROR_STOP=1 >/dev/null 2>"$STAGE/psql.err" \
      || { cat "$STAGE/psql.err" >&2; die "Schema apply failed in $db as $user"; }
    ok "schema applied in container $db (db $DB_NAME, as $user${owner:+, owner $owner})"
    SCHEMA_OK=1; break 2
  done
done
if [[ $SCHEMA_OK == 0 ]]; then
  warn "No local Postgres container with millitop_tv was found. Run server/watch-party-schema.sql as the DB owner manually."
  warn "Watch parties will answer 'database migration pending' until then; everything else keeps working."
fi

# ---------------------------------------------------------------- build + restart
say "Building and restarting $SERVICE (takes a few minutes)"
"${COMPOSE[@]}" build "$SERVICE"
"${COMPOSE[@]}" up -d "$SERVICE"
NEW="$("${COMPOSE[@]}" ps -q "$SERVICE" | head -1)"
[[ -n "$NEW" ]] || die "Container did not start"
say "Health check"
for i in $(seq 1 30); do
  if docker exec "$NEW" node -e "fetch('http://127.0.0.1:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then break; fi
  sleep 2
  [[ $i == 30 ]] && { docker logs --tail 40 "$NEW" >&2 || true; die "Dashboard did not become healthy"; }
done
docker exec "$NEW" node --input-type=module -e "
const b='http://127.0.0.1:3000';
const page=await fetch(b+'/watch/ABCDEFGH'); if(page.status!==200) {console.error('join page',page.status);process.exit(1)}
const js=await fetch(b+'/watch-assets/watch.js'); if(js.status!==200) {console.error('assets',js.status);process.exit(1)}
const l=await fetch(b+'/api/watch/lookup/ABCDEFGH'); const body=await l.json().catch(()=>({}));
console.log('lookup status',l.status,body.error??'');
process.exit(l.status===404||l.status===503?0:1)" || die "Watch party endpoints are not answering"
if docker exec "$NEW" node --input-type=module -e "const r=await fetch('http://127.0.0.1:3000/api/watch/lookup/ABCDEFGH');process.exit(r.status===503?1:0)"; then
  ok "watch party API ready"
else
  warn "watch party API reports 'migration pending' (schema not applied)"
fi
docker exec "$NEW" node --input-type=module -e "await import('nodemailer');" 2>/dev/null && ok "nodemailer available" || warn "nodemailer missing in image; invite email will report an error"

trap 'rm -rf "$STAGE"' EXIT
echo
ok "Watch parties deployed."
echo "   Join page:  $PUBLIC/watch"
echo "   Settings:   $PUBLIC  ->  Watch parties  (add SMTP, then 'Send test email')"
echo "   Backup:     $DASH/$BACKUP"
echo "   Reverse proxy note: the event stream uses Server-Sent Events. If guests stay on"
echo "   'Reconnecting', turn off proxy buffering for $PUBLIC (NPM > Advanced: proxy_buffering off;)."
