#!/usr/bin/env bash
# Usage: ./play_torrents.sh <list-file>
# Each line of <list-file> is a magnet link / torrent URL / .torrent path.
#
# Big torrents are handled in batches: the audio files are listed with
# `rqbit download --list`, split into roughly equal batches of at most
# $BATCH_MAX bytes (so between BATCH_MAX/2 and BATCH_MAX when the torrent is
# bigger than that), and each batch is downloaded (-r <regex of its paths>)
# into its own directory $DL_DIR/<seq>.
#
# Downloading and playing are pipelined: a background producer downloads the
# batches one after another (across all torrents in the list), while the
# foreground plays each finished batch and deletes it. The producer stays at
# most one batch ahead, so at most two batches are on disk at a time.
set -u

LIST="${1:?usage: $0 <list-file>}"
[[ -r "$LIST" ]] || { echo "!!! Can't read list file: $LIST" >&2; exit 1; }
RQBIT="${RQBIT:-rqbit}"            # rqbit binary (the image installs it in /usr/local/bin)
DL_DIR="./download"
FIFO="/tmp/snapfifo"               # snapserver-rs source must read floats: pipe:///tmp/snapfifo?...&encoding=float
RQBIT_LOG="./rqbit.log"            # rqbit --log-file for downloads (holds the current download only)
UPLOAD_LIMIT=256000                # rqbit --ratelimit-upload, bytes per second
ROUNDS=2
BATCH_MAX=$((2 * 1024 ** 3))
LIST_TIMEOUT=600                   # seconds to wait for torrent metadata
DONE_MARK=".batch_complete"        # in a batch dir: it finished downloading; holds its label
SNAP_RPC="http://127.0.0.1:1780/jsonrpc"   # local snapserver JSON-RPC, for track metadata

# Ctrl-C / kill: stop everything (ffmpeg, rqbit, producer, and this loop) instead of skipping to the next track.
# Bash runs a trap only once the foreground command returns, so long-running
# work is started in the background and waited for (`wait` returns at once on a
# trapped signal). kill 0 TERMs the whole process group; ignore TERM here meanwhile.
# ffmpeg only exits on TERM between writes, so one blocked on a full pipe would
# need several Ctrl-C: KILL it (it only streams PCM, nothing to clean up).
trap 'trap "" INT TERM; echo; echo ">>> Interrupted, exiting"; kill 0; pkill -KILL -g 0 -x ffmpeg; exit 130' INT TERM

AUDIO_EXT_RE='\.(flac|wav|ape|wv|tta|aiff|aif|alac|m4a|mka)$'
# Codecs accepted from container formats that may hold lossy or lossless audio
LOSSLESS_CODECS=" alac flac wavpack ape tta mlp truehd pcm_s16le pcm_s24le pcm_s32le pcm_f32le "

# list_audio <torrent>: print "bytes<TAB>path" for each audio file, sorted by path.
# rqbit prints lines like "... INFO rqbit: File CD01/x.flac, size 191.0Mi"
# --foreground: otherwise timeout moves to its own process group, out of reach of kill 0
list_audio() {
    timeout --foreground "$LIST_TIMEOUT" "$RQBIT" download --list "$1" 2>&1 \
        | sed -E 's/\x1b\[[0-9;]*m//g' \
        | sed -nE 's/.*rqbit: File (.*), size ([0-9.]+) ?([KMGT]i)?B?$/\2\t\3\t\1/p' \
        | awk -F'\t' '
            BEGIN { m["Ki"] = 1024; m["Mi"] = 1024^2; m["Gi"] = 1024^3; m["Ti"] = 1024^4 }
            { printf "%.0f\t%s\n", $1 * ($2 in m ? m[$2] : 1), $3 }' \
        | grep -iE "$AUDIO_EXT_RE" \
        | sort -t $'\t' -k2,2V
}

# plan_batches: stdin "bytes<TAB>path" -> stdout "batch<TAB>path".
# Files of one directory (an album / CD) stay together unless the directory
# alone exceeds $BATCH_MAX. With n = ceil(total / BATCH_MAX) batches of target
# size total/n, each unit goes to the batch where its midpoint falls.
plan_batches() {
    awk -F'\t' -v max="$BATCH_MAX" '
        {
            nf++; fsize[nf] = $1; fpath[nf] = $2
            d = $2; if (!sub(/\/[^\/]*$/, "", d)) d = ""
            if (nf == 1 || d != dir[nd]) dir[++nd] = d
            fdir[nf] = nd; dsize[nd] += $1; total += $1
        }
        END {
            if (!nf) exit
            for (i = 1; i <= nf; i++) {
                if (i == 1 || dsize[fdir[i]] > max || fdir[i] != fdir[i-1]) nu++
                funit[i] = nu; usize[nu] += fsize[i]
            }
            # Midpoint rounding can overshoot max: retry with one more batch
            for (nb = int((total + max - 1) / max); ; nb++) {
                target = total / nb; cum = 0; out = 0; prev = 0; over = 0
                delete bsize
                for (u = 1; u <= nu; u++) {
                    b = int((cum + usize[u] / 2) / target) + 1; if (b > nb) b = nb
                    if (b != prev) { out++; prev = b }
                    ubatch[u] = out; cum += usize[u]
                    if ((bsize[out] += usize[u]) > max && usize[u] < bsize[out]) over = 1
                }
                if (!over || nb >= nu) break
            }
            for (i = 1; i <= nf; i++) printf "%d\t%s\n", ubatch[funit[i]], fpath[i]
        }'
}

re_escape() { sed 's/[][\\.^$|?*+(){}]/\\&/g' <<< "$1"; }

human() { numfmt --to=iec --suffix=B "$1"; }

# build_playlist <dir> <rel-path>...: resolve torrent-relative paths to the
# files rqbit wrote under <dir> (usually <dir>/<torrent name>/<rel-path>), keep
# the lossless ones in the global array `playlist` and write <dir>/playlist.m3u.
# Files not in the batch are ignored: rqbit leaves 0-byte / partial files there.
build_playlist() {
    local dir="$1"; shift
    local -A want=()
    local rel file p codec
    for rel in "$@"; do want[$rel]=1; done

    playlist=()
    while IFS= read -r -d '' file; do
        p="${file#"$dir"/}"
        [[ -n "${want[$p]:-}" || -n "${want[${p#*/}]:-}" ]] || continue
        # .m4a/.mka can be AAC/MP3/Opus etc.: keep them only if the codec is lossless
        case "${file,,}" in
            *.m4a|*.mka)
                codec=$(ffprobe -v error -select_streams a:0 \
                    -show_entries stream=codec_name -of csv=p=0 "$file")
                [[ "$LOSSLESS_CODECS" == *" $codec "* ]] || continue
                ;;
        esac
        playlist+=("$file")
    done < <(find "$dir" -type f -size +0 -print0 | sort -zV)

    { echo '#EXTM3U'; printf '%s\n' "${playlist[@]}"; } > "$dir/playlist.m3u"
}

# snap_rpc <method> <params-json>: call the local snapserver, print the result.
# Fails if snapserver isn't reachable or answers with an error.
snap_rpc() {
    local resp
    resp=$(jq -cn --arg m "$1" --argjson p "$2" '{jsonrpc: "2.0", id: 1, method: $m, params: $p}' \
        | curl -sf --max-time 2 -H 'Content-Type: application/json' --data-binary @- "$SNAP_RPC") \
        || return 1
    jq -e 'has("error") | not' <<< "$resp" > /dev/null || {
        echo "    snapserver: $1 failed: $(jq -c '.error' <<< "$resp")" >&2
        return 1
    }
    jq -c '.result' <<< "$resp"
}

# track_metadata <file>: print the file's tags as Snapcast (MPRIS-style) metadata JSON
track_metadata() {
    ffprobe -v error -show_entries format=duration:format_tags:stream_tags -of json "$1" \
        | jq -c --arg file "$1" '
            ((.format.tags // {}) + (.streams[0].tags // {}) | with_entries(.key |= ascii_downcase)) as $t
            | def list: if . then [splits("\\s*;\\s*")] else null end;
              def num: if . then (split("/")[0] | tonumber? ) else null end;
            {
                title: ($t.title // ($file | split("/")[-1] | sub("\\.[^.]*$"; ""))),
                artist: ($t.artist | list),
                album: $t.album,
                albumArtist: (($t.album_artist // $t.albumartist) | list),
                genre: ($t.genre | list),
                trackNumber: ($t.track | num),
                discNumber: ($t.disc | num),
                contentCreated: $t.date,
                duration: (.format.duration | tonumber?),
                url: ("file://" + $file)
            } | with_entries(select(.value != null))'
}

# snap_set_metadata <file>: show <file> as the playing track on snapserver's
# stream fed by $FIFO. Skipped silently if snapserver isn't running.
snap_set_metadata() {
    local status stream meta
    status=$(snap_rpc Server.GetStatus '{}') || return 0
    stream=$(jq -r --arg fifo "$FIFO" '
        .server.streams // [] | (map(select(.uri.path == $fifo)) + .)[0].id // empty' <<< "$status")
    [[ -n "$stream" ]] || return 0
    meta=$(track_metadata "$1") || return 0
    snap_rpc Stream.SetProperty "$(jq -cn --arg id "$stream" --argjson m "$meta" \
        '{id: $id, properties: {playbackStatus: "playing", metadata: $m}}')" > /dev/null
}

# play_playlist <rounds>
# Each track is decoded by its own ffmpeg, resampled to 48 kHz with soxr,
# normalized with dynaudnorm and written to the FIFO as float PCM. No 16-bit
# step: snapserver-rs (encoding=float) hands the floats to the Opus encoder.
# Keep -y: without it ffmpeg refuses to open the existing FIFO ("already exists").
#
# -readrate 1.05: read the input at 1.05x real time (after a 10 s initial
# burst), so ffmpeg stays only a little ahead of what snapserver plays. The
# FIFO reader also drains in real time, so pipe backpressure would pace it
# anyway, but without -readrate ffmpeg finishes decoding (and the next track's
# "Playing" line and metadata go out) up to a pipe buffer + dynaudnorm window
# early. 1.05 rather than 1.0 keeps the FIFO from running dry.
play_playlist() {
    local rounds="$1" round file
    for ((round = 1; round <= rounds; round++)); do
        echo ">>> Round $round/$rounds (${#playlist[@]} tracks)" >&2
        for file in "${playlist[@]}"; do
            echo "    Playing: $file" >&2
            # In the background: a slow snapserver must not stall the audio
            snap_set_metadata "$file" &
            ffmpeg -nostdin -hide_banner -loglevel error \
                -readrate 1.05 -readrate_initial_burst 10 -i "$file" -vn \
                -af "aresample=48000:resampler=soxr:precision=22,dynaudnorm=f=500:g=31:p=0.95:m=8:r=0.22:s=25.0" \
                -f f32le -acodec pcm_f32le -ac 2 -y "$FIFO" \
                || echo "    Failed: $file" >&2
        done
    done
}

# batch_dirs: set the global array `dirs` to the batch directories, oldest first
batch_dirs() {
    local d
    dirs=()
    for d in "$DL_DIR"/[0-9]*/; do [[ -d "$d" ]] && dirs+=("${d%/}"); done
}

# next_ready: print the oldest batch dir that finished downloading
next_ready() {
    local d
    batch_dirs
    for d in "${dirs[@]}"; do
        [[ -f "$d/$DONE_MARK" ]] && { echo "$d"; return 0; }
    done
    return 1
}

# play_dir <dir> <rounds>: play a finished batch, then delete it
play_dir() {
    mapfile -t playlist < <(grep -v '^#' "$1/playlist.m3u")
    echo ">>> Playing $(< "$1/$DONE_MARK")" >&2
    # Background + wait, so Ctrl-C reaches the trap at once (see the trap above)
    if (( ${#playlist[@]} > 0 )); then
        play_playlist "$2" &
        wait $!
    fi
    rm -rf "$1"
}

# producer: list, plan and download every batch of every torrent in $LIST,
# waiting before each download until at most one other batch is on disk.
producer() {
    local seq=0 line f b path regex dir nbatches
    local -a files paths
    # Read the list on fd 3 so rqbit can't swallow the remaining lines from stdin
    while IFS= read -r line <&3 || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        echo ">>> Listing: $line" >&2
        mapfile -t files < <(list_audio "$line")
        if (( ${#files[@]} == 0 )); then
            echo "!!! No audio files listed (metadata timeout or no audio): $line" >&2
            continue
        fi

        # batch_paths[b] = newline-separated paths, batch_size[b] = bytes
        local -A batch_paths=() batch_size=() size_of=()
        for f in "${files[@]}"; do size_of[${f#*$'\t'}]=${f%%$'\t'*}; done
        nbatches=0
        while IFS=$'\t' read -r b path; do
            batch_paths[$b]+="$path"$'\n'
            batch_size[$b]=$(( ${batch_size[$b]:-0} + ${size_of[$path]} ))
            (( b > nbatches )) && nbatches=$b
        done < <(printf '%s\n' "${files[@]}" | plan_batches)

        for ((b = 1; b <= nbatches; b++)); do
            mapfile -t paths < <(printf '%s' "${batch_paths[$b]}")
            regex=$(for path in "${paths[@]}"; do re_escape "$path"; done | paste -sd '|')

            # One batch may be playing and one ready: wait for the playing one to finish
            while batch_dirs; (( ${#dirs[@]} >= 2 )); do sleep 2; done

            # Increment outside $(...): a command substitution is a subshell
            (( ++seq ))
            dir="$DL_DIR/$(printf '%06d' "$seq")"
            mkdir -p "$dir"
            echo ">>> Downloading batch $b/$nbatches: ${#paths[@]} files, $(human "${batch_size[$b]}") (log: $RQBIT_LOG)" >&2

            # --exit-on-finish: without it rqbit keeps seeding and never returns.
            # --log-file gets the log at info level (its default is librqbit=debug);
            # the console copy is dropped since we run in the background.
            # rqbit appends to the log: start each download with a fresh one.
            rm -f "$RQBIT_LOG"
            if ! "$RQBIT" --log-file "$RQBIT_LOG" --log-file-rust-log info \
                    --ratelimit-upload "$UPLOAD_LIMIT" \
                    download --exit-on-finish -o "$dir" -r "^($regex)\$" "$line" > /dev/null 2>&1; then
                echo "!!! Download failed: batch $b/$nbatches of $line" >&2
                rm -rf "$dir"
                continue
            fi

            build_playlist "$dir" "${paths[@]}"
            if (( ${#playlist[@]} == 0 )); then
                echo "!!! No lossless tracks in batch $b/$nbatches of $line" >&2
                rm -rf "$dir"
                continue
            fi
            echo ">>> Downloaded batch $b/$nbatches (${#playlist[@]} tracks)" >&2
            echo "batch $b/$nbatches of $line" > "$dir/$DONE_MARK"
        done
        unset batch_paths batch_size size_of
    done 3< "$LIST"
}

mkdir -p "$DL_DIR"

# Hold the FIFO open read-write for the whole run (never read from), so it
# always has a reader. If snapserver stops or restarts, ffmpeg's writes then
# just block once the pipe buffer is full, and resume when snapserver reopens
# the FIFO, instead of failing with "Broken pipe".
[[ -p "$FIFO" ]] || mkfifo "$FIFO" || exit 1
exec 4<>"$FIFO"

# Leftovers from a previous (interrupted) run: batches that had finished
# downloading are played once. Unfinished batches are just partial files: drop them.
while dir=$(next_ready); do
    echo ">>> Found leftover batch $dir, playing once"
    play_dir "$dir" 1
done
echo ">>> Cleaning up $DL_DIR"
find "$DL_DIR" -mindepth 1 -delete

producer &
producer_pid=$!

while :; do
    if dir=$(next_ready); then
        play_dir "$dir" "$ROUNDS"
    elif kill -0 "$producer_pid" 2>/dev/null; then
        sleep 2
    elif ! dir=$(next_ready); then
        break   # producer finished and nothing left to play
    fi
done
wait
echo ">>> All done"
