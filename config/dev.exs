import Config

config :logger,
  level: :debug

config :logger, :console,
  format: "$date $time [$level] [$node] $metadata- $message\n",
  metadata: [:pid, :module, :function, :line]
