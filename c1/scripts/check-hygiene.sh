#!/usr/bin/env bash
# Higiene de la rama research/c1 (D-47 del paper):
#   1. nada cambia fuera de c1/ respecto de research/paper@92c4a69 (ni en el índice, ni en el árbol, ni sin seguimiento);
#   2. src/OneTimeSignerAccount.sol conserva su sha256 de referencia (OTS de C0 y del TFM);
#   3. la rama actual es research/c1.
# Uso (desde cualquier sitio):  bash ots/c1/scripts/check-hygiene.sh      Sale con 1 si algo falla.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1          # raíz de ots/
BASE=${BASE:-92c4a69e20ac2884a93b94fd8348aa1832a67351}
SRC_SHA=802db87fec5c3c8141302d43d1d2be5f70dd55de0de37329e4a915b10ff2dbeb
G="git --no-optional-locks"
fail=0

branch=$($G rev-parse --abbrev-ref HEAD)
[ "$branch" = "research/c1" ] && echo "OK   rama: $branch" || { echo "FALLO rama: $branch (se esperaba research/c1)"; fail=1; }

$G merge-base --is-ancestor "$BASE" HEAD && echo "OK   ${BASE:0:8} es ancestro de HEAD" || { echo "FALLO ${BASE:0:8} no es ancestro de HEAD"; fail=1; }

outside=$( { $G diff --name-only "$BASE" -- . ':(exclude)c1';
             $G diff --name-only --cached -- . ':(exclude)c1';
             $G ls-files --others --exclude-standard -- . ':(exclude)c1'; } | sort -u )
if [ -z "$outside" ]; then echo "OK   nada cambia fuera de c1/ respecto de ${BASE:0:8}"; else
  echo "FALLO cambios fuera de c1/:"; echo "$outside" | sed 's/^/       /'; fail=1; fi

if command -v sha256sum >/dev/null; then got=$(sha256sum src/OneTimeSignerAccount.sol | cut -d' ' -f1);
else got=$(shasum -a 256 src/OneTimeSignerAccount.sol | cut -d' ' -f1); fi
[ "$got" = "$SRC_SHA" ] && echo "OK   sha256 de src/OneTimeSignerAccount.sol = ${SRC_SHA:0:8}…" || { echo "FALLO sha256 de src/: $got"; fail=1; }

echo "--- cambios dentro de c1/ respecto de ${BASE:0:8}:"
{ $G diff --stat "$BASE" -- c1; $G ls-files --others --exclude-standard -- c1 | sed 's/^/  (sin seguimiento) /'; } | tail -20
exit $fail
