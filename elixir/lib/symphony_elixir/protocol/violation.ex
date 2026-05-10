defmodule SymphonyElixir.Protocol.Violation do
  @moduledoc """
  Explicit protocol violation or warning emitted by the workflow hardening layer.
  """

  @enforce_keys [:code, :severity, :message]
  defstruct [:code, :severity, :message, :required_action, evidence: %{}]

  @type severity :: :blocking | :warning | :info

  @type t :: %__MODULE__{
          code: atom(),
          severity: severity(),
          message: String.t(),
          required_action: String.t() | nil,
          evidence: map()
        }

  @spec blocking(atom(), String.t(), keyword()) :: t()
  def blocking(code, message, opts \\ []), do: new(code, :blocking, message, opts)

  @spec warning(atom(), String.t(), keyword()) :: t()
  def warning(code, message, opts \\ []), do: new(code, :warning, message, opts)

  @spec info(atom(), String.t(), keyword()) :: t()
  def info(code, message, opts \\ []), do: new(code, :info, message, opts)

  @spec new(atom(), severity(), String.t(), keyword()) :: t()
  def new(code, severity, message, opts)
      when is_atom(code) and severity in [:blocking, :warning, :info] and is_binary(message) do
    %__MODULE__{
      code: code,
      severity: severity,
      message: message,
      required_action: Keyword.get(opts, :required_action),
      evidence: Keyword.get(opts, :evidence, %{})
    }
  end
end
