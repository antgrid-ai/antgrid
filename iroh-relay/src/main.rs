#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let path = args.next().ok_or_else(|| {
        anyhow::anyhow!("usage: antgrid-iroh-relay [--healthcheck] <config.json>")
    })?;
    let healthcheck = path == "--healthcheck";
    let path = if healthcheck {
        args.next()
            .ok_or_else(|| anyhow::anyhow!("missing configuration"))?
    } else {
        path
    };
    let config: antgrid_iroh_relay::config::Config = serde_json::from_slice(&std::fs::read(path)?)?;
    if healthcheck {
        config.validate()?;
        let response = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(2))
            .build()?
            .get(format!("http://{}/readyz", config.admin_listen))
            .send()
            .await?;
        anyhow::ensure!(response.status().is_success(), "relay not ready");
        return Ok(());
    }
    antgrid_iroh_relay::run(config).await
}
