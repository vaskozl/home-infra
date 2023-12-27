vcl 4.1;
backend default {
    .host = "internal-kubernetes-ingress.haproxy.svc.cluster.local.";
    .port = "80";
    .proxy_header = 1;
}

/* Include cookie in cache hash */
sub vcl_hash {
  if (req.http.Cookie) {
    hash_data(req.http.Cookie);
  }
}

/* Default VCL code with Cookie removed */
sub vcl_recv {
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
    return (hash);
}

sub vcl_backend_response {
    set beresp.grace = 24h;
    # Set TTL base don response
    if (beresp.status == 200 || beresp.status == 206 || beresp.status == 301) {
        set beresp.ttl = 120m;
    } elsif (beresp.status == 302 || beresp.status == 303) {
        set beresp.ttl = 20m;
    } elsif (beresp.status == 404 || beresp.status == 410) {
        set beresp.ttl = 3m;
    }

    # Keep serving from cache on 500s
    if (beresp.status >= 500) {
      if (bereq.is_bgfetch) {
        return (abandon);
      }
      set beresp.uncacheable = true;
    }
}

# Tells haproxy to send the request stsraight to the backend next time
sub vcl_backend_fetch {
    # Let haproxy know
    set bereq.http.X-Varnished = "true";
}
