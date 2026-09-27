#!/usr/bin/env bash

art=$(cat <<'EOF'
        ...                              ....        
       ........                      ......:..       
       ..  ...x...                 ...;..   ;;       
      ...    ...x:..             ...x...    :$       
      ...      ..xx:..............xx..      :$       
       ..       :xxxxxxxxxxxxxxxxxxx:      .+:       
       .x.    ...xXXXXXxxxxxxxxxXXxX...    .x.       
       .... ...xxxxxxxxXXXXXxXXxxxxXxx... .+..       
        .x:..xxxxxxXxxxxxxxxxxxXxxXxxxxx.....        
         xxxxxxxxxxxxxXxXxXXXxxXXXxxxxxxXXX.         
        .xXXxxxxx.....xxxxxxxx......xxxxxxx..        
       .:XxxXXXxx+    ..XxXxX..    .XXXxxXXx..       
     ..:x+;;++xxx....  .Xx$XX.  ...:xxxxxxxXX&x.     
    ..;+;&&&&$&;x+xx:..;xXxxx;..:;;;;+&&&&x;;;$.     
      .....+xX$&&&&;+xxxxx$xxxxx+x $&&$Xxx:...&      
           .....;X$&&xxXXxxxxxx:&Xxx:.....           
                ...;$&;xxXXXxx&&$:..                 
            .      :..+&x::.x&;..                    
          ..      .   .... ...;   .      .           
         ..     ..:...         .....     ...         
       ....    ..$XxXx........:$X$$X..    .:..       
      .;$.    .:$$$XX$$XXX$$$$XXXxX$X:.   .:X..      
    ..x$:.   ..xXxxxxxxxXXXXxXxxXxx$$x.    .X&&x.    
   ..$$$.    .$Xx$$$$$$$$xxxXxXXXxXXX$x.   .:$X$..   
  .:$X$x.   .:$XXXXXXXXXXXXXXXX$$$$XXX$..   .XX$$:.  
 .:&$$$x.   .X$$$$$XX$X$$$$$$$XXXXXXXX$x.   .$$$$&:. 
..&$$$&X.   .$$xXx$XXXXXXXX$XXXXXXXXX$$X.   .&&$$$&:.
.$$$$x...   .$XX$XX$$$$XXXXX$$$$X$X$XX$$.   ...x$&$$.
.&&&+.      .$$$$$$XXXX$$$$$XXX$$$XX$X$$.      .;&&$.
.&x.        .$&$$$$$$$$$$$$$$$$$$$$$$$$;.       .x&&.
.+.         .;&$$$XX$$$$$$$$$$$$$$$xx$$.          ;x.
             .;&$$$$$$$$$$$$$$$$$$$$$&;.           . 
              ....x&&$&$$$$$$$&$$$x:...              
                  ;;..+&$$$$$$x:.++                  
             .....;:  ........:  ;;.....             
           .......:...         ...........            
EOF
)

printf '%s\n' "$art" | awk '
BEGIN {
    reset = "\033[0m"
    white = "\033[38;2;226;250;252m"
    muzzle = "\033[38;2;190;243;247m"
    glow = "\033[38;2;125;239;240m"
    shadow = "\033[38;2;13;169;222m"
}
{
    row = NR

    if (row <= 18) {
        t = (row - 1) / 17
        r = int(105 - 45 * t)
        g = int(235 - 10 * t)
        b = int(232 + 3 * t)
    } else {
        t = (row - 18) / 18
        r = int(60 - 38 * t)
        g = int(225 - 37 * t)
        b = 235
    }

    base = sprintf("\033[38;2;%d;%d;%dm", r, g, b)

    for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        color = base

        if (row >= 13 && row <= 17) {
            if ((i >= 5 && i <= 20) || (i >= 35 && i <= 50)) {
                color = muzzle
            }
        }

        if (row >= 15 && row <= 19 && i >= 18 && i <= 37) {
            color = white
        }

        if (color == base) {
            if (c == "X") {
                color = glow
            } else if (c == "$") {
                color = shadow
            } else if (c == "&") {
                color = white
            } else if (c == "." || c == ":") {
                rr = r + 14
                gg = g + 11
                bb = b + 7

                if (rr > 255) rr = 255
                if (gg > 255) gg = 255
                if (bb > 255) bb = 255

                color = sprintf("\033[38;2;%d;%d;%dm", rr, gg, bb)
            }
        }

        printf "%s%s", color, c
    }

    printf "%s\n", reset
}
'
