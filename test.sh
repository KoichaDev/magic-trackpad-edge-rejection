#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build --product EdgeModelChecks "$@"
binary_dir="$(swift build --show-bin-path "$@")"
"$binary_dir/EdgeModelChecks"
clang -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I Sources/MultitouchAdapter/include \
  Tests/RawContactFilterTests/main.c Sources/MultitouchAdapter/RawContactFilter.c \
  -o "$binary_dir/RawContactFilterChecks"
"$binary_dir/RawContactFilterChecks"
