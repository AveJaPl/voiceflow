#!/usr/bin/env bash
# Buduje pionową rolkę 1080x1920 z lektora + marmurów z landingu.
#
#   ./build-reel.sh <plik-lektora.mp3> <plik-wyjsciowy.mp4>
#
# Napisy i cięcia są opisane w tablicy CAPTIONS (start;koniec;styl;tekst),
# więc zmiana lektora = podmiana czasów w jednym miejscu, bez ruszania ffmpega.
set -euo pipefail

VOICE="${1:?podaj plik mp3 z lektorem}"
OUT="${2:?podaj plik wyjsciowy mp4}"

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$ROOT/site/assets"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FONT_DISPLAY=/usr/share/fonts/truetype/liberation/LiberationSansNarrow-Bold.ttf
FONT_BODY=/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf

W=1080; H=1920; FPS=30

# --- sceny: obraz + czas trwania -------------------------------------------
# Powolny najazd (Ken Burns) + odbarwienie do monochromu, jak na stronie.
scene() { # $1=obraz $2=sekundy $3=wyjscie $4=kierunek(in|out)
    local frames; frames=$(python3 -c "print(int($2*$FPS))")
    local zexpr
    if [[ "$4" == "in" ]]; then
        zexpr="min(1+0.00040*on,1.14)"
    else
        zexpr="max(1.14-0.00040*on,1.0)"
    fi
    ffmpeg -y -loglevel error -loop 1 -i "$1" -t "$2" \
        -vf "scale=-2:2304:flags=lanczos,crop=1296:2304,\
zoompan=z='$zexpr':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=$frames:s=${W}x${H}:fps=$FPS,\
hue=s=0,eq=contrast=1.22:brightness=-0.06:gamma=0.94,\
vignette=angle=PI/4.2,format=yuv420p" \
        -r $FPS -c:v libx264 -crf 17 -preset medium "$3"
}

# --- karta końcowa ----------------------------------------------------------
endcard() { # $1=sekundy $2=wyjscie
    ffmpeg -y -loglevel error -f lavfi -i "color=c=0x0A0A0A:s=${W}x${H}:d=$1:r=$FPS" \
        -vf "drawtext=fontfile=$FONT_DISPLAY:text='voiceflow':fontcolor=white:fontsize=132:\
x=(w-text_w)/2:y=(h-text_h)/2-150,\
drawtext=fontfile=$FONT_BODY:text='Free. Open. Yours.':fontcolor=0xBFBFBF:fontsize=52:\
x=(w-text_w)/2:y=(h-text_h)/2+20,\
drawtext=fontfile=$FONT_BODY:text='github.com/AveJaPl/voiceflow':fontcolor=0x8A8A8A:fontsize=38:\
x=(w-text_w)/2:y=(h-text_h)/2+140,\
format=yuv420p" \
        -c:v libx264 -crf 17 -preset medium "$2"
}

echo "==> sceny"
scene "$ASSETS/statue-muse-4.webp"  10.72 "$WORK/s1.mp4" in
scene "$ASSETS/statue-hand-4.webp"   8.66 "$WORK/s2.mp4" out
scene "$ASSETS/hero-statue-4.webp"   6.12 "$WORK/s3.mp4" in
endcard 4.2 "$WORK/s4.mp4"

echo "==> sklejanie"
for f in s1 s2 s3 s4; do echo "file '$WORK/$f.mp4'"; done > "$WORK/list.txt"
ffmpeg -y -loglevel error -f concat -safe 0 -i "$WORK/list.txt" -c copy "$WORK/base.mp4"

# --- napisy -----------------------------------------------------------------
# start;koniec;styl;tekst    styl: big = hasło, small = zdanie
CAPTIONS=(
"0.15;1.10;big;I SPEAK,"
"1.10;2.98;big;THEREFORE I WRITE."
"3.10;6.24;small;For centuries the hand was slower than the mind."
"6.30;8.01;small;Thoughts at the speed of lightning."
"8.05;10.72;small;Fingers at the speed of stone."
"10.80;12.22;big;NO LONGER."
"12.30;14.02;small;Press one key."
"14.05;15.79;small;Say what you mean."
"15.82;17.52;small;Watch the words appear —"
"17.55;19.38;small;wherever the cursor waits."
"19.42;20.71;big;NO CLOUD."
"20.75;22.22;big;NO SUBSCRIPTION."
"22.26;24.08;small;Only your own machine,"
"24.10;25.60;small;listening."
)

filter=""
for entry in "${CAPTIONS[@]}"; do
    IFS=';' read -r start end style text <<< "$entry"
    # apostrofy i dwukropki trzeba uciec, inaczej ffmpeg rozbije sobie filtr
    esc=${text//\\/\\\\}; esc=${esc//\'/\\\\\\\'}; esc=${esc//:/\\:}
    if [[ "$style" == "big" ]]; then
        font=$FONT_DISPLAY; size=104; color=white; ypos="h-620"
    else
        font=$FONT_BODY;    size=56;  color=0xE8E8E8; ypos="h-560"
    fi
    # miękkie wejście/wyjście napisu, żeby nie migało
    alpha="if(lt(t,$start+0.25),(t-$start)/0.25,if(gt(t,$end-0.25),($end-t)/0.25,1))"
    filter+="drawtext=fontfile=$font:text='$esc':fontcolor=$color:fontsize=$size:\
x=(w-text_w)/2:y=$ypos:alpha='$alpha':\
box=1:boxcolor=0x000000@0.34:boxborderw=26:\
enable='between(t,$start,$end)',"
done
filter="${filter%,}"

echo "==> napisy + dźwięk"
ffmpeg -y -loglevel error -i "$WORK/base.mp4" -i "$VOICE" \
    -filter_complex "[0:v]$filter[v];[1:a]afade=t=out:st=25.2:d=0.9,apad=pad_dur=4[a]" \
    -map "[v]" -map "[a]" \
    -c:v libx264 -crf 19 -preset medium -pix_fmt yuv420p \
    -c:a aac -b:a 192k -shortest -movflags +faststart "$OUT"

echo "==> gotowe: $OUT"
ffprobe -v quiet -show_entries format=duration,size -of default=nw=1 "$OUT"
