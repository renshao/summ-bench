mod client;
mod metrics;
mod report;

use anyhow::{Context, Result};
use clap::Parser;
use futures::stream::{self, StreamExt};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

use crate::client::RegistryClient;
use crate::metrics::Aggregator;
use crate::report::{PullSample, Report};

#[derive(Parser, Debug)]
#[command(name = "loadtest", about = "OCI registry pull load tester")]
struct Args {
    /// Registry base URL, e.g. http://10.20.1.4:5000
    #[arg(long)]
    target: String,

    /// Scenario label recorded in the report (e.g. "fs", "azure")
    #[arg(long)]
    scenario: String,

    /// Number of concurrent image pulls
    #[arg(long, default_value_t = 1)]
    concurrency: usize,

    /// How many times to pull each (repo, tag) sequentially within this run
    #[arg(long, default_value_t = 1)]
    iterations: usize,

    /// Per-image blob fetch concurrency (containerd default is 3)
    #[arg(long, default_value_t = 3)]
    blob_concurrency: usize,

    /// Output JSON report path
    #[arg(long)]
    output: PathBuf,

    /// Optional: only pull repos matching this substring
    #[arg(long)]
    repo_filter: Option<String>,

    /// Optional: cap total pulls (useful for smoke runs)
    #[arg(long)]
    max_pulls: Option<usize>,
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let args = Args::parse();
    let started = chrono::Utc::now();
    let wall_start = Instant::now();

    let client = Arc::new(RegistryClient::new(&args.target)?);

    tracing::info!(target = %args.target, "discovering catalog");
    let catalog = client.catalog().await.context("catalog fetch failed")?;
    tracing::info!(repo_count = catalog.len(), "catalog discovered");

    let mut work: Vec<(String, String)> = Vec::new();
    for repo in &catalog {
        if let Some(filter) = &args.repo_filter {
            if !repo.contains(filter) {
                continue;
            }
        }
        let tags = match client.tags(repo).await {
            Ok(t) => t,
            Err(e) => {
                tracing::warn!(%repo, error = %e, "tag list failed; skipping");
                continue;
            }
        };
        for tag in tags {
            for _ in 0..args.iterations {
                work.push((repo.clone(), tag.clone()));
            }
        }
    }

    if let Some(cap) = args.max_pulls {
        work.truncate(cap);
    }
    let total = work.len();
    tracing::info!(
        total_pulls = total,
        concurrency = args.concurrency,
        blob_concurrency = args.blob_concurrency,
        "starting load"
    );

    let blob_concurrency = args.blob_concurrency;
    let samples: Vec<PullSample> = stream::iter(work.into_iter().enumerate())
        .map(|(idx, (repo, tag))| {
            let client = Arc::clone(&client);
            async move {
                let result = client.pull_image(&repo, &tag, blob_concurrency).await;
                match result {
                    Ok(s) => {
                        tracing::info!(
                            n = idx + 1,
                            of = total,
                            %repo,
                            %tag,
                            duration_ms = s.duration_ms,
                            mb = (s.bytes as f64) / 1_048_576.0,
                            mb_per_s = s.mb_per_sec(),
                            "pull ok"
                        );
                        s
                    }
                    Err(e) => {
                        tracing::error!(%repo, %tag, error = %e, "pull failed");
                        PullSample::failed(repo, tag, e.to_string())
                    }
                }
            }
        })
        .buffer_unordered(args.concurrency)
        .collect()
        .await;

    let agg = Aggregator::from_samples(&samples);
    let report = Report {
        scenario: args.scenario.clone(),
        target: args.target.clone(),
        started_at: started,
        finished_at: chrono::Utc::now(),
        wall_clock_seconds: wall_start.elapsed().as_secs_f64(),
        concurrency: args.concurrency,
        blob_concurrency: args.blob_concurrency,
        iterations: args.iterations,
        aggregates: agg,
        samples,
    };

    let json = serde_json::to_string_pretty(&report)?;
    tokio::fs::write(&args.output, json)
        .await
        .with_context(|| format!("writing report to {}", args.output.display()))?;
    tracing::info!(path = %args.output.display(), "report written");

    println!();
    report.print_summary();

    Ok(())
}
