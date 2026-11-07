#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
stage=${1:?usage: capture-database.sh STAGE}
[[ "$stage" =~ ^[A-Za-z0-9._-]+$ ]] || exit 2
out="$TASK_EVIDENCE/database/$stage"
mkdir -p "$out"
date -u +%FT%TZ > "$out/time.txt"
# The local socket is already available to the PostgreSQL container. No
# passwords, role catalog, Secrets, or authentication files are exported.
psql=(kubectl -n ate-system exec -i postgres-0 -c postgres -- psql -X -U postgres -d atepg -v ON_ERROR_STOP=1)
"${psql[@]}" --csv > "$out/settings.csv" <<'SQL'
BEGIN READ ONLY;
SELECT name, setting FROM pg_settings WHERE name IN
 ('server_version','fsync','synchronous_commit','full_page_writes','wal_level','data_directory') ORDER BY name;
COMMIT;
SQL
kubectl -n ate-system exec postgres-0 -c postgres -- pg_dump -U postgres -d atepg --schema-only --schema=substrate --no-owner --no-privileges > "$out/schema.sql"
"${psql[@]}" --csv > "$out/rows.csv" <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT clock_timestamp() AS captured_at;
SELECT atespace,name,uid,version,octet_length(proto) AS proto_bytes,md5(proto) AS proto_md5
 FROM substrate.actors WHERE name LIKE 'lifecycle-%' ORDER BY atespace,name;
SELECT a.name AS actor,a.uid AS actor_uid,w.worker_name,octet_length(w.proto) AS assignment_proto_bytes
 FROM substrate.actors a LEFT JOIN substrate.worker_assignments w ON w.actor_uid=a.uid
 WHERE a.name LIKE 'lifecycle-%' ORDER BY a.name;
SELECT atespace,name,uid,version,octet_length(proto) AS proto_bytes
 FROM substrate.tags WHERE name='lifecycle-checkpoint';
SELECT atespace,actor_name,uid,version,octet_length(proto) AS proto_bytes
 FROM substrate.actor_egress_policies WHERE actor_name LIKE 'lifecycle-%';
SELECT c.relname,c.relkind,c.relpersistence FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='substrate' AND (c.relname IN ('actors','tags','workers','worker_assignments','worker_outbox','worker_outbox_default','worker_outbox_trim') OR c.relname LIKE 'worker_outbox_p%') ORDER BY c.relname;
SELECT * FROM substrate.schema_migrations ORDER BY id;
COMMIT;
SQL
"${psql[@]}" -Atq > "$out/proto-rows.jsonl" <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT json_build_object('kind','Actor','atespace',atespace,'name',name,'uid',uid,'version',version,'proto_hex',encode(proto,'hex'))
 FROM substrate.actors WHERE name LIKE 'lifecycle-%' ORDER BY atespace,name;
SELECT json_build_object('kind','ActorAssignment','name',actor_uid,'worker_name',worker_name,'proto_hex',encode(proto,'hex'))
 FROM substrate.worker_assignments WHERE actor_uid IN (SELECT uid FROM substrate.actors WHERE name LIKE 'lifecycle-%') ORDER BY actor_uid;
SELECT json_build_object('kind','Tag','atespace',atespace,'name',name,'uid',uid,'version',version,'proto_hex',encode(proto,'hex'))
 FROM substrate.tags WHERE name='lifecycle-checkpoint';
COMMIT;
SQL
go run "$TASK_EVIDENCE/scripts/decode-proto.go" < "$out/proto-rows.jsonl" > "$out/decoded-records.json"
kubectl-ate get actor lifecycle-counter -a ate-demo-counter -o json > "$out/api-counter.json"
printf '%s\n' "$out"
