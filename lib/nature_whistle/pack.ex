defmodule NatureWhistle.Pack do
  @callback alerts(keyword()) :: [map()]
end
