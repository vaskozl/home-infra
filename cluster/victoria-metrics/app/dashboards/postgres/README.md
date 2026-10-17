# PostgreSQL / Overview

Adapted from the Prometheus PostgreSQL Exporter project's
[Postgres Overview mixin dashboard](https://github.com/prometheus-community/postgres_exporter/blob/v0.19.1/postgres_mixin/dashboards/postgres-overview.json),
originally released with exporter v0.19.1. The Apache-2.0 license copy is in
[`../THIRD_PARTY_LICENSES.md`](../THIRD_PARTY_LICENSES.md).

Local adaptations:

- Namespace, job, instance and database selectors cover Rekon (`ai`) and dossier.
- PostgreSQL 18 checkpoint buffers use `pg_stat_checkpointer_buffers_written_total`;
  the removed backend buffer/fsync metrics are omitted. Both exporters enable
  the checkpointer collector.
- Health, scrape errors, uptime, database size, locks, dead tuples, transaction
  rollbacks and checkpoint rates complement the upstream activity/cache panels.
- Transaction throughput and connection counts are labelled accurately: they
  count transactions rather than SQL statements, and sessions in all states.
- Top SQL tables use `pg_stat_statements` counters over the selected dashboard
  range. Query text is limited to 120 characters and the exporter collects at
  most 50 statements per database.

`pg_stat_statements` aggregates normalized SQL statistics since its last reset;
these panels do not retain individual executions, plans, or wait-event history.
For deeper Query Analytics, use a tool such as Percona PMM's
[QAN for PostgreSQL](https://docs.percona.com/percona-monitoring-and-management/3/use/qan/).

The `dashboards-postgres` ConfigMap carries the `grafana_dashboard` label. The
stack's existing dashboard sidecar copies it into its provisioned folder; no
manual Grafana import or extra data source is required. Queries use the dashboard's
Prometheus-compatible data source variable and need no recording rules or custom
SQL metrics.

Both DB pods enable the preloaded `pg_stat_statements` module and create its
extension in their application database. Exporters use the official
`ghcr.io/prometheus-community/postgres-exporter:v0.20.1` image, the existing
local database login with sessions configured read-only, run as UID/GID 568,
and do not mount the Postgres data volume. Query text is exported as a Prometheus
label, so access to these metrics also grants access to normalized SQL text.

After rollout, check both `pg_up` series are 1 and
`pg_exporter_last_scrape_error` is 0, then confirm that
`pg_stat_statements_seconds_total` is present after each database's first
extension setup. Open `PostgreSQL / Overview` in Grafana and switch
namespace/instance to compare the two databases. The application's handled
duplicate inserts can legitimately increase the rollback rate.
