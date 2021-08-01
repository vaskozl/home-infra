#!/usr/bin/env raku
use v6.d;

my regex video { (480|720|1080|2160)p|<[sS]><[0..9]>|x26<[45]> };
my regex show { :i S<[0..9]>|Season|Series }

class Movie is IO::Path {
  has Str $.movies_dir is rw;

  method tsort {
    unless $.movies_dir.IO.add($.basename).e {
      say "NEW (MOVIE): $.basename";
      $.movies_dir.IO.mkdir;
      '../../rarfs/'.IO.add($.basename).symlink(
        $.movies_dir.IO.add($.basename),
        absolute => False,
      )
    }
  }
};

class Show is IO::Path {
  has Str $.shows_dir is rw;

  method name {
    $.basename.subst(
     /:i <[\s\.]>?(S\d\d?|Season.?\d\d?).*$/,
     '', :i
    ).subst(/\(.*?\)/, '', :g
    ).subst(/<["']>/, '', :g
    ).subst(/<[\s+]>/, '.', :g
    ).subst(
     /<[\(\)-]>|<[\.\s]>+/,
     '.'
    ).subst(
      /(^\w|<[\.\s]>\w)/,
      {$0.uc}
    )
  }

  method tsort {
    my $sd = $.shows_dir.IO.add($.name);
    $sd.mkdir;

    unless $sd.add($.basename).e {
      say "NEW (SHOW): $.basename";
      '../../../rarfs/'.IO.add($.basename).symlink(
        $sd.add($.basename),
        absolute => False,
      )
    }
  }
};

#| Symlinks a raw torrents directory into sorted shows and movies
sub MAIN(
  Str :h(:$hdd_dir) = "/media-pv",
  Str :t(:$torrent_dir) = "$hdd_dir/torrents", #= Raw torrent directory
  Str :s(:$shows_dir)   = "$hdd_dir/linksr/shows", #= Where to symlink shows
  Str :m(:$movies_dir)  = "$hdd_dir/linksr/movies", #= Where to symlink movies
  Bool :v(:$verbose), #= Print more things to STDOUT
  Bool :n(:$dryrun) = False, #= Don't actually symlink anything
) {
  say "Reading from Torrents: $torrent_dir;" if $verbose;
  say "Will populate Shows: $torrent_dir;" if $verbose;
  say "Will populate movies: $torrent_dir" if $verbose;

  for $torrent_dir.IO.dir {
    if .path ~~ / <video> / {
      if .path ~~ / <show> / {
        my $show = Show.new(.path);
        $show.shows_dir = $shows_dir;
        $show.tsort;
      } else {
        my $movie = Movie.new(.path);
        $movie.movies_dir = $movies_dir;
        $movie.tsort;
      }
    } else {
      say "Ignoring: " ~ .path if $verbose;
    }
  }
}
