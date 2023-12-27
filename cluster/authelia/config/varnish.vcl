vcl 4.1;
backend default {
    .host = "authelia";
    .port = "8080";
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
    # Remove Set-Cookie header
    if (bereq.url ~ "^/api/verify") {
        unset beresp.http.set-cookie;
    }

    # Keep serving from cache on 500s
    set beresp.ttl = 10m;
    set beresp.grace = 60m;
    if (beresp.status >= 500) {
      if (bereq.is_bgfetch) {
        return (abandon);
      }
      set beresp.uncacheable = true;
    }
}
