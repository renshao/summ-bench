use hdrhistogram::Histogram;
use serde::Serialize;

use crate::report::PullSample;

#[derive(Debug, Serialize)]
pub struct Aggregator {
    pub total_pulls: usize,
    pub successful: usize,
    pub failed: usize,
    pub total_bytes: u64,
    pub duration_ms: PercentileSet,
    pub mb_per_sec: PercentileSet,
}

#[derive(Debug, Serialize)]
pub struct PercentileSet {
    pub min: f64,
    pub p50: f64,
    pub p90: f64,
    pub p95: f64,
    pub p99: f64,
    pub max: f64,
    pub mean: f64,
}

impl Aggregator {
    pub fn from_samples(samples: &[PullSample]) -> Self {
        let ok: Vec<&PullSample> = samples.iter().filter(|s| s.ok).collect();
        let total_bytes: u64 = ok.iter().map(|s| s.bytes).sum();
        let duration_ms = percentiles_f64(ok.iter().map(|s| s.duration_ms));
        let mb_per_sec = percentiles_f64(ok.iter().map(|s| s.mb_per_sec()));

        Self {
            total_pulls: samples.len(),
            successful: ok.len(),
            failed: samples.len() - ok.len(),
            total_bytes,
            duration_ms,
            mb_per_sec,
        }
    }
}

fn percentiles_f64<I>(iter: I) -> PercentileSet
where
    I: IntoIterator<Item = f64>,
{
    // hdrhistogram works on integers — scale by 1000 to keep 3 decimals.
    let values: Vec<f64> = iter.into_iter().filter(|v| v.is_finite()).collect();
    if values.is_empty() {
        return PercentileSet {
            min: 0.0,
            p50: 0.0,
            p90: 0.0,
            p95: 0.0,
            p99: 0.0,
            max: 0.0,
            mean: 0.0,
        };
    }

    let mut hist = Histogram::<u64>::new(3).expect("hist new");
    for v in &values {
        let scaled = (v.max(0.0) * 1000.0) as u64;
        let scaled = scaled.max(1);
        hist.record(scaled).ok();
    }

    let scale = 1000.0_f64;
    let sum: f64 = values.iter().sum();
    PercentileSet {
        min: values.iter().cloned().fold(f64::INFINITY, f64::min),
        p50: hist.value_at_quantile(0.50) as f64 / scale,
        p90: hist.value_at_quantile(0.90) as f64 / scale,
        p95: hist.value_at_quantile(0.95) as f64 / scale,
        p99: hist.value_at_quantile(0.99) as f64 / scale,
        max: values.iter().cloned().fold(f64::NEG_INFINITY, f64::max),
        mean: sum / values.len() as f64,
    }
}
