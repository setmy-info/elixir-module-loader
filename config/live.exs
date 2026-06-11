import Config

config :logger,
  level: :info

config :logger, :console,
  format: "$date $time UTC [$level] [$node] $metadata- $message\n",
  metadata: [:pid, :module, :line]
