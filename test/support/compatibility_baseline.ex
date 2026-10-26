defmodule Hyperlang.CompatibilityBaseline do
  @moduledoc false

  @otp_release Hyperlang.StdlibAllowlist.otp_release()

  @otp_sources %{
    file: %{
      app: :kernel,
      source_path: "kernel/src/file.erl",
      role: :filesystem_compatibility
    },
    filelib: %{
      app: :stdlib,
      source_path: "stdlib/src/filelib.erl",
      role: :filesystem_compatibility
    },
    file_hrl: %{
      app: :kernel,
      source_path: "kernel/include/file.hrl",
      role: :filesystem_metadata_shape
    },
    io_lib: %{
      app: :stdlib,
      source_path: "stdlib/src/io_lib.erl",
      role: :stdout_formatting_compatibility
    },
    io_lib_format: %{
      app: :stdlib,
      source_path: "stdlib/src/io_lib_format.erl",
      role: :stdout_formatting_compatibility
    },
    io_lib_fread: %{
      app: :stdlib,
      source_path: "stdlib/src/io_lib_fread.erl",
      role: :stdout_formatting_compatibility
    },
    io_lib_pretty: %{
      app: :stdlib,
      source_path: "stdlib/src/io_lib_pretty.erl",
      role: :stdout_formatting_compatibility
    },
    filename: %{
      app: :stdlib,
      source_path: "stdlib/src/filename.erl",
      role: :path_string_helpers
    },
    compile: %{
      app: :compiler,
      source_path: "compiler/src/compile.erl",
      role: :loader_evaluator_compatibility
    },
    code: %{
      app: :kernel,
      source_path: "kernel/src/code.erl",
      role: :loader_evaluator_compatibility
    },
    erl_eval: %{
      app: :stdlib,
      source_path: "stdlib/src/erl_eval.erl",
      role: :loader_evaluator_compatibility
    }
  }

  @vendor_sources %{
    file: %{
      source_key: :file,
      vendor_path: "vendor/otp_kernel_11_0_2/src/file.erl",
      sha256: "a8fdd9f93bede84b1d1d00ffa92163826dc452703f50da12a85c2a8d82058e04"
    },
    filelib: %{
      source_key: :filelib,
      vendor_path: "vendor/otp_stdlib_8_0_1/src/filelib.erl",
      sha256: "e9952a847dc0ee2f5bd1f95ee6c44a90f740156153babcca8114d9933c90c398"
    },
    file_hrl: %{
      source_key: :file_hrl,
      vendor_path: "vendor/otp_kernel_11_0_2/include/file.hrl",
      sha256: "4c7ed0e4cc09c454f65c0bf0528e6e56d94ab309e232a4e25db9a486df950299"
    },
    io_lib: %{
      source_key: :io_lib,
      vendor_path: "vendor/otp_stdlib_8_0_1/src/io_lib.erl",
      sha256: "b6da306a37f9ddb4fad3779e65f154f09815cc1ebeb7fca991983033d92fc7c6"
    },
    io_lib_format: %{
      source_key: :io_lib_format,
      vendor_path: "vendor/otp_stdlib_8_0_1/src/io_lib_format.erl",
      sha256: "8ecbee07d2a39edf081e2888ddb47e8fdfc4b58ee452dd34306e1d1d3cf32c7f"
    },
    io_lib_fread: %{
      source_key: :io_lib_fread,
      vendor_path: "vendor/otp_stdlib_8_0_1/src/io_lib_fread.erl",
      sha256: "d66c2e6b4617bcbd7c497d46830947a90903851c0b1d07ad8369ca0d3004eed3"
    },
    io_lib_pretty: %{
      source_key: :io_lib_pretty,
      vendor_path: "vendor/otp_stdlib_8_0_1/src/io_lib_pretty.erl",
      sha256: "c489356b654c63453ef217bf73235ab7f2df1e99fe5cdd8b0424461d860d910b"
    }
  }

  @patch_log "doc/SECURITY_SPECIFICATION.md"

  def otp_release, do: @otp_release
  def otp_sources, do: @otp_sources
  def vendor_sources, do: @vendor_sources
  def patch_log, do: @patch_log

  def metadata do
    %{
      otp_release: @otp_release,
      otp_sources: @otp_sources,
      vendor_sources: @vendor_sources,
      patch_log: @patch_log
    }
  end
end
