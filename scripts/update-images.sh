grep -lRP 'image:' cluster | while read file; do \
  mv $file $file.bak
  perl -M'Sort::Versions' -Mojo -ne '
  our ($image, $tag);
  my $line = $_;
  if (/^\s+(image|repository):\s*(\S*?)($|:)(.*)/ and $2 or
      /^\s+(tag):\s*([\S]+)/) {
    if ($1 eq "tag") {
      $tag = $2; 
    } else {
      ($image, $tag) = ($2, $4) if $2;
    }
    if ($image and $tag and $image !~ /(\.io|\.ai)/){
      $image =~ s/["]//g;
      $tag =~ s/["]//g;
      my $tag_regex = quotemeta($tag);
      $tag_regex =~ s/\d+/\\d\+/g;
      $image = "library/$image" unless $image =~ m!/!;
      sub rd { $_ = shift; s/[^\.\d]//g; $_ }
      my @versions = sort { versioncmp(rd($a),rd($b)) } grep { /^$tag_regex$/ } map { $_->{name} } @{g("https://hub.docker.com/v2/repositories/$image/tags/?page=1&page_size=1000")->json->{results}};
      if (@versions) {
        my $newest = pop @versions;
        if ($newest ne $tag) {
          $line =~ s/\Q$tag\E/$newest/g;
          warn "$image:$tag -> $newest" ;
        } else { 
          warn "already newest $image:$tag";
        }
      } else {
        warn "Could not retrieve version for $image";
      }
    }
  }
  print $line;
' < $file.bak > $file;
  rm $file.bak;
done
