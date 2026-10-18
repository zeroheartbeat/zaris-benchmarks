// Native Zaris throughput benchmark (NO RESP) — phased SET then GET, concurrent, latency percentiles.
// Directly measures the core store write/read ceiling via the native client, for apples-to-apples
// comparison with the RESP RespBench numbers. Usage:
//   NativeBench --conn "zaris://127.0.0.1:17002/localresp" --ops 100000 --concurrency 64 --data 100 --ttl 60
using System.Diagnostics;
using Clustron.Zaris.Abstractions;
using Clustron.Zaris.Client;

static string Arg(string[] a, string n, string d) { for (int i = 0; i < a.Length - 1; i++) if (a[i] == n) return a[i + 1]; return d; }

var conn = Arg(args, "--conn", "zaris://127.0.0.1:17002/localresp");
var ops = int.Parse(Arg(args, "--ops", "100000"));
var conc = int.Parse(Arg(args, "--concurrency", "64"));
var dataSize = int.Parse(Arg(args, "--data", "100"));
var ttl = int.Parse(Arg(args, "--ttl", "60"));
var label = Arg(args, "--label", "native");
var mode = Arg(args, "--mode", "phased");          // phased = SET phase then GET phase; mixed = 50/50 interleaved (matches memtier --ratio 1:1)
var keyspace = int.Parse(Arg(args, "--keyspace", "1000000"));

Console.WriteLine($"=== NativeBench [{label}] conn={conn} ops={ops} conc={conc} data={dataSize} ttl={ttl}s ===");
var client = (IZaris)await ZarisClient.ConnectAsync(conn);
Console.WriteLine("connected.");

var value = new byte[dataSize]; new Random(7).NextBytes(value);
var putOpts = ttl > 0 ? new PutOptions { Metadata = new EntryMetadata { Ttl = TimeSpan.FromSeconds(ttl) } } : null;
string Key(int i) => $"nb:{i}";

double TicksMs(long t) => t * 1000.0 / Stopwatch.Frequency;
static double Pct(List<double> xs, double p) { if (xs.Count == 0) return 0; xs.Sort(); int i = (int)Math.Ceiling(p / 100 * xs.Count) - 1; return xs[Math.Clamp(i, 0, xs.Count - 1)]; }

async Task<(double ops, double p50, double p99, long fail)> Phase(string name, Func<int, ValueTask<bool>> op)
{
    var lat = new List<double>(ops); var latLock = new object(); long fail = 0; int next = -1;
    var sw = Stopwatch.StartNew();
    var workers = new Task[conc];
    for (int w = 0; w < conc; w++) workers[w] = Task.Run(async () =>
    {
        while (true)
        {
            int i = Interlocked.Increment(ref next); if (i >= ops) return;
            long t0 = Stopwatch.GetTimestamp();
            bool ok; try { ok = await op(i).ConfigureAwait(false); } catch { ok = false; }
            double ms = TicksMs(Stopwatch.GetTimestamp() - t0);
            if (!ok) Interlocked.Increment(ref fail);
            lock (latLock) lat.Add(ms);
        }
    });
    await Task.WhenAll(workers); sw.Stop();
    double ps = ops / sw.Elapsed.TotalSeconds;
    Console.WriteLine($"--- {name} ---  {ps:N0} ops/sec  p50={Pct(lat, 50):F3}ms p99={Pct(lat, 99):F3}ms  fail={fail}");
    return (ps, Pct(lat, 50), Pct(lat, 99), fail);
}

if (mode == "mixed")
{
    // Populate the keyspace so GETs hit, then run a 50/50 SET:GET interleave over random keys —
    // the same workload as memtier --ratio=1:1 --key-pattern=R:R, so the native number is directly
    // comparable to the RESP/Redis mixed throughput.
    Console.WriteLine($"populating {keyspace} keys...");
    await Phase("POPULATE", async i => (await client.PutAsync<byte[]>(Key(i % keyspace), value, putOpts).ConfigureAwait(false)).IsSuccess);
    var mix = await Phase("MIX(1:1)", async i =>
    {
        var rnd = (uint)(i * 2654435761u);            // cheap per-op deterministic hash
        int k = (int)(rnd % (uint)keyspace);
        if ((rnd & 1) == 0)
            return (await client.PutAsync<byte[]>(Key(k), value, putOpts).ConfigureAwait(false)).IsSuccess;
        return (await client.GetAsync<byte[]>(Key(k), null).ConfigureAwait(false)).IsSuccess;
    });
    Console.WriteLine($"SUMMARY  MIX {mix.ops:N0} ops/sec  p50={mix.p50:F3}ms p99={mix.p99:F3}ms");
    return 0;
}

// warmup
for (int i = 0; i < Math.Min(ops, 2000); i++) await client.PutAsync<byte[]>(Key(i), value, putOpts);

var set = await Phase("SET", async i => (await client.PutAsync<byte[]>(Key(i), value, putOpts).ConfigureAwait(false)).IsSuccess);
var get = await Phase("GET", async i => (await client.GetAsync<byte[]>(Key(i), null).ConfigureAwait(false)).IsSuccess);
Console.WriteLine($"SUMMARY  SET {set.ops:N0} ops/sec  GET {get.ops:N0} ops/sec");
return 0;
