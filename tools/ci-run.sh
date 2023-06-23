#!/usr/bin/bash

set -x

GCC_VERSION=${GCC_VERSION:=9}
TEST_CFLAGS=
EXTRA_CFLAGS=
EXTRA_LDFLAGS=
SAVED_GITHUB_API_TOKEN="${GITHUB_API_TOKEN}"
unset GITHUB_API_TOKEN  # remove from env

# Set up compilers
if [ -z "${OS_NAME##ubuntu*}" ]; then
  echo "Installing requirements [apt]"
  sudo apt-add-repository -y "ppa:ubuntu-toolchain-r/test"
  sudo apt-get update -y -q
  sudo apt-get install -y -q ccache gcc-$GCC_VERSION "libxml2=2.9.13*" "libxml2-dev=2.9.13*" libxslt1.1 libxslt1-dev || exit 1
  sudo /usr/sbin/update-ccache-symlinks
  echo "/usr/lib/ccache" >> $GITHUB_PATH # export ccache to path

  sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-$GCC_VERSION 60

  export CC="gcc"
  export PATH="/usr/lib/ccache:$PATH"
  TEST_CFLAGS="-Og -g -fPIC"
  EXTRA_CFLAGS="-Wall -Wextra"

elif [ -z "${OS_NAME##macos*}" ]; then
  export CC="clang -Wno-deprecated-declarations"
  TEST_CFLAGS="-Og -g -fPIC -arch arm64 -arch x86_64"
  EXTRA_LDFLAGS="-arch arm64 -arch x86_64"
  EXTRA_CFLAGS="-Wall -Wextra -arch arm64 -arch x86_64"
fi

# Log versions in use
echo "===================="
echo "|VERSIONS INSTALLED|"
echo "===================="
python -c 'import sys; print("Python %s" % (sys.version,))'
if [[ "$CC" ]]; then
  which ${CC%% *}
  ${CC%% *} --version
fi
if [ -z "${OS_NAME##win*}" ]; then
    pkg-config --modversion libxml-2.0 libxslt
fi
echo "===================="

ccache -s || true

set -eo pipefail

# Install python requirements
echo "Installing requirements [python]"

REQUIREMENTS_COMMON_DIR="tools/ci-deps"
case "$PYTHON_VERSION" in
  *2.7)
    REQUIREMENTS_VERSION_DIR="tools/ci-deps-eol"
    REQUIREMENTS_VERSION_SUFFIX="-py2"
  ;;
  3.6)
    REQUIREMENTS_VERSION_DIR="tools/ci-deps-eol"
    REQUIREMENTS_VERSION_SUFFIX="-py36"
  ;;
  *)
    REQUIREMENTS_VERSION_DIR="tools/ci-deps"
    REQUIREMENTS_VERSION_SUFFIX="-py3"
  ;;
esac

python -m pip install -U -r ${REQUIREMENTS_VERSION_DIR}/requirements-infra${REQUIREMENTS_VERSION_SUFFIX}.txt --require-hashes
python -m pip install -U -r ${REQUIREMENTS_VERSION_DIR}/requirements-wheel${REQUIREMENTS_VERSION_SUFFIX}.txt --require-hashes
if [ -z "${PYTHON_VERSION##*-dev}" ];
  then CYTHON_COMPILE_MINIMAL=true python -m pip install -r ${REQUIREMENTS_COMMON_DIR}/requirements-cython3.txt --no-binary :all: --require-hashes 
  else python -m pip install -r ${REQUIREMENTS_COMMON_DIR}/requirements-cython.txt --require-hashes
fi
python -m pip install -U -r ${REQUIREMENTS_VERSION_DIR}/requirements${REQUIREMENTS_VERSION_SUFFIX}.txt --require-hashes || exit 1
[ -n "${EXTRA_DEPS}" ] && python -m pip install -U -r ${REQUIREMENTS_COMMON_DIR}/requirements-docs.txt --require-hashes --no-deps
if [[ "$COVERAGE" == "true" ]]; then
  python -m pip install -r ${REQUIREMENTS_COMMON_DIR}/requirements-coverage.txt --require-hashes || exit 1
fi

# Build
GITHUB_API_TOKEN="${SAVED_GITHUB_API_TOKEN}" \
      CFLAGS="$CFLAGS $TEST_CFLAGS $EXTRA_CFLAGS" \
      LDFLAGS="$LDFLAGS $EXTRA_LDFLAGS" \
      python -u setup.py build_ext --inplace \
      $(if [ -n "${PYTHON_VERSION##2.*}" ]; then echo -n " -j7 "; fi ) \
      $(if [[ "$COVERAGE" == "true" ]]; then echo -n " --with-coverage"; fi ) \
      || exit 1

ccache -s || true

# Run tests
echo "Running the tests ..."
GITHUB_API_TOKEN="${SAVED_GITHUB_API_TOKEN}" \
      CFLAGS="$TEST_CFLAGS $EXTRA_CFLAGS" \
      LDFLAGS="$LDFLAGS $EXTRA_LDFLAGS" \
      PYTHONUNBUFFERED=x \
      make test || exit 1

if [[ "$COVERAGE" != "true" ]]; then
  echo "Building a clean wheel ..."
  GITHUB_API_TOKEN="${SAVED_GITHUB_API_TOKEN}" \
        CFLAGS="$EXTRA_CFLAGS -O3 -g1 -mtune=generic -fPIC -flto" \
        LDFLAGS="-flto $EXTRA_LDFLAGS" \
        make clean wheel || exit 1
fi

ccache -s || true
