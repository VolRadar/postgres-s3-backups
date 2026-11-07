#!/bin/sh
# Interpreter contract: BUSYBOX ASH, the /bin/sh of the Alpine image this runs in.
# Not bash -- the image installs only postgresql-client and aws-cli, and the Dockerfile
# ENTRYPOINT is [ "sh", "backup.sh" ], so the shebang never selects the interpreter and
# bashisms (arrays, PIPESTATUS, ${var:offset}) fail to PARSE: the backup dies before
# uploading anything, on every scheduled run.
# Not generic POSIX sh either: `set -o pipefail` below is required by the completion
# contract and dash does not have it. Keep every other construct to what both BusyBox
# and POSIX accept, so the only non-portable thing here is the one we chose on purpose.

set -o errexit -o nounset -o pipefail

export AWS_PAGER=""

# Key of the archive this run writes, shared by the upload and its completion marker.
BACKUP_KEY=""

s3() {
    aws s3 --region "$AWS_REGION" "$@"
}

s3api() {
    s3api_cmd="$1"
    shift
    aws s3api "$s3api_cmd" --region "$AWS_REGION" --bucket "$S3_BUCKET_NAME" "$@"
}

bucket_exists() {
    s3 ls "$S3_BUCKET_NAME" > /dev/null 2>&1
}

create_bucket() {
    echo "Bucket $S3_BUCKET_NAME doesn't exist. Creating it now..."

    # create bucket
    s3api create-bucket \
        --create-bucket-configuration LocationConstraint="$AWS_REGION" \
        --object-ownership BucketOwnerEnforced

    # block public access
    s3api put-public-access-block \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    # enable versioning for objects in the bucket
    s3api put-bucket-versioning --versioning-configuration Status=Enabled

    # encrypt objects in the bucket
    s3api put-bucket-encryption \
      --server-side-encryption-configuration \
      '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}'
}

ensure_bucket_exists() {
    if bucket_exists; then
        return
    fi
    create_bucket
}

# VolRadar: the saved-trades subsystem (migration 109) runs FORCE ROW LEVEL SECURITY,
# which subjects the table OWNER to RLS as well. pg_dump connects as that owner and runs
# with row_security=off, so it fails closed rather than dumping a filtered subset.
# It cannot be dumped, by design. Do NOT "fix" this with --enable-row-security: that
# exits 0 having written ZERO rows for these tables, i.e. a green backup with no data.
# The schema is excluded too: its policies and SECURITY DEFINER functions reference the
# vr_saved_* roles, which pg_dump never emits (roles are cluster-level), so a dump
# containing them would halt a psql restore run with ON_ERROR_STOP=1.
# Disaster recovery for this subsystem = re-apply migration 109 (self-contained) and
# provision the role passwords out of band. See docs/ops/DB-BACKUP-RUNBOOK.md.
# Tables are listed EXPLICITLY, not user_saved_trade_*: a future FORCE-RLS table must
# break this backup loudly instead of being dropped from it silently.
pg_dump_database() {
    pg_dump  --no-owner --no-privileges --clean --if-exists --quote-all-identifiers \
        --exclude-schema='saved_trades_20261019' \
        --exclude-table='public.user_saved_trade_ideas' \
        --exclude-table='public.user_saved_trade_operations' \
        --exclude-table='public.user_saved_trade_deleted_owners' \
        --exclude-table='public.user_saved_trade_maintenance' \
        --exclude-table='public.premium_logged_entries' \
        "$DATABASE_URL"
}

upload_to_bucket() {
    # if the zipped backup file is larger than 50 GB add the --expected-size option
    # see https://docs.aws.amazon.com/cli/latest/reference/s3/cp.html
    s3 cp - "s3://$S3_BUCKET_NAME/$BACKUP_KEY"
}

# VolRadar: a .sql.gz object on its own is NOT a backup.
# The upload is a stream (pg_dump | gzip | aws s3 cp -). When pg_dump dies mid-dump,
# gzip closes the partial stream cleanly and the upload still completes, so S3 ends up
# holding a truncated object of a plausible size. On 2026-10-20 two failed runs left
# 1.7 GB objects next to the 1.7 GB good one; neither size nor `gunzip -t` can tell
# them apart (gzip accepts a truncated-but-closed stream).
# So completion is recorded OUT OF BAND: this marker is written only after all three
# pipeline stages returned 0. An archive without its matching .OK sibling is not a
# backup and must never be restored from.
# The marker asserts ONLY that the dump pipeline completed and uploaded. It is NOT
# evidence that the dump restores — a full scratch restore stays a separate DR test.
upload_completion_marker() {
    {
        echo "status=complete"
        echo "backup=$BACKUP_KEY"
        echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "pg_dump_exit=$1"
        echo "saved_trades_excluded=true"
    } | s3 cp - "s3://$S3_BUCKET_NAME/$BACKUP_KEY.OK"
}

main() {
    ensure_bucket_exists

    # Fix the key once: the marker must name the archive it certifies, and a second
    # date call at upload time can land in the next second (or the next day at 23:59:59).
    # The random suffix is a collision guard, not decoration: two runs starting in the
    # same second would otherwise share a key, and a failing run could overwrite an
    # archive whose .OK marker already certifies it -- exactly the truncated-but-trusted
    # dump this marker exists to prevent (a scheduled run and a manual trigger can race).
    BACKUP_KEY="$(date +%Y/%m/%d/backup-%H-%M-%S)-$(od -An -N4 -tx1 /dev/urandom | tr -d '[:space:]').sql.gz"

    echo "Taking backup and uploading it to S3..."
    echo "WARNING: Saved Trades excluded from this logical backup (FORCE RLS); covered by Render PITR only" >&2

    # errexit is lifted only around the pipeline so its status can be inspected and
    # reported instead of killing the script silently. Under pipefail -- already set
    # above, and BusyBox supports it (the 2026-10-20 failures exited 1 through it) --
    # a zero status proves EVERY stage returned zero, which is what the marker asserts.
    set +o errexit
    pg_dump_database | gzip | upload_to_bucket
    pipeline_status=$?
    set -o errexit

    if [ "$pipeline_status" -ne 0 ]; then
        echo "ERROR: backup pipeline failed (exit $pipeline_status); the failing stage reported above." >&2
        echo "ERROR: no completion marker written. s3://$S3_BUCKET_NAME/$BACKUP_KEY is NOT a valid backup." >&2
        exit 1
    fi

    # A marker that cannot be written leaves an uncertifiable archive, so the run fails.
    upload_completion_marker "$pipeline_status"

    echo "Done."
}

main
