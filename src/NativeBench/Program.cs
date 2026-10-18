// Native Zaris throughput + latency benchmark (NO RESP). The single owner of native load generation for the
// Zaris-vs-Redis/RESP comparison; the RESP/Redis side is memtier. Usage:
//   NativeBench --conn "zaris://HOST:7861/CLUSTER" --mode mixed --keyspace 1000000 --ops 3000000 --concurrency 2048 --data 100 --ttl 0
//
//   --mode phased        SET phase then GET phase over --ops keys (default)
//   --mode mixed         populate --keyspace keys, then a 50/50 SET:GET interleave over random keys — the same
//                        workload as memtier --ratio=1:1 --key-pattern=R:R
//   --concurrency N      in-flight ops per process (N worker loops, each with exactly ONE op outstanding).
//                        --concurrency 1 is the unloaded per-op round trip: the reported mean IS the service time.
//   --connections N      TCP connections this process opens to EACH node (default: the client default = 1).
//                        One connection pins a node's whole stream from this process to one server receive thread.
//   --no-metadata        GET without entry metadata (Redis-comparable: a GET returns only the value).
//   --inline-completions run response continuations on the receive thread (ZARIS_CLIENT_INLINE_COMPLETIONS=1).
//
// SUMMARY line: ops/sec + latency in MICROSECONDS (mean, p50, p99, p999, max) measured per op from issue to
// completion inside this process (so it includes the client library, not just the wire).
using System.Diagnostics;
using Clustron.Zaris.Abstractions;
using Clustron.Zaris.Client;

static string Arg(string[] a, string n, string d) { for (int i = 0; i < a.Length - 1; i++) if (a[i] == n) return a[i + 1]; return d; }
static bool Flag(string[] a, string n) => Array.IndexOf(a, n) >= 0;

var conn = Arg(args, "--conn", "zaris://127.0.0.1:17002/localresp");
var ops = int.Parse(Arg(args, "--ops", "100000"));
var conc = int.Parse(Arg(args, "--concurrency", "64"));
var dataSize = int.Parse(Arg(args, "--data", "100"));
var ttl = int.Parse(Arg(args, "--ttl", "60"));
var label = Arg(args, "--label", "native");
var mode = Arg(args, "--mode", "phased");
var keyspace = int.Parse(Arg(args, "--keyspace", "1000000"));
var connections = int.Parse(Arg(args, "--connections", "0"));
var noMetadata = Flag(args, "--no-metadata");
if (Flag(args, "--inline-completions")) Environment.SetEnvironmentVariable("ZARIS_CLIENT_INLINE_COMPLETIONS", "1");

Console.WriteLine($"=== NativeBench [{label}] conn={conn} mode={mode} ops={ops} conc={conc} connections={(connections > 0 ? connections : "default")} data={dataSize} ttl={ttl}s metadata={!noMetadata} ===");
var client = (IZaris)await ZarisClient.ConnectAsync(conn, o => { if (connections > 0) o.ConnectionsPerNode = connections; });
Console.WriteLine("connected.");

var value = new byte[dataSize]; new Random(7).NextBytes(value);
var putOpts = ttl > 0 ? new PutOptions { Metadata = new EntryMetadata { Ttl = TimeSpan.FromSeconds(ttl) } } : null;
var getOpts = noMetadata ? new GetOptions { IncludeMetadata = false } : null;

// Keys are pre-built once: a per-op string allocation + format in the generator would be bench overhead, not Zaris.
int keyCount = mode == "mixed" ? keyspace : ops;
var keys = new string[keyCount];
for (int i = 0; i < keyCount; i++) keys[i] = "nb:" + i;

double usPerTick = 1_000_000.0 / Stopwatch.Frequency;

static (double mean, double p50, double p99, double p999, double max) Stats(Lat[] lats, double usPerTick)
{
    int n = 0; foreach (var l in lats) n += l.Count;
    if (n == 0) return default;
    var all = new long[n]; int o = 0;
    foreach (var l in lats) { Array.Copy(l.Ticks, 0, all, o, l.Count); o += l.Count; }
    Array.Sort(all);
    double sum = 0; foreach (var t in all) sum += t;
    long P(double p) => all[Math.Clamp((int)Math.Ceiling(p * n) - 1, 0, n - 1)];
    return (sum / n * usPerTick, P(0.50) * usPerTick, P(0.99) * usPerTick, P(0.999) * usPerTick, all[n - 1] * usPerTick);
}

// Runs `ops` operations with `conc` worker loops; opKind: 0 = put key[i], 1 = get key[i], 2 = mixed over the keyspace.
async Task<(double ops, double mean, double p50, double p99, double p999, double max, long fail)> Phase(string name, int opKind)
{
    long fail = 0; int next = -1;
    var lats = new Lat[conc];
    long alloc0 = GC.GetTotalAllocatedBytes(precise: true);
    int gc0 = GC.CollectionCount(0), gc1 = GC.CollectionCount(1), gc2 = GC.CollectionCount(2);
    var sw = Stopwatch.StartNew();
    var workers = new Task[conc];
    for (int w = 0; w < conc; w++)
    {
        var lat = lats[w] = new Lat();
        workers[w] = Task.Run(async () =>
        {
            while (true)
            {
                int i = Interlocked.Increment(ref next); if (i >= ops) return;
                bool ok;
                long t0 = Stopwatch.GetTimestamp();
                try
                {
                    if (opKind == 0)
                        ok = (await client.PutAsync<byte[]>(keys[i], value, putOpts).ConfigureAwait(false)).IsSuccess;
                    else if (opKind == 1)
                        ok = (await client.GetAsync<byte[]>(keys[i], getOpts).ConfigureAwait(false)).IsSuccess;
                    else
                    {
                        var rnd = (uint)(i * 2654435761u);            // cheap per-op deterministic hash
                        int k = (int)(rnd % (uint)keyspace);
                        ok = (rnd & 1) == 0
                            ? (await client.PutAsync<byte[]>(keys[k], value, putOpts).ConfigureAwait(false)).IsSuccess
                            : (await client.GetAsync<byte[]>(keys[k], getOpts).ConfigureAwait(false)).IsSuccess;
                    }
                }
                catch { ok = false; }
                lat.Add(Stopwatch.GetTimestamp() - t0);
                if (!ok) Interlocked.Increment(ref fail);
            }
        });
    }
    await Task.WhenAll(workers); sw.Stop();
    double ps = ops / sw.Elapsed.TotalSeconds;
    var s = Stats(lats, usPerTick);
    long allocPerOp = (GC.GetTotalAllocatedBytes(precise: true) - alloc0) / Math.Max(1, ops);
    Console.WriteLine($"--- {name} ---  {ps:N0} ops/sec  mean={s.mean:F1}us p50={s.p50:F1}us p99={s.p99:F1}us p999={s.p999:F1}us max={s.max:F0}us  fail={fail}  alloc/op={allocPerOp}B gc0/1/2=+{GC.CollectionCount(0) - gc0}/+{GC.CollectionCount(1) - gc1}/+{GC.CollectionCount(2) - gc2}");
    return (ps, s.mean, s.p50, s.p99, s.p999, s.max, fail);
}

if (mode == "mixed")
{
    Console.WriteLine($"populating {keyspace} keys...");
    var savedOps = ops; ops = keyspace;
    await Phase("POPULATE", 0);
    ops = savedOps;
    var mix = await Phase("MIX(1:1)", 2);
    Console.WriteLine($"SUMMARY  MIX {mix.ops:N0} ops/sec  mean={mix.mean:F1}us p50={mix.p50:F1}us p99={mix.p99:F1}us p999={mix.p999:F1}us  conc={conc} conns={(connections > 0 ? connections : 1)} fail={mix.fail}");
    return 0;
}

// warmup
for (int i = 0; i < Math.Min(ops, 2000); i++) await client.PutAsync<byte[]>(keys[i], value, putOpts);

var set = await Phase("SET", 0);
var get = await Phase("GET", 1);
Console.WriteLine($"SUMMARY  SET {set.ops:N0} ops/sec mean={set.mean:F1}us p50={set.p50:F1}us p99={set.p99:F1}us  GET {get.ops:N0} ops/sec mean={get.mean:F1}us p50={get.p50:F1}us p99={get.p99:F1}us  conc={conc}");
return 0;

// Per-worker latency buffers (no shared lock on the hot path); merged + sorted once at the end of a phase.
sealed class Lat
{
    public long[] Ticks = new long[1024]; public int Count;
    public void Add(long t) { if (Count == Ticks.Length) Array.Resize(ref Ticks, Ticks.Length * 2); Ticks[Count++] = t; }
}
