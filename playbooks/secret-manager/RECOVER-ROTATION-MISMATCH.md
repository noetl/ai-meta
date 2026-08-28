# RECOVERY — Cloud SQL does not match Secret Manager v2

**Owner runs steps 1–2. The agent runs step 3.** Prod is currently serving on the
old pod's pooled connections; see the timing note at the bottom.

## What went wrong

The Cloud SQL password was set to something that is **not** the value in
`noetl-postgres-password` **v2**. The new pod mounts v2 correctly
(`source="file"`) and Postgres rejects it: `SASL authentication failed`.

## Verified before writing this

`noetl-postgres-password` **v2 is 44 bytes with NO trailing newline** — its raw and
newline-stripped sha256 are identical. So there is exactly one candidate value and
the file below is byte-exact.

    v2 sha256[:12] = 625b68042c6c   (44 bytes)

---

## Step 1 — recreate the file and PROVE it matches before touching Cloud SQL

```bash
umask 077
gcloud secrets versions access 2 --secret=noetl-postgres-password \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com > /tmp/pgv2

# GATE — all three must agree. Do NOT proceed if they do not.
wc -c < /tmp/pgv2                                  # expect exactly 44
shasum -a 256 /tmp/pgv2 | cut -c1-12               # expect 625b68042c6c
tr -d '\n\r' < /tmp/pgv2 | shasum -a 256 | cut -c1-12   # expect 625b68042c6c
```

If `wc -c` shows **45**, a newline crept in — fix it and re-check:

```bash
tr -d '\n\r' < /tmp/pgv2 > /tmp/pgv2.fixed && mv /tmp/pgv2.fixed /tmp/pgv2
shasum -a 256 /tmp/pgv2 | cut -c1-12               # must now be 625b68042c6c
```

This is the step that was missing the first time: the mismatch is caught **here**,
before Cloud SQL, instead of as another crashloop.

## Step 2 — set Cloud SQL from that exact file

### Preferred: clipboard, so nothing is typed

```bash
pbcopy < /tmp/pgv2        # macOS. Linux: xclip -selection clipboard < /tmp/pgv2

gcloud sql users set-password noetl \
  --instance=noetl-shared-pg \
  --prompt-for-password \
  --project=shastaratech-noetl-prod --account=shastaratech@gmail.com
# At the prompt: paste (Cmd-V), then Enter. Do not type, do not add a space.
# The clipboard holds exactly the 44 verified bytes and no newline.
```

⚠ **Do not use `--prompt-for-password < /tmp/pgv2`.** The prompt reads the TTY, not
stdin, so a redirect will typically hang or submit nothing. I could not test this
without changing the password, so I will not recommend it blind.

⚠ **Never `--password="$(cat /tmp/pgv2)"`** — that puts the value in argv, readable
by any local user via `ps`.

### Alternative: no paste at all (Cloud SQL Admin API)

Use this if the clipboard is unavailable or a paste failed once already. The value
goes from file → JSON → request body; it never touches argv or the clipboard.

```bash
python3 -c 'import json;print(json.dumps({"name":"noetl","password":open("/tmp/pgv2").read()}))' > /tmp/pgbody.json
chmod 600 /tmp/pgbody.json

curl -sS -X PUT \
  -H "Authorization: Bearer $(gcloud auth print-access-token --account=shastaratech@gmail.com)" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/pgbody.json \
  "https://sqladmin.googleapis.com/v1/projects/shastaratech-noetl-prod/instances/noetl-shared-pg/users?name=noetl&host=" \
  | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("status") or d.get("error",{}).get("message"))'
# expect: PENDING or DONE

shred -u /tmp/pgbody.json 2>/dev/null || rm -f /tmp/pgbody.json
```

## Step 3 — nothing further to run; the pod self-heals

The crashlooping pod **already has v2 mounted**. Once Cloud SQL matches, its next
backoff retry succeeds — no new roll, no further command. Backoff is capped at
5 minutes.

Tell the agent when step 2 reports success; it verifies pod Ready, `source="file"`,
a live DB read, no SASL errors, the old pod replaced, and an end-to-end execution.

## Clean up

```bash
shred -u /tmp/pgv2 2>/dev/null || rm -f /tmp/pgv2
pbcopy < /dev/null        # clear the clipboard
```

## Timing — how urgent, precisely

`pgbouncer` runs `POOL_MODE=transaction`, `SERVER_IDLE_TIMEOUT=120`,
`MIN_POOL_SIZE=1`, `DEFAULT_POOL_SIZE=12`.

Any backend connection idle for **120 seconds** is closed and **cannot be
re-established**, because re-auth uses the dead password. This is a one-way
ratchet, not a countdown: under steady traffic the warm connections persist; every
quiet gap over two minutes permanently removes one. Failures therefore appear
gradually and irreversibly rather than all at once.

Practical read: it is not "prod dies in two minutes", but every minute that passes
makes recovery more likely to require the pool to rebuild — which it cannot do
until step 2 lands.

## Not doing, and will not do

Rolling back to **v1**. That is the publicly-exposed password; reverting would
re-open the exposure to work around a condition that self-heals. It stays
break-glass only, and prod is still serving.
