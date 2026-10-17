# PostgreSQL / Overview

This dashboard is authored for the Rekon and Veroso databases. It combines
PostgreSQL health and workload metrics with rankings from `pg_stat_statements`:

- Availability, exporter errors, database size, uptime and transaction rate.
- Rows fetched, buffer activity, cache hit ratio, connections, locks, deadlocks,
  dead tuples, rollbacks and checkpoints.
- Queries ranked by execution time, average execution time and call volume over
  the selected dashboard range.

Both database containers preload `pg_stat_statements`. After the updated pods
have rolled out, check whether each database has the extension installed:

```sh
kubectl exec -n ai rekon-postgres-0 -c app -- psql -X -U postgres -d rekon -c "SELECT current_setting('shared_preload_libraries') AS preload, EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') AS installed;"
kubectl exec -n dossier dossier-postgres-0 -c app -- psql -X -U postgres -d veroso -c "SELECT current_setting('shared_preload_libraries') AS preload, EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') AS installed;"
```

If `installed` is `f`, create the extension once in that database:

```sh
kubectl exec -n ai rekon-postgres-0 -c app -- psql -X -v ON_ERROR_STOP=1 -U postgres -d rekon -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
kubectl exec -n dossier dossier-postgres-0 -c app -- psql -X -v ON_ERROR_STOP=1 -U postgres -d veroso -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
```

The panels show aggregate normalized SQL statistics, not individual executions,
query plans or wait-event history. The exporter returns at most 50 statements
per database and includes up to 120 characters of query text in a Prometheus
label. Limit access to these metrics accordingly.

The dashboard is provisioned from the `dashboards-postgres` ConfigMap by the
Grafana dashboard sidecar. No manual import or additional data source is needed.
