#!/bin/bash

mkdir -p lib/ocaml
cp $OPAM_SWITCH_PREFIX/lib/ocaml/*.cmi lib/ocaml/
mkdir -p lib/astring
cp $OPAM_SWITCH_PREFIX/lib/astring/META lib/astring
cp $OPAM_SWITCH_PREFIX/lib/astring/*.cmi lib/astring

js_of_ocaml $OPAM_SWITCH_PREFIX/lib/astring/astring.cma -o lib/astring/astring.cma.js --effects=cps

cat > lib/ocaml/dynamic_cmis.json << EOF
{
  dcs_url: "/lib/ocaml/",
  dcs_toplevel_modules: ["CamlinternalOO","Stdlib","CamlinternalFormat","Std_exit","CamlinternalMod","CamlinternalFormatBasics","CamlinternalLazy"],
  dcs_file_prefixes : ["stdlib__"]
}
EOF

cat > lib/astring/dynamic_cmis.json << EOF
{
  dcs_url: "/lib/astring/",
  dcs_toplevel_modules: ["Astring"],
  dcs_file_prefixes : []
}
EOF

