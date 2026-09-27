#!/usr/bin/env bash

# Smooth cyan -> blue gradient
TOP_R=99
TOP_G=231
TOP_B=229

BOT_R=25
BOT_G=188
BOT_B=235

art=(
'    ....                ....    '
'    .......          .......    '
'    ..  .....       ....  $;.   '
'    ..   .x;........:+:   ..    '
'    ... ..xxxxxxxxxxx+.. ...    '
'    .....xxxxxxxxxxxxxx:.::.    '
'     .xxxx...;xxxxX...xxxx:     '
'    ..xxxx.  ;+xxxX  .xxxx:.    '
'  ...:::::...&+xxx$...:::.....  '
'   ......$$&.:;xx+;.$&X......   '
'         ...:x:;;:x;...         '
'       .    +&&+x&&+    .       '
'     ..   ...:.  +....   ..     '
'    ...  .;x++:;+Xxxx+.. ....   '
'  ..X.  .+xxxxxxxx+x+xx.  .x..  '
' ..xx. ..xxxxxxxxxxxxxx.. ..X.. '
'..$$+. .xxxxxxxxxxxxxxxx.  .$$..'
'.$$:.. .xxxxxxxxxxxxxxxx.  ..$&.'
'.$..   .XxxxxxxxxxxxxX$X.    .x.'
'..     ..$XxxXxXXXXxxxX..     ..'
'        ...:XxXXxxxx+...        '
'           ..;;$$x$x:           '
'       ...... .... ......       '
)

# Lines belonging to the white fox muzzle.
# Start/end columns are inclusive.
muzzle_start=(
  [8]=5
  [9]=4
  [10]=9
)

muzzle_end=(
  [8]=28
  [9]=29
  [10]=23
)

rows=${#art[@]}

for ((i=0; i<rows; i++)); do
    # Smoothly interpolate RGB from top to bottom.
    r=$(( TOP_R + (BOT_R-TOP_R)*i/(rows-1) ))
    g=$(( TOP_G + (BOT_G-TOP_G)*i/(rows-1) ))
    b=$(( TOP_B + (BOT_B-TOP_B)*i/(rows-1) ))

    line="${art[$i]}"

    if [[ -v "muzzle_start[$i]" ]]; then
        start=${muzzle_start[$i]}
        end=${muzzle_end[$i]}

        before="${line:0:start}"
        white="${line:start:end-start+1}"
        after="${line:end+1}"

        # Fox color
        printf '\e[38;2;%d;%d;%dm%s' "$r" "$g" "$b" "$before"

        # Soft white/light-cyan muzzle
        printf '\e[38;2;225;250;250m%s' "$white"

        # Back to fox gradient
        printf '\e[38;2;%d;%d;%dm%s\e[0m\n' \
            "$r" "$g" "$b" "$after"
    else
        printf '\e[38;2;%d;%d;%dm%s\e[0m\n' \
            "$r" "$g" "$b" "$line"
    fi
done
