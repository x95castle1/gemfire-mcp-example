# 07: An S3 telemetry store (SeaweedFS)

```bash
make start      # now also starts seaweedfs + s3-init (creates the bucket)
make seaweed    # browse http://localhost:8888/buckets/gemfire-telemetry/gfmcp/
make logs S=telemetry-forwarder   # "Store s3://gemfire-telemetry/gfmcp (... path-style) ready"
```

Chunk 3 used `file:///telemetry-store`, a shared folder. This chunk swaps it for an S3 bucket, which is how you'd run this for real (AWS S3 or any S3-compatible store). **Nothing else changed**: not the cluster, not the MCP tools, not the store layout.

## What changed

```
before:  forwarder ──writes──▶ ./data/telemetry-store ◀──reads (:ro)── mcp-server
after:   forwarder ──PUT─────▶ s3://gemfire-telemetry/gfmcp ◀──GET/LIST── mcp-server
                                  (SeaweedFS on :8333)
```

Both sides get identical settings from one YAML anchor in `compose.yaml`, which makes the contract between them explicit:

```yaml
x-telemetry-store: &telemetry-store
  GF_TELEMETRY_STORE: s3://gemfire-telemetry/gfmcp   # bucket + per-cluster prefix
  GF_S3_ENDPOINT: http://seaweedfs:8333              # unset = real AWS S3
  GF_S3_ACCESS_KEY: admin
  GF_S3_SECRET_KEY: admin
```

| Piece | What it does |
|---|---|
| `seaweedfs` | One container: master + volume server + filer + S3 gateway. S3 on `:8333`, file browser on `:8888`. User `admin`/`admin` in `seaweedfs/s3.json` (lab only) |
| `s3-init` | One-shot `aws` CLI: creates the `gemfire-telemetry` bucket if it's missing. The forwarder doesn't create buckets |
| `/gfmcp` prefix | One prefix per cluster. The docs warn that two clusters sharing a location get their data mixed. Runner mode (chunk 8) can use `/runner` in the same bucket |

Notes:
- **Path-style is automatic.** Setting `GF_S3_ENDPOINT` makes both sides use `http://seaweedfs:8333/gemfire-telemetry/...` instead of `http://gemfire-telemetry.seaweedfs:8333/...`. Both log `path-style` at startup.
- **The MCP server checks the store at startup.** It refuses to start if it can't reach the store, which is why it `depends_on` `s3-init` finishing. Startup log: `Telemetry store has data for 4 member(s)`.
- **Same layout, now as object keys:** `gfmcp/server-1/stats/live/server-1.gfs.gz`, `gfmcp/server-1/logs/2026/11/23/20/<gen>-<from>-<to>.log.gz`, … (see [docs/03](03-telemetry.md)).

Listing objects with the AWS CLI (no install needed):

```bash
docker run --rm --network gfmcp -e AWS_ACCESS_KEY_ID=admin -e AWS_SECRET_ACCESS_KEY=admin \
  -e AWS_DEFAULT_REGION=us-east-1 amazon/aws-cli --endpoint-url http://seaweedfs:8333 \
  s3 ls --recursive s3://gemfire-telemetry/gfmcp/
```

## The bug we hit: "Not in GZIP format"

On SeaweedFS **4.01**, everything looked fine (objects uploaded, the right keys, `uploadFailures=0`), but every MCP history tool failed:

```
query_stat → isError: Failed to download server-1/stats/live/server-1.gfs.gz: Not in GZIP format
```

Downloading an object showed why. Instead of starting with gzip's magic bytes `1f 8b`, it started with:

```
e3e3;chunk-signature=b249985d...\r\n  <gzip bytes>  ... x-amz-trailer-signature:3c1a...\r\n
```

That's the **aws-chunked upload wrapper**. Recent AWS SDKs (the forwarder uses AWS SDK for Java 2.x) attach a CRC checksum as a *trailer* to every upload by default. SeaweedFS 4.01 didn't understand that trailer format, so it stored the wrapper *as the object's content*. **SeaweedFS 4.55** handles it, so we pinned that version.

Lessons:
- **"S3-compatible" is a spectrum.** Test the real read/write path, not just "the upload said OK".
- If you're stuck on an older S3-compatible store, the AWS SDK has an official switch: `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` (set it on the forwarder).
- The MCP server surfaced it well: `isError` with the exact object key, and `assess_cluster_health` said `its stats could not be read; the server log has the details` instead of making up a status.

## Why there's no least privilege here

In a real deployment, give each side its own credentials:

| Identity | Needs |
|---|---|
| forwarder | `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` |
| mcp-server | `s3:GetObject`, `s3:ListBucket` only |

This lab uses one `admin`/`admin` user on purpose, to keep it simple. In SeaweedFS, splitting it is just more entries in `seaweedfs/s3.json` with actions such as `"Read:gemfire-telemetry"`, `"List:gemfire-telemetry"` and `"Write:gemfire-telemetry"`.
