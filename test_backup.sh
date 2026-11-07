#!/bin/bash
# Tests for the completion-marker contract in backup.sh.
#
# The thing under test is not the dump: it is the rule that an archive is only a
# backup when its .OK marker exists. Every case therefore asserts on which objects
# reached S3, not on their contents.
#
# pg_dump, gzip and aws are replaced by stubs on PATH whose behaviour is driven by
# STUB_FAIL_*. The stub aws records every upload destination, so a case can assert
# that an archive was uploaded and the marker was not -- the exact shape of the
# 2026-10-20 incident.
#
# Run: bash test_backup.sh   (or SH_UNDER_TEST=busybox bash test_backup.sh)

set -o nounset

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUBS="$WORK/stubs"
mkdir -p "$STUBS"

cat > "$STUBS/pg_dump" <<'STUB'
#!/bin/bash
echo "-- partial dump"
if [ "${STUB_FAIL_PG_DUMP:-0}" = "1" ]; then
    echo "pg_dump: error: query would be affected by row-level security policy" >&2
    exit 1
fi
echo "-- PostgreSQL database dump complete"
exit 0
STUB

cat > "$STUBS/gzip" <<'STUB'
#!/bin/bash
if [ "${STUB_FAIL_GZIP:-0}" = "1" ]; then
    cat > /dev/null
    exit 1
fi
exec cat
STUB

cat > "$STUBS/aws" <<'STUB'
#!/bin/bash
# Recognises the two invocations backup.sh makes: `s3 ... ls BUCKET` and `s3 ... cp - DEST`.
sub=""
for a in "$@"; do
    case "$a" in
        ls|cp) sub="$a"; break ;;
    esac
done

if [ "$sub" = "ls" ]; then
    exit 0
fi

if [ "$sub" = "cp" ]; then
    dest="${!#}"
    case "$dest" in
        *.OK)
            cat > "$STUB_MARKER_BODY"
            echo "$dest" >> "$STUB_UPLOAD_LOG"
            [ "${STUB_FAIL_MARKER_UPLOAD:-0}" = "1" ] && exit 1
            exit 0
            ;;
        *)
            cat > /dev/null
            echo "$dest" >> "$STUB_UPLOAD_LOG"
            [ "${STUB_FAIL_ARCHIVE_UPLOAD:-0}" = "1" ] && exit 1
            exit 0
            ;;
    esac
fi

exit 0
STUB

chmod +x "$STUBS/pg_dump" "$STUBS/gzip" "$STUBS/aws"

# backup.sh declares BusyBox ash and needs `set -o pipefail`. The host's /bin/sh is
# NOT guaranteed to provide it -- on Debian/Ubuntu it is dash, which rejects pipefail
# and aborts the script before any work. That would make the failure cases below pass
# VACUOUSLY. So pick a shell that supports pipefail, prefer real BusyBox when installed,
# and refuse to run otherwise.
pick_shell() {
    if [ -n "${SH_UNDER_TEST:-}" ]; then
        echo "$SH_UNDER_TEST"
        return
    fi
    if command -v busybox > /dev/null 2>&1 && busybox sh -c 'set -o pipefail' > /dev/null 2>&1; then
        echo "busybox sh"
        return
    fi
    if sh -c 'set -o pipefail' > /dev/null 2>&1; then
        echo "sh"
        return
    fi
    echo ""
}

SHELL_UNDER_TEST="$(pick_shell)"
if [ -z "$SHELL_UNDER_TEST" ]; then
    echo "ABORT: no available sh supports 'set -o pipefail' (Debian/Ubuntu dash does not)."
    echo "       Install busybox, or set SH_UNDER_TEST to a shell that has it."
    exit 1
fi
echo "interpreter under test: $SHELL_UNDER_TEST"
case "$SHELL_UNDER_TEST" in
    busybox*) ;;
    *) echo "         NOTE: not BusyBox, so this covers behaviour, not dialect (case 7 covers dialect)." ;;
esac
echo

PASS=0
FAIL=0

run_backup() {
    STUB_UPLOAD_LOG="$WORK/uploads.txt"
    STUB_MARKER_BODY="$WORK/marker.txt"
    : > "$STUB_UPLOAD_LOG"
    : > "$STUB_MARKER_BODY"
    export STUB_UPLOAD_LOG STUB_MARKER_BODY

    # Invoked the way production does: Dockerfile ENTRYPOINT is [ "sh", "backup.sh" ].
    PATH="$STUBS:$PATH" \
    AWS_REGION="us-west-2" \
    S3_BUCKET_NAME="test-bucket" \
    DATABASE_URL="postgresql://stub/stub" \
        $SHELL_UNDER_TEST "$HERE/backup.sh" > "$WORK/stdout.txt" 2> "$WORK/stderr.txt"
    RUN_EXIT=$?
}

check() {
    local label="$1" condition="$2"
    if [ "$condition" = "1" ]; then
        echo "  PASS  $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $label"
        FAIL=$((FAIL + 1))
    fi
}

uploaded_archive() {
    grep -qE 'backup-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9a-f]{8}\.sql\.gz$' "$STUB_UPLOAD_LOG" && echo 1 || echo 0
}

uploaded_marker() {
    grep -q '\.sql\.gz\.OK$' "$STUB_UPLOAD_LOG" && echo 1 || echo 0
}

archive_key() {
    grep -E '\.sql\.gz$' "$STUB_UPLOAD_LOG" | head -1 | sed 's#^s3://[^/]*/##'
}

echo "1. happy path: pipeline succeeds"
STUB_FAIL_PG_DUMP=0 STUB_FAIL_GZIP=0 STUB_FAIL_ARCHIVE_UPLOAD=0 STUB_FAIL_MARKER_UPLOAD=0 \
    run_backup
check "exits 0" "$([ "$RUN_EXIT" -eq 0 ] && echo 1 || echo 0)"
check "archive uploaded" "$(uploaded_archive)"
check "marker uploaded" "$(uploaded_marker)"
check "marker names the archive it certifies" \
    "$(grep -qx "backup=$(archive_key)" "$STUB_MARKER_BODY" && echo 1 || echo 0)"
check "marker says status=complete" \
    "$(grep -qx 'status=complete' "$STUB_MARKER_BODY" && echo 1 || echo 0)"
check "marker records pg_dump_exit=0" \
    "$(grep -qx 'pg_dump_exit=0' "$STUB_MARKER_BODY" && echo 1 || echo 0)"
check "marker records the saved-trades exclusion" \
    "$(grep -qx 'saved_trades_excluded=true' "$STUB_MARKER_BODY" && echo 1 || echo 0)"

echo "2. pg_dump fails, gzip and upload succeed (the 2026-10-20 shape)"
STUB_FAIL_PG_DUMP=1 STUB_FAIL_GZIP=0 STUB_FAIL_ARCHIVE_UPLOAD=0 STUB_FAIL_MARKER_UPLOAD=0 \
    run_backup
check "exits non-zero" "$([ "$RUN_EXIT" -ne 0 ] && echo 1 || echo 0)"
check "truncated archive may reach S3" "$(uploaded_archive)"
check "NO marker is written" "$([ "$(uploaded_marker)" = "0" ] && echo 1 || echo 0)"
check "names the invalid object in the error" \
    "$(grep -q 'is NOT a valid backup' "$WORK/stderr.txt" && echo 1 || echo 0)"

echo "3. gzip fails"
STUB_FAIL_PG_DUMP=0 STUB_FAIL_GZIP=1 STUB_FAIL_ARCHIVE_UPLOAD=0 STUB_FAIL_MARKER_UPLOAD=0 \
    run_backup
check "exits non-zero" "$([ "$RUN_EXIT" -ne 0 ] && echo 1 || echo 0)"
check "not vacuous: the pipeline reached the upload" "$(uploaded_archive)"
check "NO marker is written" "$([ "$(uploaded_marker)" = "0" ] && echo 1 || echo 0)"

echo "4. archive upload fails"
STUB_FAIL_PG_DUMP=0 STUB_FAIL_GZIP=0 STUB_FAIL_ARCHIVE_UPLOAD=1 STUB_FAIL_MARKER_UPLOAD=0 \
    run_backup
check "exits non-zero" "$([ "$RUN_EXIT" -ne 0 ] && echo 1 || echo 0)"
check "not vacuous: the pipeline reached the upload" "$(uploaded_archive)"
check "NO marker is written" "$([ "$(uploaded_marker)" = "0" ] && echo 1 || echo 0)"

echo "5. marker upload fails"
STUB_FAIL_PG_DUMP=0 STUB_FAIL_GZIP=0 STUB_FAIL_ARCHIVE_UPLOAD=0 STUB_FAIL_MARKER_UPLOAD=1 \
    run_backup
check "run fails: an uncertifiable archive is not a backup" \
    "$([ "$RUN_EXIT" -ne 0 ] && echo 1 || echo 0)"
check "not vacuous: the pipeline reached the upload" "$(uploaded_archive)"
check "does not print Done." \
    "$(grep -q 'Done.' "$WORK/stdout.txt" && echo 0 || echo 1)"

echo "6. two runs starting in the SAME second get different keys"
# A frozen clock is the only way to force the collision the random suffix guards
# against: same second -> same key -> a failing run could overwrite an archive whose
# .OK already certifies it.
cat > "$STUBS/date" <<'STUB'
#!/bin/bash
case "$*" in
    *%Y-%m-%dT*) echo "2026-10-20T14:31:20Z" ;;
    *) echo "2026/10/20/backup-14-31-20" ;;
esac
STUB
chmod +x "$STUBS/date"
STUB_FAIL_PG_DUMP=0 STUB_FAIL_GZIP=0 STUB_FAIL_ARCHIVE_UPLOAD=0 STUB_FAIL_MARKER_UPLOAD=0 \
    run_backup
KEY_ONE="$(archive_key)"
STUB_FAIL_PG_DUMP=0 STUB_FAIL_GZIP=0 STUB_FAIL_ARCHIVE_UPLOAD=0 STUB_FAIL_MARKER_UPLOAD=0 \
    run_backup
KEY_TWO="$(archive_key)"
rm -f "$STUBS/date"
check "frozen clock still yields the dated prefix" \
    "$(echo "$KEY_ONE" | grep -qE '^2026/10/20/backup-14-31-20-[0-9a-f]{8}\.sql\.gz$' && echo 1 || echo 0)"
check "two same-second runs do not share a key" \
    "$([ -n "$KEY_ONE" ] && [ "$KEY_ONE" != "$KEY_TWO" ] && echo 1 || echo 0)"

echo "7. static: no bash-only syntax on the path production executes"
# Alpine runs this with BusyBox ash and has no bash installed, so arrays and
# PIPESTATUS do not merely misbehave there -- they fail to PARSE, and no backup
# happens at all. The static checks read CODE, never the comments that explain the ban.
code_only() {
    grep -v '^[[:space:]]*#' "$HERE/backup.sh"
}
check "no PIPESTATUS" \
    "$(code_only | grep -q 'PIPESTATUS' && echo 0 || echo 1)"
check "no array assignment" \
    "$(code_only | grep -qE '[A-Za-z_][A-Za-z0-9_]*=\(' && echo 0 || echo 1)"
check "no bash substring expansion" \
    "$(code_only | grep -qE '[$][{][@#]?[A-Za-z_@][A-Za-z0-9_]*:[0-9]' && echo 0 || echo 1)"
check "no &> redirect" \
    "$(code_only | grep -q '&>' && echo 0 || echo 1)"
check "shebang declares sh, not bash" \
    "$(head -1 "$HERE/backup.sh" | grep -qx '#!/bin/sh' && echo 1 || echo 0)"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
