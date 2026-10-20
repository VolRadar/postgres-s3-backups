#!/bin/bash

set -o errexit -o nounset -o pipefail

export AWS_PAGER=""

s3() {
    aws s3 --region "$AWS_REGION" "$@"
}

s3api() {
    aws s3api "$1" --region "$AWS_REGION" --bucket "$S3_BUCKET_NAME" "${@:2}"
}

bucket_exists() {
    s3 ls "$S3_BUCKET_NAME" &> /dev/null
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
        "$DATABASE_URL"
}

upload_to_bucket() {
    # if the zipped backup file is larger than 50 GB add the --expected-size option
    # see https://docs.aws.amazon.com/cli/latest/reference/s3/cp.html
    s3 cp - "s3://$S3_BUCKET_NAME/$(date +%Y/%m/%d/backup-%H-%M-%S.sql.gz)"
}

main() {
    ensure_bucket_exists
    echo "Taking backup and uploading it to S3..."
    echo "WARNING: Saved Trades excluded from this logical backup (FORCE RLS); covered by Render PITR only" >&2
    pg_dump_database | gzip | upload_to_bucket
    echo "Done."
}

main
