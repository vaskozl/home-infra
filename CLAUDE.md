# home-infra

- `cluster/gitlab/postgresql.yaml` runs `pgautoupgrade *-debian` on a
  glibc-collated data dir: close any bump to an `-alpine` tag (musl corrupts
  text indexes). A Debian release change needs `reindexdb --all` +
  `REFRESH COLLATION VERSION`.
