#!/bin/bash

set -e
set -u

UNAME=$(uname)
ARCH=$(uname -m)

if [ "$UNAME" == "Linux" ] ; then
    if [ "$ARCH" != "i686" -a "$ARCH" != "x86_64" ] ; then
        echo "Unsupported architecture: $ARCH"
        echo "Meteor only supports i686 and x86_64 for now."
        exit 1
    fi
    MONGO_OS="linux"

    stripBinary() {
        strip --remove-section=.comment --remove-section=.note $1
    }
elif [ "$UNAME" == "Darwin" ] ; then
    SYSCTL_64BIT=$(sysctl -n hw.cpu64bit_capable 2>/dev/null || echo 0)
    if [ "$ARCH" == "i386" -a "1" != "$SYSCTL_64BIT" ] ; then
        # some older macos returns i386 but can run 64 bit binaries.
        # Probably should distribute binaries built on these machines,
        # but it should be OK for users to run.
        ARCH="x86_64"
    fi

    if [ "$ARCH" != "x86_64" ] ; then
        echo "Unsupported architecture: $ARCH"
        echo "Meteor only supports x86_64 for now."
        exit 1
    fi

    MONGO_OS="osx"

    # We don't strip on Mac because we don't know a safe command. (Can't strip
    # too much because we do need node to be able to load objects like
    # fibers.node.)
    stripBinary() {
        true
    }
else
    echo "This OS not yet supported"
    exit 1
fi

PLATFORM="${UNAME}_${ARCH}"

# save off meteor checkout dir as final target
cd `dirname $0`/..
TARGET_DIR=`pwd`

# Read the bundle version from the meteor shell script.
BUNDLE_VERSION=$(perl -ne 'print $1 if /BUNDLE_VERSION=(\S+)/' meteor)
if [ -z "$BUNDLE_VERSION" ]; then
    echo "BUNDLE_VERSION not found"
    exit 1
fi
echo "Building dev bundle $BUNDLE_VERSION"

DIR=`mktemp -d -t generate-dev-bundle-XXXXXXXX`
trap 'rm -rf "$DIR" >/dev/null 2>&1' 0

echo BUILDING IN "$DIR"

cd "$DIR"
chmod 755 .
umask 022
mkdir build
cd build

git clone git://github.com/joyent/node.git
cd node
# When upgrading node versions, also update the values of MIN_NODE_VERSION at
# the top of tools/meteor.js and tools/server/server.js.
git checkout v0.8.24

./configure --prefix="$DIR"
make -j4
make install PORTABLE=1
# PORTABLE=1 is a node hack to make npm look relative to itself instead
# of hard coding the PREFIX.

# export path so we use our new node for later builds
export PATH="$DIR/bin:$PATH"

which node

which npm

# When adding new node modules (or any software) to the dev bundle,
# remember to update LICENSE.txt! Also note that we include all the
# packages that these depend on, so watch out for new dependencies when
# you update version numbers.

cd "$DIR/lib/node_modules"
npm install connect@2.7.10
npm install optimist@0.3.5
npm install semver@1.1.0
npm install handlebars@1.0.7
npm install clean-css@0.8.3
npm install useragent@2.0.1
npm install request@2.12.0
npm install keypress@0.1.0
npm install http-proxy@0.10.1  # not 0.10.2, which contains a sketchy websocket change
npm install underscore@1.4.4
npm install fstream@0.1.21
npm install tar@0.1.14
npm install kexec@0.1.1
npm install shell-quote@0.0.1

# uglify-js has a bug which drops 'undefined' in arrays:
# https://github.com/mishoo/UglifyJS2/pull/97
npm install https://github.com/meteor/UglifyJS2/tarball/aa5abd14d3

# progress 0.1.0 has a regression where it opens stdin and thus does not
# allow the node process to exit cleanly. See
# https://github.com/visionmedia/node-progress/issues/19
npm install progress@0.0.5

# If you update the version of fibers in the dev bundle, also update the "npm
# install" command in docs/client/concepts.html and in the README in
# app/lib/bundler.js.
npm install fibers@1.0.0
# Fibers ships with compiled versions of its C code for a dozen platforms. This
# bloats our dev bundle, and confuses dpkg-buildpackage and rpmbuild into
# thinking that the packages need to depend on both 32- and 64-bit versions of
# libstd++. Remove all the ones other than our architecture. (Expression based
# on build.js in fibers source.)
FIBERS_ARCH=$(node -p -e 'process.platform + "-" + process.arch + "-v8-" + /[0-9]+\.[0-9]+/.exec(process.versions.v8)[0]')
cd fibers/bin
mv $FIBERS_ARCH ..
rm -rf *
mv ../$FIBERS_ARCH .
cd ../..

# Checkout and install mongodb.
# To see the mongo changelog, go to http://www.mongodb.org/downloads,
# click 'changelog' under the current version, then 'release notes' in
# the upper right.
cd "$DIR"
MONGO_VERSION="2.4.4"

mkdir -p mongodb/bin
git clone git://github.com/mongodb/mongo.git
cd mongo
git checkout r$MONGO_VERSION

# Compile
if [ "$MONGO_OS" == "osx" ]; then
    scons -j8 --ssl --cpppath /usr/local/Cellar/openssl/1.0.1e/include --libpath /usr/local/Cellar/openssl/1.0.1e/lib all
elif [ "$MONGO_OS" == "linux" ]; then
    scons --ssl --extrapath=/usr/local/opt/openssl all
fi

# Copy binaries
cp mongo ../mongodb/bin/
cp mongod ../mongodb/bin/

# Copy distribution information
find ./distsrc -maxdepth 1 -type f -exec cp '{}' ../mongodb \;
cd ..
rm -rf mongo

stripBinary bin/node
stripBinary mongodb/bin/mongo
stripBinary mongodb/bin/mongod

echo BUNDLING

cd "$DIR"
echo "${BUNDLE_VERSION}" > .bundle_version.txt
rm -rf build

tar czf "${TARGET_DIR}/dev_bundle_${PLATFORM}_${BUNDLE_VERSION}.tar.gz" .

echo DONE
