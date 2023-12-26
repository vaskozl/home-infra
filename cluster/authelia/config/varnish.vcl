# Default backend definition. Set this to point to your content server.
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
