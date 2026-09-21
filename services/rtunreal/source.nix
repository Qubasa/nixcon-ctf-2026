# The published challenge tree: the bytes players download *and* the bytes
# submissions are graded against, so the two can never drift.
#
# Two things are stripped:
#
#   .git       - the clone is served from gitea, the tarball is a convenience
#   solution/  - a scratch copy of the whole challenge that lives in the
#                challenge repo, and whose own .gitignore has
#                `#input-derivation.nix` commented out. Nothing is leaking
#                today, but the day the author commits their answer there it
#                would ship with the tarball. Stripped rather than trusted.
{ runCommand, src }:
runCommand "rtunreal-src" { } ''
  cp -r ${src} $out
  chmod -R u+w $out
  rm -rf $out/.git $out/solution
''
