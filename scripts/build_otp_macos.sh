#!/bin/bash

set -euox pipefail

main() {
  if [ $# -ne 3 ]; then
    cat <<EOF
Usage:
    build_otp_macos.sh ref_name ref arch
EOF
    exit 1
  fi

  local ref_name=$1
  local ref=$2
  local arch=$3
  : "${OPENSSL_VERSION:=3.1.6}"
  : "${OPENSSL_DIR:=/tmp/builds/openssl-${OPENSSL_VERSION}-macos-${arch}}"
  : "${WXWIDGETS_VERSION:=3.2.5}"
  : "${WXWIDGETS_DIR:=/tmp/builds/wxwidgets-${WXWIDGETS_VERSION}-macos-${arch}}"
  : "${OTP_DIR:=/tmp/builds/otp-${ref_name}-${ref}-openssl-${OPENSSL_VERSION}-macos-${arch}}"
  export MAKEFLAGS=-j$(getconf _NPROCESSORS_ONLN)
  export CFLAGS="-Os -fno-common -mmacosx-version-min=11.0"

  case "${arch}" in
    amd64) ;;
    arm64) ;;
    *)
      echo "bad arch ${arch}"
      exit 1
  esac

  local cross_compile=yes
  if [[ `uname -m` == "arm64" && "$arch" == "arm64" ]]; then
    cross_compile=no
  fi
  if [[ `uname -m` == "x86_64" && "$arch" == "amd64" ]]; then
    cross_compile=no
  fi

  build_openssl "${OPENSSL_VERSION}" "${arch}"
  build_wxwidgets "${WXWIDGETS_VERSION}" "${arch}"

  export PATH="${WXWIDGETS_DIR}/bin:$PATH"
  build_otp "${ref_name}" "${arch}"
}

build_openssl() {
  local version=$1
  local arch=$2
  local rel_dir=${OPENSSL_DIR}
  local src_dir=/tmp/builds/src-openssl-${version}

  if [ -d "${rel_dir}/bin" ]; then
    echo "${rel_dir}/bin already exists, skipping build"
    ${rel_dir}/bin/openssl version
    return
  fi

  case "${arch}" in
    amd64) arch=x86_64 ;;
    arm64) ;;
  esac

  ref=openssl-${version}
  url=https://github.com/openssl/openssl

  if [ ! -d ${src_dir} ]; then
    git clone --depth 1 ${url} --branch ${ref} ${src_dir}
  fi

  (
    cd ${src_dir}
    git clean -dfx

    if [ "$cross_compile" = "yes" ]; then
      ./Configure "darwin64-${arch}-cc" --prefix=${rel_dir} ${CFLAGS}
    else
      ./config --prefix=${rel_dir} ${CFLAGS}
    fi

    make
    make install_sw
  )

  if ! ${rel_dir}/bin/openssl version; then
    rm -rf ${rel_dir}
  fi
}

build_wxwidgets() {
  local version=$1
  local arch=$2
  local rel_dir=${WXWIDGETS_DIR}
  local src_dir=/tmp/builds/src-wxwidgets-${version}

  if [ -d "${rel_dir}/bin" ]; then
    echo "${rel_dir}/bin already exists, skipping build"
    ${rel_dir}/bin/wx-config --version
    return
  fi

  if [ ! -d ${src_dir} ]; then
    curl --fail -LO https://github.com/wxWidgets/wxWidgets/releases/download/v$version/wxWidgets-$version.tar.bz2
    tar -xf wxWidgets-$version.tar.bz2
    mv wxWidgets-$version $src_dir
    rm wxWidgets-$version.tar.bz2
  fi

  (
    cd ${src_dir}
    ./configure \
      --disable-shared \
      --prefix=${rel_dir} \
      --with-cocoa \
      --with-macosx-version-min=11.0 \
      --disable-sys-libs
    make
    make install
  )

  if ! ${rel_dir}/bin/wx-config --version; then
    rm -rf ${rel_dir}
  fi
}

build_otp() {
  local ref_name=$1
  local arch=$2
  local rel_dir=${OTP_DIR}
  local src_dir=/tmp/builds/src-otp-${ref_name}
  local wx_test

  if [ "${cross_compile}" = "yes" ]; then
    wx_test=""
  else
    wx_test="wx:new(), io:format(\"wx ok~n\"),"
  fi

  local test_cmd="erl -noshell -eval 'io:format(\"~s~s~n\", [
    erlang:system_info(system_version),
    erlang:system_info(system_architecture)]),
    ok = crypto:start(), io:format(\"crypto ok~n\"),
    ${wx_test}
    halt().'"

  if [ -d "${rel_dir}/bin" ]; then
    echo "${rel_dir}/bin already exists, skipping build"
    eval ${rel_dir}/bin/${test_cmd}
    return
  fi

  url=https://github.com/erlang/otp

  if [ ! -d ${src_dir} ]; then
    git clone --depth 1 ${url} --branch ${ref_name} ${src_dir}
  fi

  (
    cd $src_dir
    git clean -dfx
    export ERL_TOP=$PWD
    export ERLC_USE_SERVER=true

    case "${arch}" in
      amd64) arch=x86_64 ;;
      arm64) ;;
    esac

    if [ "${cross_compile}" = "yes" ]; then
      xcrun="xcrun -sdk macosx"
      sysroot=`$xcrun --show-sdk-path`

      ./otp_build configure --enable-bootstrap-only

      erl_xcomp_sysroot=$sysroot \
      CC="$xcrun cc -arch $arch" \
      CFLAGS="$CFLAGS" \
      CXX="$xcrun c++ -arch $arch" \
      CXXFLAGS="$CFLAGS" \
      LD="$xcrun ld" \
      LDFLAGS="-lc++" \
      RANLIB="$xcrun ranlib" \
      ./otp_build configure \
        --build=`erts/autoconf/config.guess` \
        --host="$arch-apple-darwin" \
        --with-ssl=${OPENSSL_DIR} \
        --disable-dynamic-ssl-lib \
        --without-{javac,odbc,wx,observer,debugger,et}

      ./otp_build boot -a
      ./otp_build release -a ${rel_dir}
      cd ${rel_dir}
      ./Install -cross -sasl $PWD
    else
      ./otp_build configure \
        --with-ssl=${OPENSSL_DIR} \
        --disable-dynamic-ssl-lib \
        --without-{javac,odbc}

      ./otp_build boot -a
      ./otp_build release -a ${rel_dir}
      cd ${rel_dir}
      ./Install -sasl $PWD
    fi
  )

  if ! eval ${rel_dir}/bin/erl ${test_cmd}; then
    rm -rf ${rel_dir}
  fi
}

main $@
