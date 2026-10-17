# PostgreSQL / Overview

Derived from the Prometheus PostgreSQL Exporter project's
[Postgres Overview mixin dashboard](https://github.com/prometheus-community/postgres_exporter/blob/v0.19.1/postgres_mixin/dashboards/postgres-overview.json),
pinned to exporter v0.19.1. Its Apache-2.0 license is included alongside the JSON.

Local adaptations:

- Namespace, job, instance and database selectors cover Rekon (`ai`) and dossier.
- PostgreSQL 18 checkpoint buffers use `pg_stat_checkpointer_buffers_written_total`;
  the removed backend buffer/fsync metrics are omitted. Both exporters enable
  the checkpointer collector.
- Health, scrape errors, uptime, database size, locks, dead tuples, transaction
  rollbacks and checkpoint rates complement the upstream activity/cache panels.
- Transaction throughput and connection counts are labelled accurately: they
  count transactions rather than SQL statements, and sessions in all states.

The `dashboards-postgres` ConfigMap carries the `grafana_dashboard` label. The
stack's existing dashboard sidecar copies it into its provisioned folder; no
manual Grafana import or extra data source is required. Queries use the dashboard's
Prometheus-compatible data source variable and need no recording rules or custom
SQL metrics.

Merge and publish [apkontainers!983](https://gitlab.sko.ai/doudous/apkontainers/-/merge_requests/983)
before deploying the infrastructure MR.
It supplies `ghcr.io/vaskozl/prometheus-postgres-exporter:0.19.1`. Both DB pods roll
when their sidecars are added. Exporters use the existing local database login
with sessions configured read-only, run as UID/GID 568, and do not mount the
Postgres data volume.

After rollout, check both `pg_up` series are 1 and
`pg_exporter_last_scrape_error` is 0. Open `PostgreSQL / Overview` in Grafana and
switch namespace/instance to compare the two databases. The application's handled
duplicate inserts can legitimately increase the rollback rate.
