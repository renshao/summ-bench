use chrono::{DateTime, Utc};
use serde::Serialize;

use crate::metrics::Aggregator;

#[derive(Debug, Serialize)]
pub struct PullSample {
    pub repo: String,
    pub tag: String,
    pub ok: bool,
    pub duration_ms: f64,
    pub bytes: u64,
    pub blob_count: usize,
    pub error: Option<String>,
}

impl PullSample {
    pub fn ok(repo: String, tag: String, duration_ms: f64, bytes: u64, blob_count: usize) -> Self {
        Self {
            repo,
            tag,
            ok: true,
            duration_ms,
            bytes,
            blob_count,
            error: None,
        }
    }

    pub fn failed(repo: String, tag: String, error: String) -> Self {
        Self {
            repo,
            tag,
            ok: false,
            duration_ms: 0.0,
            bytes: 0,
            blob_count: 0,
            error: Some(error),
        }
    }

    pub fn mb_per_sec(&self) -> f64 {
        if self.duration_ms <= 0.0 {
            return 0.0;
        }
        let mb = (self.bytes as f64) / 1_048_576.0;
        let sec = self.duration_ms / 1000.0;
        mb / sec
    }
}

#[derive(Debug, Serialize)]
pub struct Report {
    pub scenario: String,
    pub target: String,
    pub started_at: DateTime<Utc>,
    pub finished_at: DateTime<Utc>,
    pub wall_clock_seconds: f64,
    pub concurrency: usize,
    pub blob_concurrency: usize,
    pub iterations: usize,
    pub aggregates: Aggregator,
    pub samples: Vec<PullSample>,
}

impl Report {
    pub fn print_summary(&self) {
        let a = &self.aggregates;
        let mb_total = (a.total_bytes as f64) / 1_048_576.0;
        let throughput = if self.wall_clock_seconds > 0.0 {
            mb_total / self.wall_clock_seconds
        } else {
            0.0
        };
        println!("================ load test summary ================");
        println!("scenario:           {}", self.scenario);
        println!("target:             {}", self.target);
        println!("concurrency:        {} pulls (blob fanout {})", self.concurrency, self.blob_concurrency);
        println!("iterations/image:   {}", self.iterations);
        println!("wall clock:         {:.1}s", self.wall_clock_seconds);
        println!("pulls (ok/fail):    {}/{}", a.successful, a.failed);
        println!("data transferred:   {:.1} MB", mb_total);
        println!("aggregate rate:     {:.1} MB/s", throughput);
        println!();
        println!("per-pull duration (ms):");
        println!(
            "  min {:.1}  p50 {:.1}  p90 {:.1}  p95 {:.1}  p99 {:.1}  max {:.1}  mean {:.1}",
            a.duration_ms.min,
            a.duration_ms.p50,
            a.duration_ms.p90,
            a.duration_ms.p95,
            a.duration_ms.p99,
            a.duration_ms.max,
            a.duration_ms.mean
        );
        println!("per-pull throughput (MB/s):");
        println!(
            "  min {:.1}  p50 {:.1}  p90 {:.1}  p95 {:.1}  p99 {:.1}  max {:.1}  mean {:.1}",
            a.mb_per_sec.min,
            a.mb_per_sec.p50,
            a.mb_per_sec.p90,
            a.mb_per_sec.p95,
            a.mb_per_sec.p99,
            a.mb_per_sec.max,
            a.mb_per_sec.mean
        );
        println!("===================================================");
    }
}
