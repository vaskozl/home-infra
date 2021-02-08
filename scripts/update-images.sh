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
    if ($image and $tag and $image !~ /(\.io)/){
      $image =~ s/["]//g;
      $tag =~ s/["]//g;
      my $tag_regex = quotemeta($tag);
      $tag_regex =~ s/\d+/\\d\+/g;
      sub rd { $_ = shift; s/[^\.\d]//g; $_ }
      my @tags;
      if ($image =~ s!r\.sko\.ai/!!) {
        @tags = @{g("https://r.sko.ai/v2/$image/tags/list")->json->{tags}};
      } else {
        $image = "library/$image" unless $image =~ m!/!;
        @tags = map { $_->{name} } @{g("https://hub.docker.com/v2/repositories/$image/tags/?page=1&page_size=1000")->json->{results}};
      }
      my @versions = sort { versioncmp(rd($a),rd($b)) } grep { /^$tag_regex$/ } @tags;
      if (@versions) {
        my $newest = pop @versions;
        if ($newest ne $tag) {
          $line =~ s/\Q$tag\E/$newest/g;
          print STDERR "new: $image:$tag -> $newest\n" ;
        } else { 
          print STDERR "latest: $image:$tag\n";
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
