import Config

if config_env() == :live do
  pod_namespace = System.get_env("POD_NAMESPACE", "unknown")
  pod_name = System.get_env("POD_NAME", "unknown")

  config :logger, :console,
    format:
      "$date $time UTC [#{pod_namespace}/#{pod_name}] [$level] [$node] $metadata- $message\n",
    metadata: [:pid, :module]
end
