# Catalog backup — the 35 paths naming `noetl-demo-19700101`

Taken 2026-08-05 from the **live prod catalog** (`shastaratech-noetl-prod`,
1,389 entries / 307 distinct paths) before any repoint of
[ai-meta#234](https://github.com/noetl/ai-meta/issues/234).

## Why it exists

Most of these paths exist **only in the catalog**. A spot-check for a
recoverable source file found `files_found=0` for four of five sampled
paths — `noetl.catalog` is not an event-sourced table, so there is no
replay to reconstruct a deleted row from. Anything destructive here is
one-way unless the content is captured first. This is that capture.

## What is where, and why it is split

| | |
| :-- | :-- |
| `manifest.json` (here, committed) | path, `catalog_id`, version, kind, `created_at`, content size, **`content_sha256`** |
| `/Volumes/X10/projects/noetl/catalog-backups/catalog-backup-20260805.json` (**not** committed) | the full content of all 35 latest versions, 4.3 MB |

The content is deliberately **outside this repo**.
`agents/rules/allowed-content.md` forbids product code in ai-meta, and
this repo is public — 4.3 MB of playbook bodies is squarely product
content. The manifest is the audit trail; the hashes let you prove the
out-of-repo dump is the same bytes that were live on 2026-08-05.

A secret scan ran over the content before the split (private keys, AWS
keys, service-account JSON, bearer literals, `password=`/`api_key=`
assignments, long base64). The only hits were **15 base64 blobs that are
application data, not credentials** — decoded, they are Muno planner
prompts, a tool vocabulary, model pricing, and conversation turns.
Credentials in this platform are keychain aliases, never literals
(`agents/rules/execution-model.md`).

## Count note

**35, not the 34 in #234's body.** The difference is a version
comparison: the earlier pass compared versions as strings, so `v10`
sorted below `v9` and one path's latest version was misread. This
manifest compares numerically. Treat 35 as the number.

## Verifying the dump against this manifest

```bash
python3 - <<'PY'
import json, hashlib
man = json.load(open('manifest.json'))
dump = json.load(open('/Volumes/X10/projects/noetl/catalog-backups/catalog-backup-20260805.json'))
bad = [p for p, m in man.items()
       if hashlib.sha256((dump[p]['content'] or '').encode()).hexdigest() != m['content_sha256']]
print('MISMATCH:', bad) if bad else print(f'{len(man)} paths verified')
PY
```
