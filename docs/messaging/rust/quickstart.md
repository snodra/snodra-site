# Rust quick start

## Dependency

```toml
[dependencies]
snodra-messaging-rs = "0.7"
```

The crates live on crates.io: pin a minor version (`0.7`), or the exact release.

## Usage

```rust
use snodra_messaging::{Command, Config, Event, SnodraMessaging, MessagingError, Query, SendOptions, message_type};
use snodra_messaging::identity::Guard;

#[derive(serde::Serialize, serde::Deserialize)]
struct Shout { text: String }
#[derive(serde::Serialize, serde::Deserialize)]
struct Shouted { text: String }
message_type!(Shout, "examples.Shout");            // wire names are always explicit
impl Command for Shout { type Reply = Shouted; }

#[derive(serde::Serialize, serde::Deserialize)]
struct TextShouted { text: String, at: chrono::DateTime<chrono::Utc> }
message_type!(TextShouted, "examples.TextShouted");
impl Event for TextShouted {}

#[tokio::main]
async fn main() -> Result<(), MessagingError> {
    let builder = SnodraMessaging::builder(Config::from_env()?).await?;
    let events = builder.events();                                   // capture what handlers need
    let app = builder
        .command::<Shout, _, _>(move |cmd, ctx| {
            let events = events.clone();
            async move {
                let text = cmd.text.to_uppercase();
                events.publish(&TextShouted { text: text.clone(), at: chrono::Utc::now() }, Some(&cmd.text)).await?;
                tracing::info!(correlation = %ctx.correlation_id, "handled Shout");
                Ok(Shouted { text })
            }
        })
        .requires::<Shout>(Guard::role("snodra-user"))              // optional; needs SNODRA_JWKS_URL and SNODRA_ISSUER
        .start()                                                      // registers in the background
        .await?;
    app.await_hub(std::time::Duration::from_secs(30)).await;
    tokio::signal::ctrl_c().await.ok();
    app.shutdown().await;
    Ok(())
}
```

Handlers are async closures `Fn(Message, MessageContext) -> Future<Result<Reply, MessagingError>>`.
Event handlers receive an `EventContext { message, session }`: `session` is the Mongo session of the
consumer's transaction (`Arc<Mutex<ClientSession>>`), so writes done through it, including
`events.publish_in(&event, key, &mut session)`, commit together with the dedupe marker.

Sending: `app.commands().send_command(&cmd, SendOptions::default()).await?` and
`app.queries().send_query(&q, SendOptions { routing_key, timeout, ..Default::default() })`. Inside a handler
the caller's `correlationId` and bearer token are forwarded automatically (task-local
`MessageContext::current()`).
