#!/usr/bin/env bash

art=$(cat <<'EOF'
         .....                                   ....         
        ..:;x....                            ....+;;..        
        .;....++&;.                        ...;;....;.        
        .x.   ..;x;..                    ...+;...  .;..       
        .+.    ...+xx..                ...x;;..    ..x.       
       ..+.      ..+;;..  ..........  ..+;;;..     ..+.       
        .+.       ..++xx$$$x+++;;+;;...;++..       .;:.       
        .;.        .xx;+++;+;;;;;+++++xxxx;        .x..       
        .;..     ...;xxx++xxxxxxxx++xxxx++...     $.:.        
        ..+..  ...;;xxxxxxxxxxxxxxxxxxxxxx+;...   .;..        
         .;;. ..;x+xxxxxxxxxxxxxxxxxxxxxxxxx+;..x;:;.         
          .+;;;+xxxxxxxxx+++++xxxxx++xxxxx++xxx;::;..         
          .;xxxx++xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.          
         ..xxxxxxx;:.....;xxxxx++xxxx......+x+xxxxx..         
         .;xxxxxxxx&    ...:xxxxxx+...    ;x+xxxxxx;..        
       ..;xxxxxxxx+;...   &.xxxx+x..    ...xxxxxxxxx+..       
     ...;x;;......:++;.... .xxxxxx.  ...$x;:.....:;:;;...     
      ...:x$&&&&&&&;..;+x.:x+xxxxx. ..x;;:x$&&&&&$&XX;...     
       ....;xxx+xxX&&&&.;;;xxxxXxx...+;:&&&$xxxx+;;:...       
          &.......xxxxX&;:;xxxxxxxxx;:&&Xxxxx.......          
                 ....xxX$&.;xxxxxx;:&&XxxX....                
                    .;;&xX&x;xxxx;+&Xxx...                    
              .        ...x&+:;;:X&x...        .              
             ..          ............   .       ..            
           ...      .....            .....      ...           
          ...      ..xxx......  ......xxxX..     .+..         
        .....     ..xxxxxxxx+:...;xXxxxxxx;.      .x..        
       ..Xx.     ..X$xxxxxxxxxxXxxxxxxxxxxxx.     ..x...      
     ..xXx..    ..xx+xxxxxxxxxxxxxxxxxxxxxxx;.     .x$X..     
    ..xx$x.    ..xxxxxxxxxxxxxxxxxxxxxxxxxxxXx.    .xXxX..    
   ..x$xxx.    .xXxxxxxxxxxxxxxxxxxxxxxxXxxxXx.    .:XxxX..   
  ..xXxxX;.   ..xxxxxxxxxxxxxxxxxxxxxxxXxxxxx$;.    .xxXXX..  
  .x$xx$X;.   .xXxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx.    .XxXX$$.. 
 .+$xXX$x:.   .xXxxxxxxxxxxxxxxxxXXxxxxxxXxXxxX.    .X&$XX$$..
..$$$X$$...   .xXxxxxxxxxxxxxxxxxxxxXXxxxxxXXxX:.   .+&&xx$$x.
.+$x$X:.. .   .x$xxXXXXXXxxXxxxxxxxxxxxxxX$xxx$$.    ...$X$$x.
.X$X$:.       .xXxxXxxxxxxxXxXXXxXxxXxxxxXXXxXX:       ..X$$$.
.$&$..        .xx$xxxXXXXXXXxxxxxxXxxxX$xXXXXXX.        ..:$&.
.X;.           .XxXXxXXXXxxXXXXX$X$X$XXXxxxXX$..          .;&.
...            .x&$XX$xxxXX$$$XXXXxxxx$$XXxx$x.            ...
                ..$XXXxxXxxxxxxxxxXXXxxXXX$$$..               
                 ....x$$$$$$$$$$$$XXX$XX$:....                
                     ....xXXXXXXXXXX&;...X                    
                 .....   ..x&&$$$&$;.    ....                 
              ...x&&&;..   ........   ..:X&&$...              
             .............          .............             
EOF
)

while IFS= read -r line; do
    printf '%s\n' "$line"
done <<< "$art" | awk '
BEGIN {
    reset = "\033[0m"
    cyan1 = "\033[38;2;105;234;232m"
    light = "\033[38;2;177;239;245m"
    white = "\033[38;2;224;250;252m"
    shine = "\033[38;2;143;244;245m"
    dark  = "\033[38;2;16;172;218m"
}
{
    row = NR
    line = $0

    if (row <= 23) {
        t = (row - 1) / 22
        r = int(105 + (50-105)*t)
        g = int(234 + (222-234)*t)
        b = int(232 + (235-232)*t)
    } else {
        t = (row - 23) / 23
        if (t > 1) t = 1
        r = int(50 + (23-50)*t)
        g = int(222 + (187-222)*t)
        b = 235
    }

    base = sprintf("\033[38;2;%d;%d;%dm",r,g,b)

    for (i=1; i<=length(line); i++) {
        c = substr(line,i,1)
        color = base

        if (row >= 17 && row <= 22) {
            if (i >= 8 && i <= 27)
                color = light
            if (i >= 39 && i <= 57)
                color = light
        }

        if (row >= 20 && row <= 24 && i >= 27 && i <= 40)
            color = white

        if (c == "X" && color == base)
            color = shine

        if (c == "$" && color == base)
            color = dark

        if (c == "&" && color == base)
            color = cyan1

        if ((c == "." || c == ":") && color == base) {
            rr = r + 12
            gg = g + 10
            bb = b + 8

            if (rr > 255) rr=255
            if (gg > 255) gg=255
            if (bb > 255) bb=255

            color=sprintf("\033[38;2;%d;%d;%dm",rr,gg,bb)
        }

        printf "%s%s", color, c
    }

    printf "%s\n", reset
}
'
