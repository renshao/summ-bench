use anyhow::{anyhow, bail, Context, Result};
use futures::stream::{self, StreamExt};
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT};
use serde::Deserialize;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::report::PullSample;

const ACCEPT_MANIFESTS: &str = concat!(
    "application/vnd.oci.image.index.v1+json",
    ", application/vnd.docker.distribution.manifest.list.v2+json",
    ", application/vnd.oci.image.manifest.v1+json",
    ", application/vnd.docker.distribution.manifest.v2+json",
);

pub struct RegistryClient {
    http: reqwest::Client,
    base: String,
}

#[derive(Debug, Deserialize)]
struct CatalogResponse {
    repositories: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct TagsResponse {
    #[allow(dead_code)]
    name: Option<String>,
    #[serde(default)]
    tags: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct ManifestIndex {
    manifests: Vec<IndexEntry>,
}

#[derive(Debug, Deserialize)]
struct IndexEntry {
    digest: String,
    #[serde(default)]
    platform: Option<Platform>,
}

#[derive(Debug, Deserialize)]
struct Platform {
    architecture: Option<String>,
    os: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ImageManifest {
    config: Descriptor,
    #[serde(default)]
    layers: Vec<Descriptor>,
}

#[derive(Debug, Deserialize)]
struct Descriptor {
    digest: String,
}

impl RegistryClient {
    pub fn new(base: &str) -> Result<Self> {
        let http = reqwest::Client::builder()
            .pool_max_idle_per_host(64)
            .tcp_nodelay(true)
            .timeout(Duration::from_secs(600))
            .connect_timeout(Duration::from_secs(10))
            .build()
            .context("building reqwest client")?;
        Ok(Self {
            http,
            base: base.trim_end_matches('/').to_string(),
        })
    }

    pub async fn catalog(&self) -> Result<Vec<String>> {
        let mut all = Vec::new();
        let mut url = format!("{}/v2/_catalog?n=1000", self.base);
        loop {
            let resp = self.http.get(&url).send().await?.error_for_status()?;
            let link = resp
                .headers()
                .get("link")
                .and_then(|v| v.to_str().ok())
                .map(|s| s.to_string());
            let body: CatalogResponse = resp.json().await?;
            all.extend(body.repositories);
            match next_link(link.as_deref()) {
                Some(rel) => {
                    url = format!("{}{}", self.base, rel);
                }
                None => break,
            }
        }
        Ok(all)
    }

    pub async fn tags(&self, repo: &str) -> Result<Vec<String>> {
        let url = format!("{}/v2/{}/tags/list?n=1000", self.base, repo);
        let resp = self.http.get(&url).send().await?.error_for_status()?;
        let body: TagsResponse = resp.json().await?;
        Ok(body.tags)
    }

    pub async fn pull_image(
        self: &Arc<Self>,
        repo: &str,
        tag: &str,
        blob_concurrency: usize,
    ) -> Result<PullSample> {
        let start = Instant::now();
        let mut headers = HeaderMap::new();
        headers.insert(ACCEPT, HeaderValue::from_static(ACCEPT_MANIFESTS));

        let manifest_url = format!("{}/v2/{}/manifests/{}", self.base, repo, tag);
        let resp = self
            .http
            .get(&manifest_url)
            .headers(headers.clone())
            .send()
            .await?
            .error_for_status()?;

        let media = resp
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_string();
        let body_bytes = resp.bytes().await?;
        let manifest_bytes = body_bytes.len() as u64;

        let image_manifest = if is_index(&media) || looks_like_index(&body_bytes) {
            let index: ManifestIndex = serde_json::from_slice(&body_bytes)
                .context("parsing manifest index")?;
            let pick = index
                .manifests
                .iter()
                .find(|m| {
                    m.platform.as_ref().is_some_and(|p| {
                        p.os.as_deref() == Some("linux")
                            && p.architecture.as_deref() == Some("amd64")
                    })
                })
                .or_else(|| index.manifests.first())
                .ok_or_else(|| anyhow!("manifest index has no entries"))?;
            let sub_url = format!("{}/v2/{}/manifests/{}", self.base, repo, pick.digest);
            let sub_resp = self
                .http
                .get(&sub_url)
                .headers(headers)
                .send()
                .await?
                .error_for_status()?;
            let sub_body = sub_resp.bytes().await?;
            serde_json::from_slice::<ImageManifest>(&sub_body)
                .context("parsing image manifest from index entry")?
        } else {
            serde_json::from_slice::<ImageManifest>(&body_bytes)
                .context("parsing image manifest")?
        };

        let mut descriptors: Vec<Descriptor> = Vec::with_capacity(image_manifest.layers.len() + 1);
        descriptors.push(image_manifest.config);
        descriptors.extend(image_manifest.layers);

        let bytes_counter = Arc::new(AtomicU64::new(manifest_bytes));
        let blob_count = descriptors.len();

        let client = Arc::clone(self);
        let repo_owned = repo.to_string();
        let results: Vec<Result<()>> = stream::iter(descriptors.into_iter())
            .map(|d| {
                let client = Arc::clone(&client);
                let counter = Arc::clone(&bytes_counter);
                let repo = repo_owned.clone();
                async move {
                    let n = client.fetch_blob(&repo, &d.digest).await?;
                    counter.fetch_add(n, Ordering::Relaxed);
                    Ok(())
                }
            })
            .buffer_unordered(blob_concurrency)
            .collect()
            .await;

        for r in results {
            r?;
        }

        let total_bytes = bytes_counter.load(Ordering::Relaxed);
        let elapsed = start.elapsed();
        Ok(PullSample::ok(
            repo.to_string(),
            tag.to_string(),
            elapsed.as_secs_f64() * 1000.0,
            total_bytes,
            blob_count,
        ))
    }

    async fn fetch_blob(&self, repo: &str, digest: &str) -> Result<u64> {
        let url = format!("{}/v2/{}/blobs/{}", self.base, repo, digest);
        let mut resp = self.http.get(&url).send().await?;
        if !resp.status().is_success() {
            bail!("blob {} returned status {}", digest, resp.status());
        }
        let mut total: u64 = 0;
        while let Some(chunk) = resp.chunk().await? {
            total += chunk.len() as u64;
        }
        Ok(total)
    }
}

fn is_index(media_type: &str) -> bool {
    media_type.contains("image.index") || media_type.contains("manifest.list")
}

fn looks_like_index(body: &[u8]) -> bool {
    serde_json::from_slice::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v.get("manifests").map(|m| m.is_array()))
        .unwrap_or(false)
}

fn next_link(link: Option<&str>) -> Option<String> {
    let s = link?;
    for part in s.split(',') {
        let part = part.trim();
        if part.contains("rel=\"next\"") || part.contains("rel=next") {
            let start = part.find('<')?;
            let end = part.find('>')?;
            return Some(part[start + 1..end].to_string());
        }
    }
    None
}
