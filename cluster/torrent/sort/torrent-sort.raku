#!/usr/bin/env raku
use v6.d;

my regex video { :i (480|720|1080|2160)p|<[sS]><[0..9]>|x26<[45]>|Movie };
my regex show { :i S<[0..9]>|Season|Series }

class Movie is IO::Path {
  has Str $.movies_dir is rw;

  method tsort {
    unless $.movies_dir.IO.add($.basename).l {
      say "NEW (MOVIE): $.basename";
      $.movies_dir.IO.mkdir;
      '../../torrents/'.IO.add($.basename).symlink(
        $.movies_dir.IO.add($.basename),
        absolute => False,
      )
    }
    CATCH { when X::IO::DoesNotExist { $*ERR.say: "some kind of IO exception was caught!" } };
  }
};

class Show is IO::Path {
  has Str $.shows_dir is rw;

  method name {
    $.basename.subst(
     /:i <[\s\.]>?(S\d\d?|Season.?\d\d?).*$/, # Remove everything past the season
     '', :gi
    ).subst(/\(.*?\)/, '', :g #               # Remove everything in (parens)
    ).subst(/<["']>/, '', :g                  # Remove quotes
    ).subst(/<[\s+]>/, '.', :g                # Replace whitespace with dots
    ).subst(
     /<[\(\)-]>|<[\.\s]>+/,                   # Replace space and parens with dots
     '.', :g
    ).subst(
      /(^\w|<[\.\s]>\w)/,                     # Capitalize words after dots
      {$0.uc}, :g
    )
  }

  method tsort {
    my $sd = $.shows_dir.IO.add($.name);
    $sd.mkdir;

    unless $sd.add($.basename).l {
      say "NEW (SHOW): $.basename";
      '../../../torrents/'.IO.add($.basename).symlink(
        $sd.add($.basename),
        absolute => False,
      )
    }
    CATCH { when X::IO::DoesNotExist { $*ERR.say: "some kind of IO exception was caught!" } };
  }
};

#| Symlinks a raw torrents directory into sorted shows and movies
sub MAIN(
  Str :h(:$hdd_dir) = "/media-pv",
  Str :t(:$torrent_dir) = "$hdd_dir/torrents", #= Raw torrent directory
  Str :s(:$shows_dir)   = "$hdd_dir/links/shows", #= Where to symlink shows
  Str :m(:$movies_dir)  = "$hdd_dir/links/movies", #= Where to symlink movies
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
