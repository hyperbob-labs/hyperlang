defmodule Hyperlang.Core do
  @moduledoc false

  defstruct [:result, functions: %{}, function_order: [], calls: [], metadata: %{}]

  defmodule Function do
    @moduledoc false
    defstruct [:source_name, :safe_name, :arity, :span, clauses: []]
  end

  defmodule Clause do
    @moduledoc false
    defstruct [:patterns, :guard, :body, vars: %{}]
  end
end
