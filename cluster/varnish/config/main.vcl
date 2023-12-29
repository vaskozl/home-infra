vcl 4.1;

backend default {
    .host = "internal-kubernetes-ingress.haproxy.svc.cluster.local.";
    .port = "80";
}

backend external {
    .host = "external-kubernetes-ingress.haproxy.svc.cluster.local.";
    .port = "80";
}

include "/config/hit-miss.vcl";

/* Include cookie in cache hash */
sub vcl_hash {
  # Include the Remote-User header in the hash if present
  if (req.http.Remote-User) {
    hash_data(req.http.Remote-User);
  }
}

/* Default VCL code with Cookie removed */
sub vcl_recv {
    if (req.http.X-Ingress-Class == "haproxy-external") {
        set req.backend_hint = external;
    }

    if (req.method == "PRI") {
        /* This will never happen in properly formed traffic (see: RFC7540) */
        return (synth(405));
    }
    if (!req.http.host &&
      req.esi_level == 0 &&
      req.proto ~ "^(?i)HTTP/1.1") {
        /* In HTTP/1.1, Host is required. */
        return (synth(400));
    }
    if (req.method != "GET" &&
      req.method != "HEAD" &&
      req.method != "PUT" &&
      req.method != "POST" &&
      req.method != "TRACE" &&
      req.method != "OPTIONS" &&
      req.method != "DELETE" &&
      req.method != "PATCH") {
        /* Non-RFC2616 or CONNECT which is weird. */
        return (pipe);
    }

    if (req.method != "GET" && req.method != "HEAD") {
        /* We only deal with GET and HEAD by default */
        return (pass);
    }
    if (req.http.Authorization) {
        /* Not cacheable by default */
        return (pass);
    }

    // We include Remote-User in the hash so we can cache
    if (req.http.Cookie && !req.http.Remote-User) {
        return (pass);
    }

    return (hash);
}

sub vcl_backend_response {
    set beresp.grace = 30m;
    # Keep serving from cache on 500s
    if (beresp.status >= 500 && bereq.is_bgfetch) {
          return (abandon);
    }
}

sub vcl_deliver {
  set resp.http.x-unique-id = req.http.x-unique-id;
}
