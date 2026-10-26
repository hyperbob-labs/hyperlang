import Config

if config_env() == :test do
  config :hyperlang,
    code_pool_size: 8_192,
    library_pool_size: 2_048
end
