# Solectrus - Deployment for Tester Environment

## Quick Start

```bash
./tester-env deploy    # Build image, start services, wait for readiness
./tester-env seed      # Populate deterministic PV dashboard data
./tester-env verify    # Verify seeded settings and InfluxDB timeseries
./tester-env reset     # Clean slate (containers + volumes)
./tester-env status    # Show service status and ports
```

## Services

| Service    | Image               |
|------------|---------------------|
| PostgreSQL | postgres:18-alpine  |
| Redis      | redis:8-alpine      |
| InfluxDB   | influxdb:2.9-alpine |
| Dashboard  | source-built Rails 8|

## Credentials

- **Admin login:** `admin` / `adminpass123`
- **InfluxDB:** `admin` / `adminpass123` (token: `my-secret-admin-token`)
- **PostgreSQL:** `postgres` / `postgres`

First visit: Login page also registers the installation. The `TESTER_ENV_SKIP_REGISTRATION` env var bypasses the registration grace period.

## Port

Default: `13000` (configurable via `--port` or `PORT` env var).

Port 3000 is avoided due to chromium-browser container conflicts.

## Deterministic Seed Data

Profile: **Sonnenhof Kirchblick 9.8 kWp** / Mara Schneider

- 9 InfluxDB measurement fields with hourly data from 2025-01-01 through current day (Europe/Berlin)
- Fixed PostgreSQL settings for plant name, operator name, sensor names
- No forecast or registration gate

## Reset

```bash
./tester-env reset   # docker compose down -v (removes containers + all named volumes)
```

Does NOT remove the Docker image. Use `scripts/rl-env gc --prune-images` to reclaim unused image tags.

## Docker Compose

Uses `docker-compose.tester-env.yml` (overlay compose, does not shadow upstream `compose.yaml`).

Volumes:
- `solectrus_pg_data`
- `solectrus_redis_data`
- `solectrus_influx_data`

## Image Tag Policy

`IMAGE_TAG` env var is set by `scripts/rl-env` to a content-addressed tag. Manual invocations get `tester-env-solectrus:dev`. `RUN_ID` scopes containers/volumes only, not the image name.

## Parallel Runs

Pass `--run-id <id>` to isolate project name. Pass `--port <port>` for custom ports.

## Baseline

- Upstream tag: v1.2.1
- Baseline commit: 5105266ac738f290cbcbf98451841d803ad649e0
- Branch: tester-env-baseline