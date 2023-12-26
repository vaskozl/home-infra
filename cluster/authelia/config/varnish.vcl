vcl 4.1;
backend default {
    .host = "authelia";
    .port = "8080";
}

sub vcl_hash {
  if (req.http.Cookie) {
    /* Include cookie in cache hash */
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
    set beresp.ttl = 1m;
    set beresp.grace = 10m;

    # This block will make sure that if the upstream returns a 5xx, but we have the response in the cache (even if it's expired),
    # we fall back to the cached value (until the grace period is over).
    if (beresp.status == 500 || beresp.status == 502 || beresp.status == 503 || beresp.status == 504)
    {
        # This check is important. If is_bgfetch is true, it means that we've found and returned the cached object to the client,
        # and triggered an asynchoronus background update. In that case, if it was a 5xx, we have to abandon, otherwise the previously cached object
        # would be erased from the cache (even if we set uncacheable to true).
        if (bereq.is_bgfetch)
        {
            return (abandon);
        }

        # We should never cache a 5xx response.
        set beresp.uncacheable = true;
    }
}
