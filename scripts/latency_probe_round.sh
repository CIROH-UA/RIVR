#!/bin/bash
# ADR 0017 latency probe — one round. Appends a JSON line to $OUT.
# Everything here is a MEASUREMENT. No conclusions are drawn in this script.
OUT=${OUT:-/tmp/latency.jsonl}
POOL=${POOL:-/tmp/pool.txt}
FN=https://us-west1-ciroh-rivr-app.cloudfunctions.net/geoglows_forecast
UP=https://geoglows.ecmwf.int/api/v2
NOAA=https://api.water.noaa.gov/nwps/v1

t() { # t <url>  -> "seconds http bytes"
  curl -s -o /dev/null -w "%{time_total} %{http_code} %{size_download}" --max-time 150 "$1" 2>/dev/null || echo "-1 000 0"
}

ROUND=$(date -u +%s)
HOUR=$((10#$(date -u +%H)))
ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# A river this round will treat as "new". Rotate through the pool by round.
mapfile -t IDS < "$POOL"
N=${#IDS[@]}
[ "$N" -eq 0 ] && IDS=(220458874 220458875 220458880 220458890 220458895 220458900 220458901 220458905 220458910) && N=9
IDX=$(( (ROUND / 1800) % N ))
RIVER=${IDS[$IDX]}
RIVER2=${IDS[$(( (IDX + 3) % N ))]}

# 1. NOAA — not ours, verified-real reaches
read n1 n1c n1b <<< "$(t "$NOAA/reaches/23997208")"
read n2 n2c n2b <<< "$(t "$NOAA/reaches/3624735")"
read n3 n3c n3b <<< "$(t "$NOAA/reaches/5781481/streamflow?series=short_range")"

# 2. GEOGLOWS upstream REST — not ours
read u1 u1c u1b <<< "$(t "$UP/forecast/$RIVER?format=json")"
read u2 u2c u2b <<< "$(t "$UP/forecaststats/$RIVER?format=json")"
read u3 u3c u3b <<< "$(t "$UP/returnperiods/$RIVER?format=json")"

# 3. Our proxy — a river this instance has probably not got
read f1 f1c f1b <<< "$(t "$FN?river_id=$RIVER")"
# 4. Our proxy — immediate repeat (in-process cache)
read f2 f2c f2b <<< "$(t "$FN?river_id=$RIVER")"
# 5. Our proxy — a different river on the now-warm instance
read f3 f3c f3b <<< "$(t "$FN?river_id=$RIVER2")"

printf "{\"iso\":\"%s\",\"utc_hour\":%d,\"river\":%s,\"river2\":%s," "$ISO" "$((10#$HOUR))" "$RIVER" "$RIVER2" >> "$OUT"
printf '"noaa_meta_a":[%s,%s],"noaa_meta_b":[%s,%s],"noaa_series":[%s,%s],' "$n1" "$n1c" "$n2" "$n2c" "$n3" "$n3c" >> "$OUT"
printf '"up_forecast":[%s,%s,%s],"up_stats":[%s,%s,%s],"up_returnperiods":[%s,%s,%s],' "$u1" "$u1c" "$u1b" "$u2" "$u2c" "$u2b" "$u3" "$u3c" "$u3b" >> "$OUT"
printf '"ours_new":[%s,%s,%s],"ours_repeat":[%s,%s,%s],"ours_second_river":[%s,%s,%s]}\n' "$f1" "$f1c" "$f1b" "$f2" "$f2c" "$f2b" "$f3" "$f3c" "$f3b" >> "$OUT"
echo "round $ISO done"
