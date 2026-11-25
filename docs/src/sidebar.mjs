export const sidebar = [
  {
    "label": "Snodra site",
    "link": "https://snodra.damoreira.com/"
  },
  {
    "label": "Getting started",
    "items": [
      {
        "label": "Overview",
        "slug": "getting-started"
      },
      {
        "label": "Installation",
        "slug": "getting-started/installation"
      },
      {
        "label": "Your first service",
        "slug": "getting-started/first-service"
      }
    ]
  },
  {
    "label": "Core concepts",
    "items": [
      {
        "label": "Overview",
        "slug": "concepts"
      },
      {
        "label": "CQRS",
        "slug": "concepts/cqrs"
      },
      {
        "label": "Commands",
        "slug": "concepts/commands"
      },
      {
        "label": "Queries",
        "slug": "concepts/queries"
      },
      {
        "label": "Events",
        "slug": "concepts/events"
      },
      {
        "label": "Event sourcing",
        "slug": "concepts/event-sourcing"
      },
      {
        "label": "Sagas",
        "slug": "concepts/sagas"
      },
      {
        "label": "Event processors",
        "slug": "concepts/event-processors"
      },
      {
        "label": "Consistency",
        "slug": "concepts/consistency"
      }
    ]
  },
  {
    "label": "Reference",
    "items": [
      {
        "label": "Overview",
        "slug": "reference"
      },
      {
        "label": "Server",
        "items": [
          {
            "label": "Overview",
            "slug": "server"
          },
          {
            "label": "Quick start",
            "slug": "server/quickstart"
          },
          {
            "label": "Authentication",
            "items": [
              {
                "label": "Overview",
                "slug": "server/configuration"
              },
              {
                "label": "Anonymous",
                "slug": "server/configuration/anonymous"
              },
              {
                "label": "Static token",
                "slug": "server/configuration/token"
              },
              {
                "label": "OAuth2 / OIDC JWT",
                "slug": "server/configuration/jwt-oauth2"
              },
              {
                "label": "mTLS",
                "slug": "server/configuration/mtls"
              }
            ]
          },
          {
            "label": "Server settings",
            "slug": "server/configuration/server"
          },
          {
            "label": "Topology",
            "slug": "server/topology"
          },
          {
            "label": "Dashboard",
            "slug": "server/dashboard"
          },
          {
            "label": "Event processors",
            "slug": "server/event-processors"
          },
          {
            "label": "Processor control",
            "slug": "server/processor-control"
          },
          {
            "label": "Event browser",
            "slug": "server/event-browser"
          },
          {
            "label": "Routing",
            "slug": "server/routing"
          },
          {
            "label": "Protocol",
            "slug": "server/protocol"
          },
          {
            "label": "Lifecycle",
            "slug": "server/lifecycle"
          },
          {
            "label": "Operations",
            "slug": "server/operations"
          },
          {
            "label": "Observability",
            "slug": "server/observability"
          },
          {
            "label": "Build and image",
            "slug": "server/build-and-image"
          },
          {
            "label": "Limitations",
            "slug": "server/limitations"
          },
          {
            "label": "Licence",
            "slug": "server/license"
          }
        ]
      },
      {
        "label": "Messaging model",
        "slug": "messaging"
      },
      {
        "label": "Kotlin library",
        "items": [
          {
            "label": "Overview",
            "slug": "messaging/kotlin"
          },
          {
            "label": "Quick start",
            "slug": "messaging/kotlin/quickstart"
          },
          {
            "label": "Configuration",
            "slug": "messaging/kotlin/configuration"
          },
          {
            "label": "API",
            "slug": "messaging/kotlin/api"
          },
          {
            "label": "Testing",
            "slug": "messaging/kotlin/testing"
          },
          {
            "label": "Modules and build",
            "slug": "messaging/kotlin/modules"
          }
        ]
      },
      {
        "label": "Rust library",
        "items": [
          {
            "label": "Overview",
            "slug": "messaging/rust"
          },
          {
            "label": "Quick start",
            "slug": "messaging/rust/quickstart"
          },
          {
            "label": "Configuration",
            "slug": "messaging/rust/configuration"
          },
          {
            "label": "API",
            "slug": "messaging/rust/api"
          },
          {
            "label": "Dead letters",
            "slug": "messaging/rust/dead-letters"
          },
          {
            "label": "Sagas",
            "slug": "messaging/rust/sagas"
          },
          {
            "label": "Testing",
            "slug": "messaging/rust/testing"
          },
          {
            "label": "Modules and build",
            "slug": "messaging/rust/modules"
          }
        ]
      },
      {
        "label": "Go library",
        "items": [
          {
            "label": "Overview",
            "slug": "messaging/go"
          },
          {
            "label": "Quick start",
            "slug": "messaging/go/quickstart"
          },
          {
            "label": "Configuration",
            "slug": "messaging/go/configuration"
          },
          {
            "label": "API",
            "slug": "messaging/go/api"
          },
          {
            "label": "Testing",
            "slug": "messaging/go/testing"
          }
        ]
      },
      {
        "label": "Python library",
        "items": [
          {
            "label": "Overview",
            "slug": "messaging/python"
          },
          {
            "label": "Quick start",
            "slug": "messaging/python/quickstart"
          },
          {
            "label": "Configuration",
            "slug": "messaging/python/configuration"
          },
          {
            "label": "API",
            "slug": "messaging/python/api"
          },
          {
            "label": "Testing",
            "slug": "messaging/python/testing"
          }
        ]
      }
    ]
  },
  {
    "label": "Add-ons",
    "items": [
      {
        "label": "Overview",
        "slug": "add-ons"
      },
      {
        "label": "Kafka event store",
        "slug": "add-ons/kafka-event-store"
      },
      {
        "label": "RabbitMQ Streams event store",
        "slug": "add-ons/rabbitmq-streams-event-store"
      },
      {
        "label": "MongoDB message store",
        "slug": "add-ons/mongodb-message-store"
      },
      {
        "label": "SQL message store",
        "slug": "add-ons/sql-message-store"
      }
    ]
  },
  {
    "label": "Writing a library",
    "items": [
      {
        "label": "Overview",
        "slug": "library-authors"
      },
      {
        "label": "Writing guide",
        "slug": "library-authors/writing-a-library"
      },
      {
        "label": "Protocol",
        "slug": "library-authors/protocol"
      },
      {
        "label": "Messages",
        "slug": "library-authors/messages"
      },
      {
        "label": "Feature levels",
        "slug": "library-authors/feature-levels"
      },
      {
        "label": "Event-store add-ons",
        "slug": "library-authors/event-store-add-ons"
      },
      {
        "label": "Message-store add-ons",
        "slug": "library-authors/message-store-add-ons"
      },
      {
        "label": "MongoDB layout",
        "slug": "library-authors/mongodb-layout"
      },
      {
        "label": "Conformance",
        "slug": "library-authors/conformance"
      }
    ]
  },
  {
    "label": "Operations",
    "items": [
      {
        "label": "Overview",
        "slug": "operations"
      },
      {
        "label": "Monitoring",
        "slug": "operations/monitoring"
      },
      {
        "label": "Testing",
        "slug": "operations/testing"
      },
      {
        "label": "Tuning",
        "slug": "operations/tuning"
      },
      {
        "label": "Upgrades",
        "slug": "operations/upgrades"
      }
    ]
  },
  {
    "label": "Integrations",
    "items": [
      {
        "label": "Overview",
        "slug": "integrations"
      },
      {
        "label": "Spring Boot",
        "slug": "integrations/spring-boot"
      },
      {
        "label": "OAuth2 provider",
        "slug": "integrations/oauth2"
      },
      {
        "label": "OpenTelemetry",
        "slug": "integrations/opentelemetry"
      },
      {
        "label": "Containers",
        "slug": "integrations/containers"
      },
      {
        "label": "Existing services",
        "slug": "integrations/existing-service"
      }
    ]
  },
  {
    "label": "Tools",
    "items": [
      {
        "label": "Overview",
        "slug": "tools"
      },
      {
        "label": "Event browser",
        "slug": "tools/event-browser"
      },
      {
        "label": "Conformance runner",
        "slug": "tools/conformance-runner"
      }
    ]
  },
  {
    "label": "Migration",
    "items": [
      {
        "label": "Overview",
        "slug": "migration"
      },
      {
        "label": "Compatibility",
        "slug": "migration/compatibility"
      }
    ]
  },
  {
    "label": "Examples",
    "slug": "examples"
  },
  {
    "label": "Editions",
    "slug": "editions"
  },
  {
    "label": "Licence",
    "slug": "concepts/license"
  }
];
