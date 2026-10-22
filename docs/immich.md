# Immich

Immich is the photo library at https://photos.skinke.net: phone backup,
timeline, faces and smart search. It is the addon
`gitops/addons/immich`, namespace `immich`. Server, machine learning and
Valkey come from the upstream `immich-charts` chart; the database, the
PVCs, the routes and the config secret are our own templates (why: see
[tech-choices.md](tech-choices.md), Photos).

## What runs where

| Part | What | Storage |
| --- | --- | --- |
| `immich-server` | API, web app and the job workers (thumbnails, metadata, video) | `library`: 770 Gi, StorageClass `zfs-thin` (a thin-provisioned ZFS filesystem, 1M records), mounted at `/data` |
| `immich-machine-learning` | CLIP (smart search, duplicates), faces, OCR, on CPU | `model-cache`: 10 Gi on `zfs-thin`; models come from Hugging Face on first use |
| `immich-valkey` | the job queues | `emptyDir`: survives a container restart, not a new pod |
| `immich-db` (CloudNativePG) | Postgres 18 with VectorChord and pgvector | `immich-db-1`: 20 Gi zvol on `zfs` |

The 800 GB share is those three volumes. Versions are in `values.yaml`: the
Immich image tags for server and machine learning (Renovate bumps them from
their `# renovate:` comments), the Postgres image and the VectorChord
version.

On the library, `library/<user>/<year>/<year-month-day>/<file>` holds the
originals as uploaded (Immich's storage template is on), so they are
readable without Immich. `thumbs/` and `encoded-video/` are derived and can
be regenerated; `backups/` holds Immich's own nightly database dumps
(02:00, the last 14).

Settings live in `templates/_config.tpl`, rendered with the OIDC client
secret into the Secret `immich-config` by External Secrets. With a config
file Immich's admin UI shows the settings but can't change them; change
them in git. The name is fixed, so after a config change run
`kubectl -n immich rollout restart deploy` to make the server read it.

The map is off (`map.enabled`): its tiles come from `tiles.immich.cloud`,
which would see which areas people look at. Reverse geocoding stays on; it
runs locally.

Metrics: a ServiceMonitor for the API (`:8081`) and the job workers
(`:8082`), a PodMonitor for Postgres. Upstream publishes no Grafana
dashboard.

## Signing in

Only through Keycloak (client `immich`); password login and the public
admin sign-up are off. An account is created at its first login, named by
the Keycloak username. Every tier can sign in; someone without a tier is
refused at Keycloak, before Immich sees them.

| Tier | Immich role |
| --- | --- |
| `homelab-admins` | admin |
| `homelab-operators`, `homelab-viewers` | user |

The role comes from the `immich_role` claim (the client's roles, granted per
tier in `gitops/addons/keycloak/tofu/groups.tf`) and is synced at every login, so
moving someone between tiers promotes or demotes them at their next login.

- **Web:** https://photos.skinke.net goes straight to Keycloak.
  `https://photos.skinke.net/auth/login?autoLaunch=0` shows Immich's own
  login page instead.
- **Phone:** install Immich (App Store, Google Play or F-Droid), enter
  `https://photos.skinke.net` as the server, tap *Login with OAuth*, sign
  in to Keycloak in the browser that opens (password, then the security key
  or passkey). Keycloak sends the browser back to the app on
  `app.immich:///oauth-callback`. The app then holds its own Immich session:
  backups keep running while Keycloak is down, but a new login needs it.

## What is public

The site is on the public edge without the `edge-oidc` gate, because the
phone app can't get through an OIDC gate. Immich's own login is the guard.
Without a session, these answer:

- `/.well-known/immich`, `/api/server/ping`, `version`, `features`,
  `config`, `media-types`, `/api/public/config`,
  `/api/admin/maintenance/status`: no user data, but the exact version, so
  someone can tell if we lag behind a security release.
- `/api/oauth/*`: the start and end of the Keycloak login.
- Shared links (`/share/<key>`, `/s/<slug>`, `?key=` on the API): whatever
  a user chose to share, to anyone with the link, optionally with a password
  and an expiry. A link sees only what was shared; deleting it ends access.

Everything else answers `401`. Immich has had serious advisories (account
takeover, RCE through an authenticated upload), so upgrades matter more
here than for a WireGuard-only service; they wait for review (below).

## Bulk upload

For a large backup of photo and video files. Each file becomes an asset in
the account the API key belongs to. Immich reads dates and GPS from the
files and builds thumbnails, faces and search itself. A Google Photos
Takeout keeps its metadata in JSON files the CLI ignores; use
[immich-go](https://github.com/simulot/immich-go) for that instead.

1. Sign in as the person who should own the photos. *Account settings → API
   keys → New API key*, with the permissions `asset.upload` and `user.read`,
   plus `album.read`, `album.create` and `albumAsset.create` if albums
   should be made from folder names. Keep the key out of shell history.
2. On the machine with the files, use the CLI at the server's version
   (`curl -s https://photos.skinke.net/api/server/version`); nixpkgs'
   `immich-cli` lags behind and is not for a v3 server. With Node.js 22 or
   newer (on loft01: `nix shell nixpkgs#nodejs`):

   ```sh
   export IMMICH_INSTANCE_URL=https://photos.skinke.net
   read -rs IMMICH_API_KEY; export IMMICH_API_KEY
   immich() { npx -y @immich/cli@3.3.3 "$@"; }
   ```

   Or the container: `docker run -it -v "$PWD:/import:ro" -e
   IMMICH_INSTANCE_URL -e IMMICH_API_KEY
   ghcr.io/immich-app/immich-cli:3.3.3 upload --recursive /import`.
3. Dry run, which hashes everything and reports what is new:

   ```sh
   immich upload --recursive --dry-run /path/to/backup
   ```

4. Upload (`--album` makes an album per folder name; leave it out
   otherwise):

   ```sh
   immich upload --recursive --concurrency 4 /path/to/backup
   ```

   If it is interrupted, run the same command again: the CLI hashes every
   file (SHA-1) and the server skips each one it already has for that user,
   so nothing is uploaded twice. Identical copies inside the backup are
   skipped the same way. Near-duplicates (a resized or re-saved copy) are
   kept; duplicate detection finds them later, under *Utilities → Review
   duplicates*. `.xmp` sidecars next to a file are uploaded with it.
5. Watch *Administration → Job queues*. Thumbnails, faces and smart search
   run on CPU; for a large library that takes hours to days. Concurrency per
   queue is `job.<queue>.concurrency` in the config file if it needs to go
   up for the import.
6. Check the timeline (dates), then delete the API key.

Space: `kubectl -n immich exec deploy/immich-server -- df -h /data`, or
`zfs get used,refquota` on the dataset. Grow the library by raising
`library.size` in `clusters/loft01/addons/immich/values.yaml`; it is a quota
change, online.

## Backups and restore

sanoid snapshots the library dataset and both zvols with the rest of the
pool, all at the same instant (see [operations.md](operations.md)). A newly
created volume gets its first daily snapshot the next day. The off-site
borg backup includes the library dataset once it is enabled. Immich's own
`pg_dump` lands in `backups/` on the library every night.

Find a volume's dataset name:

```sh
pv() { kubectl get pv "$(kubectl -n immich get pvc "$1" -o jsonpath='{.spec.volumeName}')" -o jsonpath='{.spec.csi.volumeHandle}'; }
lib=tank/$(pv library) db=tank/$(pv immich-db-1)
zfs list -t snapshot -o name,used,refer -r "$lib" "$db"
```

**A single file.** Mount the snapshot read-only on loft01 and copy it out
(`.zfs/snapshot` inside the pod does not work: the pod runs in a user
namespace):

```sh
doas mkdir /mnt/snap && doas mount -t zfs -o ro "$lib@<snapshot>" /mnt/snap
ls /mnt/snap/library/<user>/<year>/
doas umount /mnt/snap && doas rmdir /mnt/snap
```

If Immich still knows the asset (its file is just missing), copy the file
back to its original path with `kubectl cp`; otherwise upload it again with
the CLI.

**Everything, to one point in time.** Roll back the database and the
library to the same snapshot. CloudNativePG hibernation stops Postgres and
keeps its volume (it waits for Immich's connections, up to about three
minutes):

```sh
kubectl -n immich annotate clusters.postgresql.cnpg.io immich-db cnpg.io/hibernation=on
kubectl -n immich wait --for=delete pod/immich-db-1 --timeout=600s
doas zfs rollback "$db@<snapshot>"
doas zfs rollback "$lib@<snapshot>"
kubectl -n immich annotate clusters.postgresql.cnpg.io immich-db cnpg.io/hibernation-
kubectl -n immich rollout restart deploy/immich-server
```

`zfs rollback` goes to the newest snapshot; an older one needs `-r`, which
destroys the newer snapshots of that volume. Everything uploaded after the
snapshot is gone. (Tested: an asset deleted after the snapshot came back,
file and all.)

## Upgrades

Renovate opens one PR for the addon (`renovate/immich`) and never
automerges it.

- **Immich:** read the release notes for every version in between
  (breaking changes, and anything about the database or VectorChord), then
  merge. The image tags are pinned explicitly in `values.yaml`; the chart is
  pinned by version in `Chart.yaml`. The server runs its migrations at
  start; watch `kubectl -n immich logs deploy/immich-server`.
- **VectorChord** (`vchord.version`): the same value moves the extension
  image and the version the `Database` resource installs, so CloudNativePG
  restarts Postgres and runs `ALTER EXTENSION vchord UPDATE TO …` as
  `postgres`. Immich can't do that itself (it isn't a superuser) and fails to
  start until it has happened; it then rebuilds its vector indexes if they
  are missing. Immich's guide asks for a reindex after a VectorChord update:

  ```sh
  kubectl -n immich exec -it immich-db-1 -c postgres -- psql -d immich \
    -c 'REINDEX INDEX clip_index' -c 'REINDEX INDEX face_index'
  ```

  Immich accepts VectorChord `>=0.3 <2` (`server/src/constants.ts`); a major
  bump outside that range waits for Immich.
- **Postgres minor** (the image tag): CloudNativePG restarts the instance.
- **Postgres major:** by hand, never from a Renovate PR alone. The `18` is
  in the image tag, in the VectorChord image's tag prefix and in its paths
  (`templates/database.yaml`), and all three move together. CloudNativePG
  then runs an offline in-place `pg_upgrade`, mounting the old and new
  extension images side by side (its `postgres_upgrades.md`). Check first
  that Immich supports the new major (`postgres-standalone.md` in Immich's
  docs), that TensorChord publishes `vchord-scratch` for it, and that today's
  Immich dump is in `backups/`. Not tested here.

## Break-glass

When Keycloak is down nobody can start a new Immich session; see
[break-glass.md](break-glass.md), Immich.
