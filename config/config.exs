import Config

config :logger,
  level: :info

config :logger, :console,
  format: "$date $time [$level] [$node] $metadata- $message\n",
  metadata: [:pid, :module, :function, :line]

effective_env = if config_env() == :dev, do: :local, else: config_env()
import_config "#{effective_env}.exs"
