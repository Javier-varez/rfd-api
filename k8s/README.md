# Kubernetes manifests

Kustomize manifests for deploying `rfd-api`, `rfd-processor` and their Postgres
database. They use the images built from `docker/` — see the Containers section
of the root [README.md](../README.md).

```
k8s/
├── base/                     workloads, namespace-scoped to `rfd`
│   ├── namespace.yaml
│   ├── postgres.yaml         headless Service + StatefulSet with a PVC
│   ├── rfd-api.yaml          Service + Deployment (+ migrate init container)
│   └── rfd-processor.yaml    Deployment
└── overlays/
    └── dev/                  generates the secrets and config map
        ├── rfd-api.config.toml
        ├── rfd-processor.config.toml
        ├── mappers.toml
        └── postgres.env
```

The base is not deployable on its own — it references secrets and a config map
that an overlay supplies.

## Configuration

Configuration is injected, never baked into an image. Each file lands at the
first entry of its service's default config search path, so no `--config` flag
is needed.

| Source file | Object | Mounted at |
| --- | --- | --- |
| `rfd-api.config.toml` | Secret `rfd-api-config` | `/etc/rfd-api/config.toml` |
| `rfd-processor.config.toml` | Secret `rfd-processor-config` | `/etc/rfd-processor/config.toml` |
| `mappers.toml` | ConfigMap `rfd-api-mappers` | `/etc/rfd-api/mappers.toml` |
| `postgres.env` | Secret `rfd-postgres` | environment |

`mappers.toml` is a config map rather than a secret because it holds only group
names and mapping rules. The API's config and mapper files are combined into
`/etc/rfd-api` with a projected volume, which is why a secret and a config map
can share one directory.

Generated names carry a content hash (`rfd-api-config-g9tkmhmctf`), so editing
any of these files produces a new object name and rolls the pods that mount it.

### Credentials live in one place

`postgres.env` holds `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB`, which
initialise the database, and `DATABASE_URL`, which is injected into both
services. Both binaries layer environment variables over their config file, so
the injected `DATABASE_URL` **overrides** `database_url` in the mounted
config — editing that field alone has no effect.

That same layering is why both pods set `enableServiceLinks: false`. Kubernetes
otherwise injects an environment variable per service into every pod, and a
name that collided with a config field would silently override the file.

## Deploying

```sh
kubectl kustomize k8s/overlays/dev          # render
kubectl apply -k k8s/overlays/dev           # apply
```

The images must be reachable from the cluster. The `dev` overlay points at
`localhost/rfd-api:test` and `localhost/rfd-processor:test` with
`imagePullPolicy: IfNotPresent`, which suits a local node the images have been
side-loaded into (`kind load docker-image`, `minikube image load`). Point the
`images:` entries in the overlay at a registry for anything else.

Database migrations run as an init container on `rfd-api` before the server
starts. `rfd-api migrate` applies both the v-api migrations and the RFD
migrations embedded in `rfd-model`, needs only `DATABASE_URL`, and is safe to
repeat. If Postgres is not accepting connections yet the init container exits
non-zero and the kubelet retries it. `rfd-processor` does not wait for
migrations and will restart until the schema exists.

## Real deployments

Copy `overlays/dev` and substitute real values. Everything in it is a
placeholder — the GitHub token, OAuth credentials and database password all
read `replace-me`, and `keys = []` has to be replaced with at least one signer
and one verifier before authentication works. Treat your copy as sensitive and
keep it out of version control; consider an external secret manager instead of
kustomize's `secretGenerator` for production.

Changing `POSTGRES_PASSWORD` after the volume has been initialised does not
change the password in the database — alter it in Postgres or recreate the
volume.

## Constraints worth knowing

Both application containers run as uid 10001 with a read-only root filesystem
and all capabilities dropped. The only writable paths are `emptyDir` mounts:
`/tmp` for both, plus `/home/rfd` on the processor for Chromium's profile. Two
consequences for the config files:

- Leave `log_directory` unset so logs go to stdout. Setting it to `""` is not
  equivalent — that writes into the working directory and the service fails.
- Omit the `[spec]` table unless `output_path` points under `/tmp`.

Postgres runs with only `fsGroup: 999`. Its entrypoint starts as root to chown
`PGDATA` before dropping privileges, so the restrictive context used by the
other two would break `initdb` on first boot.

The processor is a singleton (`replicas: 1`, `strategy: Recreate`) because it
scans the RFD repository and claims jobs on a timer; a rolling update would
briefly run two copies.
