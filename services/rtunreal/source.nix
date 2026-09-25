#     commented out. Nothing is leaking today, but the day the author commits
{ runCommand, src }:
runCommand "rtunreal-src" { } ''
  cp -r ${src} $out
  chmod -R u+w $out
  rm -rf $out/.git $out/solution
''
