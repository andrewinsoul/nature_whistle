defmodule NatureWhistle.Pack do
  @moduledoc """
  Behaviour implemented by NatureWhistle alert packs.

  An alert pack turns integration- or runtime-specific configuration into a
  list of alert definitions that can be loaded by `NatureWhistle.Application`.
  """

  @doc """
  Builds the alert definitions provided by a pack.

  The keyword list contains pack-specific options. Implementations should
  return alert maps compatible with NatureWhistle's alert configuration format.
  """
  @callback alerts(keyword()) :: [map()]
end
