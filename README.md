# Zaris vs Redis — reproducible throughput benchmarks

This repository contains **everything needed to reproduce** the Zaris performance numbers published on
[clustron.io](https://clustron.io): the load generators, the orchestration scripts, the exact workloads,
and the raw results. Nothing here is a projection — every published number is measured, and every number
in [`results/`](results/) was produced by the scripts in [`scripts/`](scripts/).

We publish this so you don't have to take our word for it. Run it yourself.

## What is measured

The full matrix is **{ Redis, Zaris (RESP API), Zaris (native API) } × { 1, 2, 3 nodes } × { 4-core, 8-core nodes }**.

- **Workload:** 100-byte values, **50 % SET / 50 % GET**, uniformly random keys over a 2,000,000-key space.
- **Redis** and **Zaris RESP** are driven by [`memtier_benchmark`](https://github.com/RedisLabs/memtier_benchmark)
  (the standard Redis load tool) over the Redis wire protocol, pipelined.
- **Zaris native** is driven by [`NativeBench`](src/NativeBench) over the Zaris binary protocol, in a
  **mixed 1:1** mode that matches the memtier workload exactly.

## Methodology — how we find the real number

The single rule: **a published number is the throughput at which the *server* saturates**, not the client.

1. **Scale the load until the server flattens.** For each cell we increase offered load (connections,
   pipeline depth, and client machines) until aggregate throughput stops rising. We record the peak.
2. **Verify server saturation.** Every recorded peak is taken with the loaded node(s) at **≥ 88 % CPU**
   (most are 97-99 %), sampled with `mpstat` *on the node, during the run*. If we cannot push a node past
   88 %, the number is explicitly flagged **CLIENT-BOUND** — we never report a client-limited number as a
   server maximum.
3. **Clusters are measured pinned-per-owner.** For multi-node runs we drive **one load generator per node**,
   each sending keys that node owns (hash-tagged to that node's slots, so they are served locally with no
   cross-node redirect), and sum the result. This measures the cluster's aggregate serving capacity with
   ideal key distribution, and it is **identical for Zaris and Redis** — both honor Redis hash-tags and both
   emit `MOVED` for owner discovery. (We found `memtier --cluster-mode` distributes poorly against both
   engines on small clusters and under-reports; pinned-per-owner is the honest, apples-to-apples method.)
4. **CPU and memory are recorded for every cell** (`results/matrix.tsv`), because throughput without its
   resource cost is only half the story.

## Hardware

- **Cloud:** Microsoft Azure, single region, all VMs in one **proximity placement group** on one VNet
  (so client↔server and node↔node latency is minimal and traffic never leaves the VNet).
- **Node VMs:** `Standard_F4als_v6` (4 vCPU / 8 GB) and `Standard_F8als_v6` (8 vCPU / 16 GB) — AMD,
  compute-optimized, current generation.
- **Client VMs:** `Standard_F16als_v6` (16 vCPU / 32 GB), up to three, so the client side always has
  spare capacity to prove the server is the bottleneck.
- **OS:** Ubuntu 22.04, Docker. Containers run with `--network host` (no NAT overhead).

## Engines & fairness

- **Zaris:** one node = one process that uses **all cores** of the box. Replication factor 1 (no replica
  overhead) for the throughput runs.
- **Redis:** given its **best single-instance multi-core configuration** — `io-threads` = core count,
  `io-threads-do-reads yes`, persistence off. Multi-node runs use Redis Cluster. We deliberately steelman
  Redis; command execution in Redis is single-threaded per node by design, which is the point the core-count
  scaling makes.

## Reproduce it

```bash
# 1. provision (edit the SKUs/region if you like)
scripts/provision-azure.sh
# 2. put the host IPs it prints into scripts/common.sh
# 3. run a full matrix at a given node size
BENCH_KEY=~/.ssh/your_key scripts/run-matrix.sh 4     # 4-core nodes
BENCH_KEY=~/.ssh/your_key scripts/run-matrix.sh 8     # 8-core nodes
# 4. results land in results/matrix.tsv ; tear down
scripts/teardown-azure.sh
```

Run a single cell directly (e.g. Zaris RESP, 3 nodes, pinned):

```bash
scripts/deploy-zaris.sh 3 resp
scripts/sweep-pinned.sh zaris-resp-4core 3
```

The exact memtier invocation (what actually generates the Redis-protocol load):

```bash
docker run --rm --network host redislabs/memtier_benchmark \
  -s <node-ip> -p 6379 --data-size=100 --ratio=1:1 --key-pattern=R:R \
  --threads=8 --clients=50 --pipeline=64 --test-time=18 --hide-histogram
```

## Results

See [`results/matrix.tsv`](results/matrix.tsv) for the raw matrix (peak ops/sec, the load point that
produced it, per-node CPU%/memory, and the server-bound flag) and [`results/`](results/) for the full
per-run logs. The headline summary is on <https://clustron.io/benchmarks>.

## License

Benchmark scripts and `NativeBench`: MIT (see [`LICENSE`](LICENSE)). Zaris itself is governed by its own
license. `memtier_benchmark`, `redis`, and the Zaris node image are the property of their respective owners.
