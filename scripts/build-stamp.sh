#!/bin/zsh
# Prints the build stamp of the checkout holding this script, one key=value per line:
#   build=412               commits up to HEAD (CFBundleVersion)
#   commit=16e85ce          HEAD's short SHA, with -dirty when the checkout differs from it
#                           (changed, staged or untracked files that git does not ignore)
#   branch=main             the checked-out branch, empty on a detached HEAD
# Outside a git checkout it prints build=0, commit=unknown and an empty branch, so a build from a
# source archive still succeeds. The Xcode project's "Stamp the build" phase and soroband-cli's
# build.rs both run it.
set -uo pipefail

cd ${0:A:h:h}
# Reading the status takes no index lock, so it cannot collide with a git command running beside
# the build.
export GIT_OPTIONAL_LOCKS=0

if ! commit=$(git rev-parse --short HEAD 2>/dev/null); then
  print "build=0\ncommit=unknown\nbranch="
  exit 0
fi
[[ -z $(git status --porcelain) ]] || commit+=-dirty
print "build=$(git rev-list --count HEAD)"
print "commit=$commit"
print "branch=$(git symbolic-ref --short -q HEAD)"
