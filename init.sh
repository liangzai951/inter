#!/bin/bash

SRCDIR=$(dirname "${BASH_SOURCE[0]}")
BUILD_DIR=$SRCDIR/build

if [[ "${BUILD_DIR:0:2}" == "./" ]]; then
  BUILD_DIR=${BUILD_DIR:2}
fi

DIST_DIR=$BUILD_DIR/dist
BUILD_TMP_DIR=$BUILD_DIR/tmp
VENV_DIR=$BUILD_DIR/venv

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # sourced
  if [[ -z $VIRTUAL_ENV ]] && [[ ! -f "$VENV_DIR/bin/activate" ]]; then
    echo "Project not configured." >&2
    echo "Execute this script instead of sourcing it to perform setup." >&2
  else
    source "$VENV_DIR/bin/activate"
    pushd "$SRCDIR" >/dev/null
    SRCDIR_ABS=$(pwd)
    popd >/dev/null
    export PYTHONPATH=$SRCDIR_ABS/misc/pylib
  fi
else
  # Subshell
  set -e
  cd "$SRCDIR"

  # ————————————————————————————————————————————————————————————————————————————————————————————————
  # virtualenv

  mkdir -p "$VENV_DIR"

  pushd "$(dirname "$VENV_DIR")" >/dev/null
  VENV_DIR_ABS=$(pwd)/$(basename "$VENV_DIR")
  popd >/dev/null

  # must check and set VENV_ACTIVE before polluting local env
  VENV_ACTIVE=false
  if [[ "$VIRTUAL_ENV" == "$VENV_DIR_ABS" ]] && [[ "$1" != "-force" ]]; then
    VENV_ACTIVE=true
  fi

  if ! (which virtualenv >/dev/null); then
    echo "$0: Can't find virtualenv in PATH -- install through 'pip install --user virtualenv'" >&2
    exit 1
  fi

  if [[ ! -d "$VENV_DIR/bin" ]]; then
    echo "Setting up virtualenv in '$VENV_DIR'"
    virtualenv "$VENV_DIR"
  else
    if [[ ! -z $VIRTUAL_ENV ]] && [[ "$VIRTUAL_ENV" != "$VENV_DIR_ABS" ]]; then
      echo "Looks like the repository has moved location -- updating virtualenv"
      virtualenv "$VENV_DIR"
    fi
  fi

  source "$VENV_DIR/bin/activate"

  UPDATE_TIMESTAMP_FILE="$VENV_DIR/last-pip-run.mark"
  REQUIREMENTS_FILE=$SRCDIR/requirements.txt

  if [ "$REQUIREMENTS_FILE" -nt "$UPDATE_TIMESTAMP_FILE" ]; then
    echo "pip install -r $REQUIREMENTS_FILE"
    pip install -r "$REQUIREMENTS_FILE"
    date '+%s' > "$UPDATE_TIMESTAMP_FILE"
  fi

  # ————————————————————————————————————————————————————————————————————————————————————————————————
  # deps
  DEPS_DIR=$BUILD_DIR/deps
  PATCH_DIR=$(pwd)/misc/patches
  mkdir -p "$DEPS_DIR"

  check_dep() {
    NAME=$1
    REPO_URL=$2
    BRANCH=$3
    TREE_REF=$4
    set -e
    REPODIR=$DEPS_DIR/$NAME
    if [[ ! -d "$REPODIR/.git" ]]; then
      rm -rf "$REPODIR"
      echo "Fetching $NAME from $REPO_URL"
      if ! (git clone --recursive --single-branch -b $BRANCH -- "$REPO_URL" "$REPODIR"); then
        exit 1
      fi
      if [[ ! -z $TREE_REF ]]; then
        git -C "$REPODIR" checkout "$TREE_REF"
        git -C "$REPODIR" submodule update
      fi
      return 1
    fi
    # TODO: check that source matches tree ref
    return 0
  }

  if ! (check_dep \
    woff2 https://github.com/google/woff2.git master 36e6555b92a1519c927ebd43b79621810bf17c1a )
  then
    echo "Building woff2"
    git -C "$DEPS_DIR/woff2" apply "$PATCH_DIR/woff2.patch"
    if !(make -C "$DEPS_DIR/woff2" -j8 clean all); then
      rm -rf "$DEPS_DIR/woff2"
      exit 1
    fi
  fi
  if [[ ! -f "$VENV_DIR/bin/woff2_compress" ]]; then
    ln -vfs ../../deps/woff2/woff2_compress "$VENV_DIR/bin"
  fi

  # EOT is disabled
  # if ! (check_dep \
  #   ttf2eot https://github.com/rsms/ttf2eot.git master )
  # then
  #   echo "Building ttf2eot"
  #   make -C "$DEPS_DIR/ttf2eot" clean all
  # fi
  # if [[ ! -f "$VENV_DIR/bin/ttf2eot" ]]; then
  #   ln -vfs ../../deps/ttf2eot/ttf2eot "$VENV_DIR/bin"
  # fi

  if [[ ! -f "$DEPS_DIR/ttfautohint" ]]; then
    URL=https://download.savannah.gnu.org/releases/freetype/ttfautohint-1.6-tty-osx.tar.gz
    echo "Fetching $URL"
    curl '-#' -o "$DEPS_DIR/ttfautohint.tar.gz" -L "$URL"
    tar -C "$DEPS_DIR" -xzf "$DEPS_DIR/ttfautohint.tar.gz"
    rm "$DEPS_DIR/ttfautohint.tar.gz"
  fi
  if [[ ! -f "$VENV_DIR/bin/ttfautohint" ]]; then
    ln -vfs ../../deps/ttfautohint "$VENV_DIR/bin"
  fi

  if [[ ! -f "$VENV_DIR/bin/ttf2woff" ]] || [[ ! -f "$SRCDIR/misc/ttf2woff/ttf2woff" ]]; then
    echo "Building ttf2woff"
    make -C "$SRCDIR/misc/ttf2woff" -j8
  fi
  if [[ ! -f "$VENV_DIR/bin/ttf2woff" ]]; then
    ln -vfs ../../../misc/ttf2woff/ttf2woff "$VENV_DIR/bin"
  fi

  # ————————————————————————————————————————————————————————————————————————————————————————————————
  # $BUILD_TMP_DIR
  # create and mount spare disk image needed on macOS to support case-sensitive filenames
  if [[ "$(uname)" = *Darwin* ]]; then
    bash misc/mac-tmp-disk-mount.sh
  else
    mkdir -p "$BUILD_TMP_DIR"
  fi

  # ————————————————————————————————————————————————————————————————————————————————————————————————
  # $BUILD_DIR/etc/generated.make
  master_styles=( \
    Regular \
    Bold \
  )
  derived_styles=( \
    "RegularItalic : Regular" \
    "Medium        : Regular Bold" \
    "MediumItalic  : Regular Bold" \
    "BoldItalic    : Bold" \
    # "Black         : Regular Bold" \
    # "BlackItalic   : Regular Bold" \
  )
  web_formats=( woff woff2 )  # Disabled/unused: eot

  mkdir -p "$BUILD_DIR/etc"
  GEN_MAKE_FILE=$BUILD_DIR/etc/generated.make

  # Only generate if there are changes to the font sources
  NEED_GENERATE=false
  if [[ ! -f "$GEN_MAKE_FILE" ]] || [[ "$0" -nt "$GEN_MAKE_FILE" ]]; then
    NEED_GENERATE=true
  else
    for style in "${master_styles[@]}"; do
      if $NEED_GENERATE; then
        break
      fi
      for srcfile in $(find src/Interface-${style}.ufo -type f -newer "$GEN_MAKE_FILE"); do
        NEED_GENERATE=true
        break
      done
    done
  fi

  if $NEED_GENERATE; then
    echo "Generating '$GEN_MAKE_FILE'"
    echo "# Generated by init.sh -- do not modify manually" > "$GEN_MAKE_FILE"

    all_styles=()

    for style in "${master_styles[@]}"; do
      all_styles+=( $style )
      echo "${style}_ufo_d := " \
        "\$(wildcard src/Interface-${style}.ufo/* src/Interface-${style}.ufo/*/*)" >> "$GEN_MAKE_FILE"
      echo "$BUILD_TMP_DIR/InterfaceTTF/Interface-${style}.ttf: \$(${style}_ufo_d)" >> "$GEN_MAKE_FILE"
      echo "$BUILD_TMP_DIR/InterfaceOTF/Interface-${style}.otf: \$(${style}_ufo_d)" >> "$GEN_MAKE_FILE"
    done

    for e in "${derived_styles[@]}"; do
      style=$(echo "${e%%:*}" | xargs)
      dependent_styles=$(echo "${e#*:}" | xargs)
      all_styles+=( $style )

      echo -n "$BUILD_TMP_DIR/InterfaceTTF/Interface-${style}.ttf:" >> "$GEN_MAKE_FILE"
      for depstyle in $dependent_styles; do
        echo -n " \$(${depstyle}_ufo_d)" >> "$GEN_MAKE_FILE"
      done
      echo "" >> "$GEN_MAKE_FILE"

      echo -n "$BUILD_TMP_DIR/InterfaceOTF/Interface-${style}.otf:" >> "$GEN_MAKE_FILE"
      for depstyle in $dependent_styles; do
        echo -n " \$(${depstyle}_ufo_d)" >> "$GEN_MAKE_FILE"
      done
      echo "" >> "$GEN_MAKE_FILE"
    done

    # STYLE and STYLE_ttf targets
    for style in "${all_styles[@]}"; do
      echo "${style}_ttf: $DIST_DIR/Interface-${style}.ttf" >> "$GEN_MAKE_FILE"
      echo "${style}_otf: $DIST_DIR-unhinted/Interface-${style}.otf" >> "$GEN_MAKE_FILE"
      echo "${style}_ttf_unhinted: $DIST_DIR-unhinted/Interface-${style}.ttf" >> "$GEN_MAKE_FILE"

      echo -n "${style}: ${style}_otf" >> "$GEN_MAKE_FILE"
      for format in "${web_formats[@]}"; do
        echo -n " $DIST_DIR/Interface-${style}.${format}" >> "$GEN_MAKE_FILE"
      done
      echo "" >> "$GEN_MAKE_FILE"

      echo -n "${style}_unhinted: ${style}_otf" >> "$GEN_MAKE_FILE"
      for format in "${web_formats[@]}"; do
        echo -n " $DIST_DIR-unhinted/Interface-${style}.${format}" >> "$GEN_MAKE_FILE"
      done
      echo "" >> "$GEN_MAKE_FILE"
    done

    # all_otf target
    echo -n "all_otf:" >> "$GEN_MAKE_FILE"
    for style in "${all_styles[@]}"; do
      echo -n " ${style}_otf" >> "$GEN_MAKE_FILE"
    done
    echo "" >> "$GEN_MAKE_FILE"

    # all_ttf target
    echo -n "all_ttf:" >> "$GEN_MAKE_FILE"
    for style in "${all_styles[@]}"; do
      echo -n " ${style}_ttf" >> "$GEN_MAKE_FILE"
    done
    echo "" >> "$GEN_MAKE_FILE"

    echo -n "all_ttf_unhinted:" >> "$GEN_MAKE_FILE"
    for style in "${all_styles[@]}"; do
      echo -n " ${style}_ttf_unhinted" >> "$GEN_MAKE_FILE"
    done
    echo "" >> "$GEN_MAKE_FILE"

    # all_web target
    echo -n "all_web:" >> "$GEN_MAKE_FILE"
    for style in "${all_styles[@]}"; do
      echo -n " ${style}" >> "$GEN_MAKE_FILE"
    done
    echo "" >> "$GEN_MAKE_FILE"

    echo -n "all_web_unhinted:" >> "$GEN_MAKE_FILE"
    for style in "${all_styles[@]}"; do
      echo -n " ${style}_unhinted" >> "$GEN_MAKE_FILE"
    done
    echo "" >> "$GEN_MAKE_FILE"
    

    echo -n ".PHONY: all_ttf all_ttf_unhinted all_web all_web_unhinted all_otf" >> "$GEN_MAKE_FILE"
    for style in "${all_styles[@]}"; do
      echo -n " ${style} ${style}_ttf ${style}_ttf_unhinted ${style}_otf" >> "$GEN_MAKE_FILE"
    done
    echo "" >> "$GEN_MAKE_FILE"
  fi

  # ————————————————————————————————————————————————————————————————————————————————————————————————
  # summary
  if ! $VENV_ACTIVE; then
    echo "You now need to activate virtualenv by:"
    echo "  source '$0'"
    echo "Or directly by sourcing the activate script:"
    echo "  source '$VENV_DIR/bin/activate'"
  fi
fi
