# NativeBench

A small throughput benchmark for the **Zaris native binary protocol**, so native-API numbers are measured
the same way (and against the same workload) as the Redis-protocol numbers.

- `--mode mixed` — 50 % SET / 50 % GET interleaved over a random keyspace (matches `memtier --ratio=1:1`).
  This is the mode used for the published native-vs-RESP comparison.
- `--mode phased` (default) — a SET phase then a GET phase, reported separately.

```bash
dotnet run -c Release -- \
  --conn "zaris://<node-ip>:7861/bench" --mode mixed \
  --keyspace 1000000 --ops 4000000 --concurrency 2048 --data 100 --ttl 0
```

Build a self-contained binary (what the orchestration scripts ship to the client VMs):

```bash
dotnet publish -c Release -r linux-x64 --self-contained true -p:PublishSingleFile=true -o ./out
```

Depends on [`Clustron.Zaris.Client`](https://www.nuget.org/packages/Clustron.Zaris.Client) (nuget.org).
