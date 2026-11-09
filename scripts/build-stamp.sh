#!/bin/zsh
# Prints the build stamp of the checkout holding this script, one key=value per line:
#   build=412               commits up to HEAD (CFBundleVersion); 0 in a shallow clone, which
#                           does not hold them all
#   commit=16e85ce          HEAD's short SHA, with -dirty when the checkout differs from it
#                           (changed, staged or untracked files that git does not ignore)
#   branch=main             the checked-out branch, empty on a detached HEAD
# Outside a git checkout of this project (a source archive, even one inside another checkout) it
# prints build=0, commit=unknown and an empty branch, so the build still succeeds. The Xcode
# project's "Stamp the build" phase and soroband-cli's build.rs both run it.
set -uo pipefail

root=${0:A:h:h}
cd $root
# Reading the status takes no index lock, so it cannot collide with a git command running beside
# the build.
export GIT_OPTIONAL_LOCKS=0

top=$(git rev-parse --show-toplevel 2>/dev/null) || top=
if [[ -z $top || ${top:A} != $root ]] || ! commit=$(git rev-parse --short HEAD 2>/dev/null); then
  print "build=0\ncommit=unknown\nbranch="
  exit 0
fi
[[ -z $(git status --porcelain) ]] || commit+=-dirty
if [[ $(git rev-parse --is-shallow-repository) == true ]]; then
  print "build=0"
else
  print "build=$(git rev-list --count HEAD)"
fi
print "commit=$commit"
print "branch=$(git symbolic-ref --short -q HEAD)"
