import Config

config :logger,
  level: :warning

config :logger, :console,
  format: "$time [$level] $metadata- $message\n",
  metadata: [:module, :line]
